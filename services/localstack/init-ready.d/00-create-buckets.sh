#!/usr/bin/env bash
# Bootstrap S3 buckets that Kafka Connect sinks need on cluster start.
# Runs from LocalStack's ready.d hook once /_localstack/health returns
# healthy; awslocal auto-targets the local endpoint + fake creds.
set -euo pipefail

awslocal s3 mb s3://kafka-events-bucket || true
awslocal s3 mb s3://kafka-lab-artifacts || true
