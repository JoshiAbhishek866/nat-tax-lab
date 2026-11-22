#!/usr/bin/env bash
# Pushes ~3 GiB of S3 traffic from the PRIVATE instance (1 upload + 2 downloads of a 1 GiB file).
# Runs from your laptop. Uses SSM Run Command, so no SSH and no open ports.
# Usage: ./scripts/generate-traffic.sh            (reads terraform outputs)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_ID="$(terraform output -raw instance_id)"
BUCKET="$(terraform output -raw bucket_name)"

read -r -d '' REMOTE <<SCRIPT || true
set -e
cd /tmp
[ -f lab-1g.bin ] || dd if=/dev/urandom of=lab-1g.bin bs=1M count=1024 status=none
aws s3 cp lab-1g.bin s3://${BUCKET}/lab-1g.bin --only-show-errors --region ${REGION}
for i in 1 2; do
  aws s3 cp s3://${BUCKET}/lab-1g.bin /tmp/dl.bin --only-show-errors --region ${REGION}
done
rm -f /tmp/dl.bin
echo "S3 traffic done at \$(date -u +%FT%TZ)"
SCRIPT

PARAMS="$(jq -n --arg c "$REMOTE" '{commands: [$c], executionTimeout: ["1800"]}')"

echo "Start (UTC): $(date -u +%FT%TZ)"
CMD_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "$PARAMS" \
  --query Command.CommandId --output text)"

echo "SSM command: $CMD_ID (waiting...)"
while true; do
  STATUS="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Pending|InProgress|Delayed) sleep 10 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' --output yaml
echo "End (UTC): $(date -u +%FT%TZ)"
