"""Trusted one-shot Fargate readiness probe; never receives work or dispatches builds.

Embedded in its dedicated task definition. Uses the real worker role, but never
prints environment values, credentials or database data. Not a consumer E2E.
"""

import json
import os
import re


def check():
    if not re.fullmatch(r"[0-9a-f]{32}", os.environ.get("SKY_PREFLIGHT_ID", "")):
        raise ValueError("A bounded operator-generated probe ID is required")
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
    from adapters.aws.job_queue import SqsOperationQueue
    from adapters.state.build_execution import PostgresBuildExecutionStore
    from adapters.state.deployment_admission import PostgresDeploymentAdmission
    from adapters.state.deployment_approvals import PostgresDeploymentApprovals
    from adapters.state.postgres import (
        PostgresStateSettings,
        RotatingDatabaseConnection,
    )
    from ports.remote_builds import BuildSettings

    settings = BuildSettings.from_environment(os.environ)
    config = Config(
        connect_timeout=5, read_timeout=10, retries={"total_max_attempts": 1}
    )
    session = boto3.Session(region_name=settings.region)
    if (
        session.client("sts", config=config).get_caller_identity()["Account"]
        != settings.account_id
    ):
        raise ValueError("Worker account mismatch")
    SqsOperationQueue(
        os.environ["SKY_JOB_QUEUE_URL"],
        region=settings.region,
        account_id=settings.account_id,
        client=object(),
    )
    database = RotatingDatabaseConnection(PostgresStateSettings.from_environment())
    PostgresDeploymentApprovals(
        PostgresDeploymentAdmission(
            PostgresBuildExecutionStore(
                database, workspace=os.environ["SKY_STATE_WORKSPACE"]
            ),
            account_id=settings.account_id,
            region=settings.region,
        )
    ).check_ready()
    with database() as connection:
        identity = connection.execute("SELECT current_user").fetchone()[0]
        tls = connection.execute(
            "SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()"
        ).fetchone()[0]
        if identity != "sky_build" or not tls:
            raise ValueError("Worker database identity or TLS mismatch")
    # A deliberately absent tag proves API authorization without running/pushing an image.
    response = session.client("ecr", config=config).batch_get_image(
        registryId=settings.account_id,
        repositoryName="sky-managed",
        imageIds=[
            {"imageTag": "sky-preflight-nonexistent-" + os.environ["SKY_PREFLIGHT_ID"]}
        ],
    )
    if (
        response.get("images")
        or len(response.get("failures", [])) != 1
        or response["failures"][0].get("failureCode") != "ImageNotFound"
    ):
        raise ValueError("Unexpected image probe result")
    try:
        session.client("secretsmanager", config=config).get_secret_value(
            SecretId=os.environ["SKY_PREFLIGHT_FORBIDDEN_SECRET_ARN"]
        )
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") != "AccessDeniedException":
            raise
    else:
        raise ValueError("Worker can read another runtime credential")
    return {
        "status": "passed",
        "database_identity": "sky_build",
        "database_tls": True,
        "approval_readiness": True,
        "queue_configuration_valid": True,
        "ecr_manifest_read_authorized": True,
        "api_secret_access_denied": True,
        "queue_received": False,
        "github_called": False,
        "deployment_started": False,
    }


if __name__ == "__main__":
    try:
        report = check()
    except Exception:
        print(
            json.dumps(
                {
                    "status": "failed",
                    "reason": "Worker infrastructure readiness failed; inspect configuration and permissions",
                }
            ),
            flush=True,
        )
        raise SystemExit(1) from None
    print(json.dumps(report), flush=True)
