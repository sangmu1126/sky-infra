"""Real API/publisher authorization tests with disposable loopback-only credentials."""

import hashlib
import json
import os
import unittest
from uuid import uuid4

from state_api_role import ROLE, provision


@unittest.skipUnless(
    os.environ.get("SKY_ROLE_TEST_DSN"), "Disposable PostgreSQL DSN required"
)
class StateApiRoleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import psycopg
        from interfaces.b_runtime import run_migrations
        from psycopg import sql

        cls.psycopg = psycopg
        cls.dsn = psycopg.conninfo.conninfo_to_dict(os.environ["SKY_ROLE_TEST_DSN"])
        if cls.dsn.get("host") not in {"localhost", "127.0.0.1", "::1"}:
            raise ValueError("Only disposable loopback test databases are accepted")
        cls.password = "fixture-" + uuid4().hex
        with psycopg.connect(**cls.dsn) as connection:
            connection.execute("CREATE ROLE state_role_test_owner CREATEROLE NOLOGIN")
            database = connection.execute("SELECT current_database()").fetchone()[0]
            connection.execute(
                sql.SQL("ALTER DATABASE {} OWNER TO state_role_test_owner").format(
                    sql.Identifier(database)
                )
            )
            # The non-superuser owner exercises PostgreSQL's automatic creator membership.
        run_migrations(
            cls.admin,
            "role_contract",
            account_id="123456789012",
            region="ap-northeast-2",
        )
        with cls.admin() as connection:
            provision(connection, cls.password)
            from state_outbox_role import provision as provision_outbox

            provision_outbox(connection, cls.password)
            from state_build_role import provision as provision_build

            provision_build(connection, cls.password)

    @classmethod
    def admin(cls):
        connection = cls.psycopg.connect(**cls.dsn)
        connection.execute("SET ROLE state_role_test_owner")
        return connection

    @classmethod
    def api(cls):
        return cls.psycopg.connect(
            **{**cls.dsn, "user": ROLE, "password": cls.password}
        )

    def test_role_is_unprivileged_and_has_bounded_sessions(self):
        with self.api() as connection:
            row = connection.execute(
                "SELECT rolsuper,rolcreatedb,rolcreaterole,rolinherit,rolreplication,rolbypassrls,rolconnlimit FROM pg_roles WHERE rolname=current_user"
            ).fetchone()
            self.assertEqual(row, (False, False, False, False, False, False, 20))
            self.assertEqual(
                connection.execute("SELECT current_schemas(false)").fetchone()[0],
                ["pg_catalog", "sky_state"],
            )

    def test_readiness_is_available_to_api(self):
        from adapters.state.readiness import check_database_ready

        check_database_ready(self.api, operations=True)

    def test_existing_role_is_reconciled_without_privilege_expansion(self):
        with self.admin() as connection:
            provision(connection, self.password)
        self.test_readiness_is_available_to_api()

    def test_actual_api_admission_preserves_replay_and_worker_boundary(self):
        from adapters.state.deployment_admission import PostgresDeploymentAdmission
        from adapters.state.operations import PostgresOperationStore
        from domain.access import LoginSource, Principal, Role
        from ports.artifacts import SourceArtifact

        store = PostgresDeploymentAdmission(
            PostgresOperationStore(self.api, workspace=uuid4().hex),
            account_id="123456789012",
            region="ap-northeast-2",
        )
        principal = Principal("alice", "role_test", Role.DEPLOYER, LoginSource.LOCAL)
        artifact = SourceArtifact(
            "role_test", "probe", "a" * 32, "prepared", "b" * 64, 10, "c" * 64
        )
        plan = {"runtime": "node"}
        digest = hashlib.sha256(
            json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        first = store.admit(
            principal,
            artifact,
            "one",
            plan,
            expected_plan_digest=digest,
            expected_source_digest=artifact.source_digest,
        )
        self.assertEqual(
            first,
            store.admit(
                principal,
                artifact,
                "one",
                plan,
                expected_plan_digest=digest,
                expected_source_digest=artifact.source_digest,
            ),
        )
        self.assertEqual(store.operations.get(first.operation_id).status, "queued")

    def test_denied_sql_never_commits(self):
        statements = [
            "CREATE TABLE sky_state.role_probe(i integer)",
            "CREATE TABLE public.role_probe(i integer)",
            "CREATE TEMP TABLE role_probe(i integer)",
            "CREATE ROLE role_probe",
            "UPDATE sky_state.schema_versions SET version=version WHERE false",
            "UPDATE sky_state.operations SET status=status WHERE false",
            "UPDATE sky_state.outbox_events SET publisher_owner=NULL WHERE false",
            "DELETE FROM sky_state.metadata_records WHERE false",
        ]
        for statement in statements:
            with (
                self.subTest(statement=statement),
                self.api() as connection,
                self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
                connection.transaction(force_rollback=True),
            ):
                connection.execute(statement)

    def test_rejects_unsafe_password_before_changes(self):
        with self.admin() as connection, self.assertRaises(ValueError):
            provision(connection, "short")

    def test_rejects_unregistered_existing_role(self):
        with self.admin() as connection, connection.transaction(force_rollback=True):
            connection.execute("COMMENT ON ROLE sky_api IS 'not-registered'")
            with self.assertRaises(ValueError):
                provision(connection, self.password)

    def test_rejects_api_role_membership(self):
        with self.admin() as connection, connection.transaction(force_rollback=True):
            connection.execute("CREATE ROLE role_probe")
            connection.execute("GRANT role_probe TO sky_api")
            with self.assertRaises(ValueError):
                provision(connection, self.password)

    @classmethod
    def outbox(cls):
        return cls.psycopg.connect(
            **{**cls.dsn, "user": "sky_outbox", "password": cls.password}
        )

    def test_outbox_readiness_and_unprivileged_identity(self):
        from adapters.state.readiness import check_database_ready

        check_database_ready(self.outbox, operations=True)
        with self.outbox() as connection:
            flags = connection.execute(
                "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=current_user"
            ).fetchone()[0]
            self.assertFalse(flags)

    def test_outbox_dispatches_real_durable_event_without_execution_rights(self):
        from adapters.state.operations import PostgresOperationStore
        from application.outbox import OutboxPublisher
        from application.shared_database_consumer import AllocationQueueRouter

        workspace = uuid4().hex
        admitted = PostgresOperationStore(self.api, workspace=workspace).admit(
            "probe", "deploy", "publisher-proof", {"source": "fixture"}
        )
        store = PostgresOperationStore(self.outbox, workspace=workspace)
        deliveries = []

        class Queue:
            def publish(self, delivery):
                deliveries.append(delivery)

        publisher = OutboxPublisher(
            store, AllocationQueueRouter(store, Queue(), None), "publisher"
        )
        report = publisher.dispatch_once()
        self.assertEqual((report.confirmed, report.deferred), (1, 0))
        self.assertEqual(deliveries[0].operation_id, admitted.id)
        self.assertEqual(store.get(admitted.id).status, "queued")
        self.assertEqual(publisher.dispatch_once().confirmed, 0)

    def test_outbox_cannot_admit_execute_delete_or_rewrite_message_identity(self):
        statements = [
            "CREATE TABLE sky_state.role_probe(i integer)",
            "CREATE ROLE role_probe",
            "UPDATE sky_state.operations SET status=status WHERE false",
            "UPDATE sky_state.metadata_records SET revision=revision WHERE false",
            "UPDATE sky_state.outbox_events SET operation_id=operation_id WHERE false",
            "UPDATE sky_state.outbox_events SET attempt_id=attempt_id WHERE false",
            "INSERT INTO sky_state.outbox_events(workspace) SELECT 'probe' WHERE false",
            "DELETE FROM sky_state.outbox_events WHERE false",
            "DELETE FROM sky_state.mutation_scopes WHERE false",
            "UPDATE sky_state.operation_schema_versions SET version=version WHERE false",
        ]
        for statement in statements:
            with (
                self.subTest(statement=statement),
                self.outbox() as connection,
                self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
                connection.transaction(force_rollback=True),
            ):
                connection.execute(statement)

    def test_outbox_reprovision_removes_independent_column_grants(self):
        from state_outbox_role import provision as provision_outbox

        with self.admin() as connection, connection.transaction(force_rollback=True):
            connection.execute(
                "GRANT UPDATE(command) ON sky_state.operations TO sky_outbox"
            )
            connection.execute(
                "GRANT UPDATE(attempt_id) ON sky_state.outbox_events TO sky_outbox"
            )
            provision_outbox(connection, self.password)
            for table, column in (
                ("operations", "command"),
                ("outbox_events", "attempt_id"),
            ):
                self.assertFalse(
                    connection.execute(
                        "SELECT has_column_privilege('sky_outbox',%s,%s,'UPDATE')",
                        ("sky_state." + table, column),
                    ).fetchone()[0]
                )
            self.assertTrue(
                connection.execute(
                    "SELECT has_column_privilege('sky_outbox','sky_state.outbox_events','published_at','UPDATE')"
                ).fetchone()[0]
            )

    def test_outbox_cannot_assume_api_identity(self):
        with (
            self.outbox() as connection,
            self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
        ):
            connection.execute("SET ROLE sky_api")

    def test_outbox_send_failure_releases_claim_and_keeps_durable_failure(self):
        from adapters.state.operations import PostgresOperationStore
        from application.outbox import OutboxPublisher

        workspace = uuid4().hex
        admission = PostgresOperationStore(
            self.api, workspace=workspace, outbox_max_attempts=1
        ).admit("probe", "deploy", "failed-send", {"source": "fixture"})
        store = PostgresOperationStore(self.outbox, workspace=workspace)

        class UncertainQueue:
            def publish(self, delivery):
                raise OSError("Send outcome uncertain")

        report = OutboxPublisher(store, UncertainQueue(), "publisher").dispatch_once()
        self.assertEqual((report.confirmed, report.deferred), (0, 1))
        failed = store.list_failed_outbox()
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0].operation_id, admission.id)
        self.assertEqual(store.get(admission.id).status, "queued")

    @classmethod
    def build(cls):
        return cls.psycopg.connect(
            **{**cls.dsn, "user": "sky_build", "password": cls.password}
        )

    def test_build_worker_readiness_uses_no_admission_or_admin_rights(self):
        from adapters.state.build_execution import PostgresBuildExecutionStore
        from adapters.state.deployment_admission import PostgresDeploymentAdmission
        from adapters.state.deployment_approvals import PostgresDeploymentApprovals

        PostgresDeploymentApprovals(
            PostgresDeploymentAdmission(
                PostgresBuildExecutionStore(self.build),
                account_id="123456789012",
                region="ap-northeast-2",
            )
        ).check_ready()
        with self.build() as connection:
            row = connection.execute(
                "SELECT rolsuper,rolcreatedb,rolcreaterole,rolinherit,rolreplication,rolbypassrls,rolconnlimit FROM pg_roles WHERE rolname=current_user"
            ).fetchone()
            self.assertEqual(row, (False, False, False, False, False, False, 20))

    def test_build_worker_claims_records_and_completes_admitted_operation(self):
        from adapters.state.operations import PostgresOperationStore

        workspace = uuid4().hex
        admitted = PostgresOperationStore(self.api, workspace=workspace).admit(
            "worker_probe", "deploy", "build-proof", {"source": "immutable"}
        )
        worker = PostgresOperationStore(self.build, workspace=workspace)
        lease = worker.claim(admitted.id, admitted.attempt_id, "worker")
        self.assertIsNotNone(lease)
        self.assertTrue(worker.heartbeat(lease))
        self.assertTrue(worker.checkpoint(lease, {"stage": "building"}))
        self.assertTrue(worker.begin_external(lease, {"kind": "probe"}))
        self.assertTrue(
            worker.observe_external(lease, {"verified": True}, {"stage": "build_ready"})
        )
        self.assertTrue(worker.complete(lease, {"verified": True}))
        self.assertEqual(worker.get(admitted.id).status, "succeeded")
        self.assertEqual(worker.get(admitted.id).command, {"source": "immutable"})

    def test_build_worker_recovers_expired_attempt_or_parks_uncertain_effect(self):
        from adapters.state.operations import PostgresOperationStore

        for pending in (False, True):
            workspace = uuid4().hex
            admitted = PostgresOperationStore(self.api, workspace=workspace).admit(
                "recovery_probe", "deploy", "recover", {}
            )
            worker = PostgresOperationStore(self.build, workspace=workspace)
            lease = worker.claim(admitted.id, admitted.attempt_id, "worker")
            if pending:
                worker.begin_external(lease, {"kind": "probe"})
            with self.admin() as connection:
                connection.execute(
                    "UPDATE sky_state.operations SET lease_until=clock_timestamp()-interval '1 second' WHERE workspace=%s AND id=%s",
                    (workspace, admitted.id),
                )
            self.assertEqual(worker.recover_expired(), (admitted.id,))
            recovered = worker.get(admitted.id)
            self.assertEqual(
                recovered.status, "needs_attention" if pending else "queued"
            )
            with self.admin() as connection:
                count = connection.execute(
                    "SELECT count(*) FROM sky_state.outbox_events WHERE workspace=%s",
                    (workspace,),
                ).fetchone()[0]
                self.assertEqual(count, 1 if pending else 2)

    def test_build_worker_cannot_admit_rewrite_approval_or_publish(self):
        for statement in (
            "CREATE TABLE sky_state.build_probe(i integer)",
            "CREATE TEMP TABLE build_probe(i integer)",
            "CREATE ROLE build_probe",
            "INSERT INTO sky_state.operations(workspace) SELECT 'probe' WHERE false",
            "DELETE FROM sky_state.operations WHERE false",
            "UPDATE sky_state.operations SET command=command WHERE false",
            "UPDATE sky_state.operations SET application_id=application_id WHERE false",
            "INSERT INTO sky_state.metadata_records(workspace) SELECT 'probe' WHERE false",
            "UPDATE sky_state.metadata_records SET record_id=record_id WHERE false",
            "DELETE FROM sky_state.metadata_records WHERE false",
            "UPDATE sky_state.deployment_approvals SET revoked_at=NULL WHERE false",
            "UPDATE sky_state.application_owners SET created_by=created_by WHERE false",
            "UPDATE sky_state.outbox_events SET published_at=NULL WHERE false",
            "DELETE FROM sky_state.operation_events WHERE false",
        ):
            with (
                self.subTest(statement=statement),
                self.build() as connection,
                self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
                connection.transaction(force_rollback=True),
            ):
                connection.execute(statement)

    def test_build_worker_reprovision_removes_unreviewed_column_grants(self):
        from state_build_role import provision as provision_build

        with self.admin() as connection, connection.transaction(force_rollback=True):
            connection.execute(
                "GRANT UPDATE(command) ON sky_state.operations TO sky_build"
            )
            provision_build(connection, self.password)
            self.assertFalse(
                connection.execute(
                    "SELECT has_column_privilege('sky_build','sky_state.operations','command','UPDATE')"
                ).fetchone()[0]
            )

    def test_budget_reservations_and_usage_are_append_only_under_real_runtime_roles(
        self,
    ):
        from datetime import UTC, datetime, timedelta
        from adapters.state.effect_budget import EffectBudgetPolicy

        maximum = {"requests": 1, "microusd": 100}
        policy = EffectBudgetPolicy.from_environment(
            {
                "SKY_EFFECT_BUDGET_JSON": json.dumps(
                    {
                        "version": 2,
                        "source": "synthetic role test, not a price",
                        "expires_at": (
                            datetime.now(UTC) + timedelta(hours=1)
                        ).isoformat(),
                        "limits": {
                            k: maximum
                            for k in ("global", "organization", "user", "application")
                        },
                        "effects": {"source_preparation": maximum},
                    }
                )
            }
        )
        workspace = uuid4().hex
        with self.api() as connection:
            self.assertTrue(
                policy.reserve(
                    connection,
                    workspace=workspace,
                    effect_key="role-test",
                    organization_id="role_test",
                    user_id="alice",
                    application_id="probe",
                    kind="source_preparation",
                    binding={"source": "a" * 64},
                )
            )
        for statement in (
            "UPDATE sky_state.effect_budget_reservations SET reserved='{}'::jsonb",
            "DELETE FROM sky_state.effect_budget_reservations",
            "DELETE FROM sky_state.effect_budget_windows",
        ):
            with (
                self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
                self.api() as connection,
            ):
                connection.execute(statement)
        with (
            self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
            self.api() as connection,
        ):
            policy.record_usage(
                connection,
                workspace=workspace,
                effect_key="role-test",
                actual=maximum,
                evidence_digest="b" * 64,
            )
        with self.psycopg.connect(
            **{**self.dsn, "user": "sky_build", "password": self.password}
        ) as worker:
            self.assertTrue(
                policy.record_usage(
                    worker,
                    workspace=workspace,
                    effect_key="role-test",
                    actual=maximum,
                    evidence_digest="b" * 64,
                )
            )
            self.assertFalse(
                policy.record_usage(
                    worker,
                    workspace=workspace,
                    effect_key="role-test",
                    actual=maximum,
                    evidence_digest="b" * 64,
                )
            )
        with (
            self.assertRaises(self.psycopg.errors.InsufficientPrivilege),
            self.psycopg.connect(
                **{**self.dsn, "user": "sky_build", "password": self.password}
            ) as worker,
        ):
            worker.execute(
                "UPDATE sky_state.effect_budget_settlements SET actual='{}'::jsonb"
            )


if __name__ == "__main__":
    unittest.main()
