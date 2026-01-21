import os
import json
import logging
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

RETENTION_DAYS = int(os.getenv("RETENTION_DAYS", "365"))
DRY_RUN = os.getenv("DRY_RUN", "false").lower() == "true"
AWS_REGION = os.getenv("AWS_REGION")  # optional


def lambda_handler(event, context):
    """
    Deletes EBS snapshots owned by this account older than RETENTION_DAYS.
    Intended to run in a private subnet; NAT enables access to AWS public APIs.
    """
    logger.info("Event: %s", json.dumps(event))
    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    logger.info("RETENTION_DAYS=%d | cutoff_utc=%s | DRY_RUN=%s", RETENTION_DAYS, cutoff.isoformat(), DRY_RUN)

    ec2 = boto3.client("ec2", region_name=AWS_REGION) if AWS_REGION else boto3.client("ec2")
    paginator = ec2.get_paginator("describe_snapshots")

    examined = deleted = failed = 0

    try:
        for page in paginator.paginate(OwnerIds=["self"]):
            for snap in page.get("Snapshots", []):
                examined += 1
                snapshot_id = snap.get("SnapshotId")
                start_time = snap.get("StartTime")

                if not snapshot_id or not start_time:
                    logger.warning("Skipping snapshot with missing fields: %s", snap)
                    continue

                if start_time >= cutoff:
                    continue

                logger.info("Eligible snapshot: %s | StartTime=%s", snapshot_id, start_time.isoformat())

                if DRY_RUN:
                    logger.info("[DRY_RUN] Would delete snapshot: %s", snapshot_id)
                    continue

                try:
                    logger.info("Deleting snapshot: %s", snapshot_id)
                    ec2.delete_snapshot(SnapshotId=snapshot_id)
                    deleted += 1
                except ClientError as e:
                    failed += 1
                    logger.error("Delete failed for %s: %s", snapshot_id, e, exc_info=True)

    except ClientError as e:
        logger.error("DescribeSnapshots failed: %s", e, exc_info=True)
        raise

    result = {
        "retention_days": RETENTION_DAYS,
        "cutoff_utc": cutoff.isoformat(),
        "dry_run": DRY_RUN,
        "examined": examined,
        "deleted": deleted,
        "failed": failed,
    }
    logger.info("Summary: %s", json.dumps(result))
    return result
