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
    from state_runtime_role import provision as provision_role

    result = provision_role(
        connection,
        password,
        role=ROLE,
        marker_prefix="sky-state-api-v1:",
        grants=tuple(
            (table, privilege)
            for tables, privilege in (
                (LEDGERS, "SELECT"),
                (EDITABLE, "SELECT, INSERT, UPDATE"),
                (APPEND_ONLY, "SELECT, INSERT"),
            )
            for table in tables
        ),
    )
    return {**result, "worker_updates": False}
