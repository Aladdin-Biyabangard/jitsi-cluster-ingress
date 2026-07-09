#!/usr/bin/env bash
# Cloudflare A record yenilə (optional)

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ZONE_ID:?}"
: "${CLOUDFLARE_RECORD_NAME:?}"
: "${CONTROL_PUBLIC_IP:?}"

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")

RECORD_ID="$(curl -sS "${API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${CLOUDFLARE_RECORD_NAME}" \
  "${AUTH[@]}" | jq -r '.result[0].id // empty')"

if [[ -z "${RECORD_ID}" ]]; then
  echo "[+] Creating A record ${CLOUDFLARE_RECORD_NAME} → ${CONTROL_PUBLIC_IP}"
  curl -sS -X POST "${API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    "${AUTH[@]}" \
    --data "{\"type\":\"A\",\"name\":\"${CLOUDFLARE_RECORD_NAME}\",\"content\":\"${CONTROL_PUBLIC_IP}\",\"ttl\":120,\"proxied\":false}" \
    | jq -r '.success'
else
  echo "[+] Updating A record ${CLOUDFLARE_RECORD_NAME} → ${CONTROL_PUBLIC_IP}"
  curl -sS -X PUT "${API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${RECORD_ID}" \
    "${AUTH[@]}" \
    --data "{\"type\":\"A\",\"name\":\"${CLOUDFLARE_RECORD_NAME}\",\"content\":\"${CONTROL_PUBLIC_IP}\",\"ttl\":120,\"proxied\":false}" \
    | jq -r '.success'
fi
