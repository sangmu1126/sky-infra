"""Shared explicit runtime-role provisioning; callers supply reviewed constant grants.

Run as the state database/schema owner in an explicit transaction. Publish the
matching Secret before commit. No passwords/verifiers belong in logs or state.
"""


def provision(connection, password, *, role, marker_prefix, grants):
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
    marker = marker_prefix + database
    schema_owner = connection.execute(
        "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='sky_state'"
    ).fetchone()
    database_owner = connection.execute(
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()"
    ).fetchone()[0]
    if not schema_owner or schema_owner[0] != owner or database_owner != owner:
        raise ValueError("State schema owner must provision the runtime role")
    for table, _ in grants:
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
        (role,),
    ).fetchone()
    if existing:
        if any(existing[1:7]) or existing[7] != marker:
            raise ValueError(
                "Existing role is not the registered unprivileged runtime identity"
            )
        if connection.execute(
            "SELECT EXISTS(SELECT 1 FROM pg_auth_members WHERE member=%s OR "
            "(roleid=%s AND member<>(SELECT oid FROM pg_roles WHERE rolname=current_user))) OR "
            "EXISTS(SELECT 1 FROM pg_class WHERE relowner=%s) OR "
            "EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=%s) OR "
            "EXISTS(SELECT 1 FROM pg_database WHERE datdba=%s)",
            (existing[0],) * 5,
        ).fetchone()[0]:
            raise ValueError(
                "Runtime role must not inherit roles or own database objects"
            )
    else:
        connection.execute(
            sql.SQL(
                "CREATE ROLE {} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                "NOINHERIT NOREPLICATION NOBYPASSRLS"
            ).format(sql.Identifier(role))
        )
        connection.execute(
            sql.SQL("COMMENT ON ROLE {} IS {}").format(
                sql.Identifier(role), sql.Literal(marker)
            )
        )
    # libpq creates the salted SCRAM verifier locally; plaintext never enters SQL statements.
    verifier = connection.pgconn.encrypt_password(
        password.encode(), role.encode(), b"scram-sha-256"
    ).decode()
    connection.execute(
        sql.SQL("ALTER ROLE {} PASSWORD {} CONNECTION LIMIT 20").format(
            sql.Identifier(role), sql.Literal(verifier)
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
            sql.Identifier(database), sql.Identifier(role)
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL ON SCHEMA sky_state FROM {}").format(sql.Identifier(role))
    )
    connection.execute(
        sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA sky_state FROM {}").format(
            sql.Identifier(role)
        )
    )
    # Table-level REVOKE does not remove independent column ACLs.
    columns = connection.execute(
        "SELECT c.relname,array_agg(a.attname ORDER BY a.attnum) "
        "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
        "JOIN pg_attribute a ON a.attrelid=c.oid "
        "WHERE n.nspname='sky_state' AND c.relkind IN ('r','p') "
        "AND a.attnum>0 AND NOT a.attisdropped GROUP BY c.relname"
    ).fetchall()
    for table, names in columns:
        for grantee in (sql.Identifier(role), sql.SQL("PUBLIC")):
            connection.execute(
                sql.SQL(
                    "REVOKE ALL PRIVILEGES ({}) ON TABLE sky_state.{} FROM {}"
                ).format(
                    sql.SQL(", ").join(sql.Identifier(name) for name in names),
                    sql.Identifier(table),
                    grantee,
                )
            )
    connection.execute(
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(database), sql.Identifier(role)
        )
    )
    connection.execute(
        sql.SQL("GRANT USAGE ON SCHEMA sky_state TO {}").format(sql.Identifier(role))
    )
    for table, privileges in grants:
        connection.execute(
            sql.SQL("GRANT " + privileges + " ON TABLE sky_state.{} TO {}").format(
                sql.Identifier(table), sql.Identifier(role)
            )
        )
    connection.execute(
        sql.SQL(
            "ALTER ROLE {} IN DATABASE {} SET search_path TO pg_catalog, sky_state"
        ).format(sql.Identifier(role), sql.Identifier(database))
    )
    for name, value in (
        ("statement_timeout", "30s"),
        ("lock_timeout", "5s"),
        ("idle_in_transaction_session_timeout", "30s"),
    ):
        connection.execute(
            sql.SQL("ALTER ROLE {} IN DATABASE {} SET {} TO {}").format(
                sql.Identifier(role),
                sql.Identifier(database),
                sql.Identifier(name),
                sql.Literal(value),
            )
        )
    connection.execute(sql.SQL("ALTER ROLE {} LOGIN").format(sql.Identifier(role)))
    return {
        "role": role,
        "database": database,
        "schema": "sky_state",
        "ddl": False,
        "tenant_row_isolation": False,
    }
