#!/usr/bin/env bash
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:-}" # B8d3PXiuXMHkMa5j8Rer4bGptv0_LDK0bPiFVOZ9
CF_ZONE_ID="${CF_ZONE_ID:-33bb994a949e56a2cdaea7c0708b81de}"
CF_RECORD_ID="${CF_RECORD_ID:-37161c9a60faf0fa5d244b2f312ad351}"
CF_RECORD_NAME="${CF_RECORD_NAME:-live.blklst.fi}"

CURRENT_IP="$(curl -s https://api.ipify.org)"

echo "[CF] Current public IP: $CURRENT_IP"

curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{
    \"type\":\"A\",
    \"name\":\"${CF_RECORD_NAME}\",
    \"content\":\"${CURRENT_IP}\",
    \"ttl\":120,
    \"proxied\":false
  }" | jq .
