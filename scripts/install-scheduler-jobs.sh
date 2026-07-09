#!/usr/bin/env bash
# Hər VM üçün Cloud Scheduler start/stop job yaradır
# (Terraform yalnız control üçün nümunə job yaradır; bu skript bütün floti əhatə edir)

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?}"
ZONE="${GCP_ZONE:?}"
REGION="${GCP_REGION:?}"
START_CRON="${SCHEDULE_START_CRON:?}"
STOP_CRON="${SCHEDULE_STOP_CRON:?}"
TZ_NAME="${SCHEDULE_TIMEZONE:-UTC}"
SA_EMAIL="${SCHEDULER_SA_EMAIL:?}"

INSTANCES=(meet-control meet-jvb)
mapfile -t JIBRIS < <(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="name~^recorder- OR name~^jibri-" \
  --format="value(name)")
INSTANCES+=("${JIBRIS[@]}")

ensure_job() {
  local name="$1" cron="$2" instance="$3" action="$4"
  local uri="https://compute.googleapis.com/compute/v1/projects/${PROJECT_ID}/zones/${ZONE}/instances/${instance}/${action}"

  if gcloud scheduler jobs describe "${name}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud scheduler jobs update http "${name}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${cron}" \
      --time-zone="${TZ_NAME}" \
      --uri="${uri}" \
      --http-method=POST \
      --oauth-service-account-email="${SA_EMAIL}" \
      --quiet
  else
    gcloud scheduler jobs create http "${name}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${cron}" \
      --time-zone="${TZ_NAME}" \
      --uri="${uri}" \
      --http-method=POST \
      --oauth-service-account-email="${SA_EMAIL}" \
      --quiet
  fi
  echo "[+] job ${name}"
}

for inst in "${INSTANCES[@]}"; do
  [[ -z "${inst}" ]] && continue
  ensure_job "jitsi-start-${inst}" "${START_CRON}" "${inst}" "start"
  ensure_job "jitsi-stop-${inst}" "${STOP_CRON}" "${inst}" "stop"
done

echo "Scheduler jobs ready for ${#INSTANCES[@]} instances"
