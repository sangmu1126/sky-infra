"""External deadline enforcement for registered credential-free build VMs only."""

import json
import os
import re
from datetime import UTC, datetime

import boto3
from botocore.config import Config


def reap(event, *, ec2, queue, environment, now):
    profile, vpc, group = (environment[key] for key in ("SKY_SANDBOX_PROFILE", "SKY_SANDBOX_VPC", "SKY_SANDBOX_GROUP"))
    if not isinstance(event, dict) or set(event) not in ({"job_id"}, {"mode"}):
        raise ValueError("Exact reaper request required")
    filters = [{"Name": "tag:app", "Values": ["sky"]},
               {"Name": "tag:sky:SandboxProfile", "Values": [profile]},
               {"Name": "vpc-id", "Values": [vpc]},
               {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}]
    if "job_id" in event:
        if not isinstance(event["job_id"], str) or not re.fullmatch(r"[0-9a-f-]{36}", event["job_id"]):
            raise ValueError("Pinned sandbox job identity required")
        filters.append({"Name": "tag:sky:JobId", "Values": [event["job_id"]]})
    elif event["mode"] != "sweep":
        raise ValueError("Registered sweep mode required")
    selected, pages = [], 0
    options = {"Filters": filters, "MaxResults": 100}
    while True:
        response = ec2.describe_instances(**options)
        pages += 1
        for reservation in response.get("Reservations", []):
            if reservation.get("OwnerId") != environment["SKY_ACCOUNT_ID"]:
                raise ValueError("Reaper account mismatch")
            for instance in reservation["Instances"]:
                tags = {item["Key"]: item["Value"] for item in instance.get("Tags", [])}
                if (instance.get("VpcId") != vpc or {x["GroupId"] for x in instance.get("SecurityGroups", [])} != {group}
                        or tags.get("app") != "sky" or tags.get("sky:SandboxProfile") != profile):
                    raise ValueError("Reaper scope mismatch")
                launched = instance["LaunchTime"].timestamp()
                deadline = tags.get("sky:DeadlineEpoch", "")
                valid = deadline.isdecimal() and launched - 1800 <= int(deadline) <= launched + int(environment["SKY_MAX_LIFETIME"])
                # A malformed deadline never buys an unlimited owned VM. Wait
                # at most the registered lifetime from the AWS launch time.
                expired = now.timestamp() >= (int(deadline) if valid else launched + int(environment["SKY_MAX_LIFETIME"]))
                if expired:
                    selected.append(instance["InstanceId"])
        token = response.get("NextToken")
        if not token:
            break
        if pages >= 5:
            raise ValueError("Reaper inventory bound exceeded; operator review required")
        options["NextToken"] = token
    if selected:
        ec2.terminate_instances(InstanceIds=selected)
        queue.send_message(QueueUrl=environment["SKY_REVIEW_QUEUE"], MessageBody=json.dumps({
            "version": 1, "kind": "sandbox_deadline_enforced", "profile": profile,
            "instances": selected, "observed_at": now.isoformat(),
            "security_clearance": False, "operator_review_required": True,
        }))
    return {"terminated": len(selected), "scope": profile, "security_clearance": False}


def handler(event, _context):
    config = Config(connect_timeout=3, read_timeout=8, retries={"total_max_attempts": 1})
    return reap(event, ec2=boto3.client("ec2", config=config), queue=boto3.client("sqs", config=config),
                environment=os.environ, now=datetime.now(UTC))
