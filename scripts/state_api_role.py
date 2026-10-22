"""Explicit administrator provisioning for the state API, never a startup migration.

The caller owns the transaction and must publish the matching Secret before commit.
This separates database administration and worker mutations; it is not tenant RLS.
Passwords/verifiers must never be logged or put into Terraform state.
"""

ROLE = "sky_api"
LEDGERS = (
    "schema_versions",
    "operation_schema_versions",
    "admission_schema_versions",
    "approval_schema_versions",
    "preview_schema_versions",
)
EDITABLE = (
    "metadata_records",
    "application_owners",
    "deployment_approvals",
    "deployment_previews",
)
APPEND_ONLY = ("operations", "mutation_scopes", "operation_events", "outbox_events")


def provision(connection, password):
    from psycopg import sql

    if (
        not isinstance(password, str)
        or not 32 <= len(password.encode()) <= 512
        or "\x00" in password
    ):
        raise ValueError("A bounded high-entropy runtime password is required")
    database, owner = connection.execute(
        "SELECT current_database(), current_user"
    ).fetchone()
    marker = "sky-state-api-v1:" + database
    schema_owner = connection.execute(
        "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='sky_state'"
    ).fetchone()
    database_owner = connection.execute(
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()"
    ).fetchone()[0]
    if not schema_owner or schema_owner[0] != owner or database_owner != owner:
        raise ValueError("State schema owner must provision the API role")
    for table in LEDGERS + EDITABLE + APPEND_ONLY:
        if (
            connection.execute(
                "SELECT to_regclass(%s)", ("sky_state." + table,)
            ).fetchone()[0]
            is None
        ):
            raise ValueError(
                "Migrate the reviewed state schema before role provisioning"
            )
    existing = connection.execute(
        "SELECT oid,rolsuper,rolcreatedb,rolcreaterole,rolinherit,rolreplication,rolbypassrls,"
        "shobj_description(oid,'pg_authid') FROM pg_roles WHERE rolname=%s",
        (ROLE,),
    ).fetchone()
    if existing:
        if any(existing[1:7]) or existing[7] != marker:
            raise ValueError(
                "Existing role is not the registered unprivileged API identity"
            )
        if connection.execute(
            "SELECT EXISTS(SELECT 1 FROM pg_auth_members WHERE member=%s OR "
            "(roleid=%s AND member<>(SELECT oid FROM pg_roles WHERE rolname=current_user))) OR "
            "EXISTS(SELECT 1 FROM pg_class WHERE relowner=%s) OR "
            "EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=%s) OR "
            "EXISTS(SELECT 1 FROM pg_database WHERE datdba=%s)",
            (existing[0],) * 5,
        ).fetchone()[0]:
            raise ValueError("API role must not inherit roles or own database objects")
    else:
        connection.execute(
            sql.SQL(
                "CREATE ROLE {} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                "NOINHERIT NOREPLICATION NOBYPASSRLS"
            ).format(sql.Identifier(ROLE))
        )
        connection.execute(
            sql.SQL("COMMENT ON ROLE {} IS {}").format(
                sql.Identifier(ROLE), sql.Literal(marker)
            )
        )
    # libpq creates the salted SCRAM verifier locally; plaintext never enters SQL statements.
    verifier = connection.pgconn.encrypt_password(
        password.encode(), ROLE.encode(), b"scram-sha-256"
    ).decode()
    connection.execute(
        sql.SQL("ALTER ROLE {} PASSWORD {} CONNECTION LIMIT 20").format(
            sql.Identifier(ROLE), sql.Literal(verifier)
        )
    )
    connection.execute(
        sql.SQL("REVOKE CONNECT, CREATE, TEMPORARY ON DATABASE {} FROM PUBLIC").format(
            sql.Identifier(database)
        )
    )
    connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
    connection.execute("REVOKE ALL ON SCHEMA sky_state FROM PUBLIC")
    connection.execute("REVOKE ALL ON ALL TABLES IN SCHEMA sky_state FROM PUBLIC")
    connection.execute(
        sql.SQL("REVOKE ALL ON DATABASE {} FROM {}").format(
            sql.Identifier(database), sql.Identifier(ROLE)
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL ON SCHEMA sky_state FROM {}").format(sql.Identifier(ROLE))
    )
    connection.execute(
        sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA sky_state FROM {}").format(
            sql.Identifier(ROLE)
        )
    )
    connection.execute(
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(database), sql.Identifier(ROLE)
        )
    )
    connection.execute(
        sql.SQL("GRANT USAGE ON SCHEMA sky_state TO {}").format(sql.Identifier(ROLE))
    )
    for tables, privileges in (
        (LEDGERS, "SELECT"),
        (EDITABLE, "SELECT, INSERT, UPDATE"),
        (APPEND_ONLY, "SELECT, INSERT"),
    ):
        for table in tables:
            connection.execute(
                sql.SQL("GRANT " + privileges + " ON TABLE sky_state.{} TO {}").format(
                    sql.Identifier(table), sql.Identifier(ROLE)
                )
            )
    connection.execute(
        sql.SQL(
            "ALTER ROLE {} IN DATABASE {} SET search_path TO pg_catalog, sky_state"
        ).format(sql.Identifier(ROLE), sql.Identifier(database))
    )
    for name, value in (
        ("statement_timeout", "30s"),
        ("lock_timeout", "5s"),
        ("idle_in_transaction_session_timeout", "30s"),
    ):
        connection.execute(
            sql.SQL("ALTER ROLE {} IN DATABASE {} SET {} TO {}").format(
                sql.Identifier(ROLE),
                sql.Identifier(database),
                sql.Identifier(name),
                sql.Literal(value),
            )
        )
    connection.execute(sql.SQL("ALTER ROLE {} LOGIN").format(sql.Identifier(ROLE)))
    return {
        "role": ROLE,
        "database": database,
        "schema": "sky_state",
        "worker_updates": False,
        "ddl": False,
        "tenant_row_isolation": False,
    }
