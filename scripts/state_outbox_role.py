"""Publisher identity: read operations and update only outbox delivery bookkeeping.

This role cannot admit jobs, acquire execution leases, change commands or delete
records. It is not a deployment consumer identity or tenant row isolation.
"""

ROLE = "sky_outbox"
DELIVERY_COLUMNS = (
    "publisher_owner",
    "publisher_epoch",
    "publisher_until",
    "available_at",
    "publish_attempts",
    "failed_at",
    "failure_code",
    "published_at",
)


def provision(connection, password):
    from state_runtime_role import provision as provision_role

    grants = tuple(
        (table, "SELECT")
        for table in (
            "schema_versions",
            "operation_schema_versions",
            "metadata_records",
            "operations",
            "outbox_events",
        )
    ) + (("outbox_events", "UPDATE (" + ", ".join(DELIVERY_COLUMNS) + ")"),)
    return {
        **provision_role(
            connection,
            password,
            role=ROLE,
            marker_prefix="sky-state-outbox-v1:",
            grants=grants,
        ),
        "execution_updates": False,
    }
