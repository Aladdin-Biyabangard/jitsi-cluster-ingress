#!/usr/bin/env bash
# Bütün Jitsi VM-lərini start/stop edir (Cloud Scheduler → Pub/Sub → bu skript əvəzinə
# deploy.sh gcloud scheduler jobs yaradır ki, hər VM üçün start/stop çağırılsın).
#
# Manual:
#   ./scripts/schedule-all.sh start
#   ./scripts/schedule-all.sh stop

set -euo pipefail

ACTION="${1:?usage: schedule-all.sh start|stop}"
PROJECT_ID="${GCP_PROJECT_ID:?}"
ZONE="${GCP_ZONE:?}"

INSTANCES=(meet-control meet-jvb)
# recorder-1 .. recorder-N (və köhnə jibri-* adları) — bash 3.2 uyğun
while IFS= read -r _name; do
  [[ -n "${_name}" ]] && INSTANCES+=("${_name}")
done < <(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="name~^recorder- OR name~^jibri-" \
  --format="value(name)")

for name in "${INSTANCES[@]}"; do
  [[ -z "${name}" ]] && continue
  echo "[+] ${ACTION}: ${name}"
  gcloud compute instances "${ACTION}" "${name}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet || echo "[!] ${name} ${ACTION} failed (maybe already ${ACTION}ed)"
done

echo "Done: ${ACTION} ${#INSTANCES[@]} instances"
