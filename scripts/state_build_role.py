"""Explicit build-consumer SQL identity; cannot admit jobs or change approvals.

The operator owns the transaction and publishes its dedicated Secret before commit.
No DDL/admin or tenant row-isolation guarantee is provided by these grants.
"""

ROLE = "sky_build"
OPERATION_COLUMNS = (
    "status",
    "attempt_id",
    "generation",
    "row_version",
    "lease_owner",
    "lease_epoch",
    "lease_until",
    "checkpoint",
    "result",
    "external_pending",
    "external_intent",
    "external_receipt",
)


def provision(connection, password):
    from state_runtime_role import provision as provision_role

    read_tables = (
        "schema_versions",
        "operation_schema_versions",
        "admission_schema_versions",
        "approval_schema_versions",
        "metadata_records",
        "application_owners",
        "deployment_approvals",
        "operations",
        "mutation_scopes",
        "operation_events",
        "outbox_events",
    )
    grants = tuple((table, "SELECT") for table in read_tables) + (
        ("operations", "UPDATE (" + ", ".join(OPERATION_COLUMNS) + ")"),
        ("metadata_records", "UPDATE (document, revision, modified_at)"),
        ("operation_events", "INSERT"),
        (
            "outbox_events",
            "INSERT",
        ),  # Recovery emits a fresh attempt, never publishes it.
        ("mutation_scopes", "DELETE"),
    )
    return {
        **provision_role(
            connection,
            password,
            role=ROLE,
            marker_prefix="sky-state-build-v1:",
            grants=grants,
        ),
        "admission_writes": False,
        "approval_writes": False,
        "outbox_delivery_updates": False,
    }
