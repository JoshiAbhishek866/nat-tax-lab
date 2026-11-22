#!/usr/bin/env bash
# How many bytes did a NAT gateway PROCESS (what you are billed for) in a time window?
# Billed data processing = BytesInFromSource + BytesInFromDestination.
#
# Usage: ./scripts/nat-bytes.sh <nat-gateway-id> <start-utc> <end-utc> [price-per-GB]
#   e.g. ./scripts/nat-bytes.sh nat-0abc 2026-11-17T10:00:00Z 2026-11-17T10:30:00Z
#        ./scripts/nat-bytes.sh nat-0abc "$(date -u -d '30 days ago' +%FT%TZ)" "$(date -u +%FT%TZ)"
set -euo pipefail

NAT_ID="$1"; START="$2"; END="$3"; PRICE="${4:-0.045}"
REGION="${AWS_REGION:-us-east-1}"

WINDOW=$(( $(date -u -d "$END" +%s) - $(date -u -d "$START" +%s) ))
# CloudWatch returns at most 1,440 datapoints per call. Pick a period that fits.
if   [ "$WINDOW" -le 86400 ];   then PERIOD=60
elif [ "$WINDOW" -le 432000 ];  then PERIOD=300
else                                 PERIOD=3600
fi

sum_metric() {
  aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/NATGateway --metric-name "$1" \
    --dimensions Name=NatGatewayId,Value="$NAT_ID" \
    --start-time "$START" --end-time "$END" \
    --period "$PERIOD" --statistics Sum \
    --query 'sum(Datapoints[].Sum)' --output text
}

FROM_SOURCE="$(sum_metric BytesInFromSource)"
FROM_DEST="$(sum_metric BytesInFromDestination)"
[ "$FROM_SOURCE" = "None" ] && FROM_SOURCE=0
[ "$FROM_DEST" = "None" ] && FROM_DEST=0

awk -v s="$FROM_SOURCE" -v d="$FROM_DEST" -v p="$PRICE" 'BEGIN {
  gib = (s + d) / (1024 ^ 3)
  printf "Sent out by your VPC (BytesInFromSource):        %10.2f GiB\n", s / (1024 ^ 3)
  printf "Came back from internet (BytesInFromDestination): %10.2f GiB\n", d / (1024 ^ 3)
  printf "Total processed by NAT:                           %10.2f GiB\n", gib
  printf "Data processing cost at $%s/GB:                  $%9.2f\n", p, gib * p
}'
