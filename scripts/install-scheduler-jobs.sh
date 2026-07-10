#!/usr/bin/env bash
# Hər VM üçün Cloud Scheduler start/stop job yaradır
# Həftəiçi (1–5) + şənbə (6) ayrı cədvəllər
# (Terraform yalnız SA yaradır; bu skript bütün floti əhatə edir)

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?}"
ZONE="${GCP_ZONE:?}"
REGION="${GCP_REGION:?}"
START_CRON="${SCHEDULE_START_CRON:?}"
STOP_CRON="${SCHEDULE_STOP_CRON:?}"
# Optional Saturday window (empty = skip)
SAT_START_CRON="${SCHEDULE_SAT_START_CRON:-}"
SAT_STOP_CRON="${SCHEDULE_SAT_STOP_CRON:-}"
TZ_NAME="${SCHEDULE_TIMEZONE:-UTC}"
SA_EMAIL="${SCHEDULER_SA_EMAIL:?}"

INSTANCES=(meet-control meet-jvb)
# bash 3 / zsh uyğun — mapfile yox
while IFS= read -r name; do
  [[ -n "${name}" ]] && INSTANCES+=("${name}")
done < <(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="name~^recorder- OR name~^jibri-" \
  --format="value(name)")

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
  # Resume if paused
  gcloud scheduler jobs resume "${name}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || true
  echo "[+] job ${name}  (${cron} ${TZ_NAME})"
}

for inst in "${INSTANCES[@]}"; do
  [[ -z "${inst}" ]] && continue
  # Həftəiçi (Mon–Fri)
  ensure_job "jitsi-start-${inst}" "${START_CRON}" "${inst}" "start"
  ensure_job "jitsi-stop-${inst}" "${STOP_CRON}" "${inst}" "stop"
  # Şənbə (Sat)
  if [[ -n "${SAT_START_CRON}" && -n "${SAT_STOP_CRON}" ]]; then
    ensure_job "jitsi-sat-start-${inst}" "${SAT_START_CRON}" "${inst}" "start"
    ensure_job "jitsi-sat-stop-${inst}" "${SAT_STOP_CRON}" "${inst}" "stop"
  fi
done

echo "Scheduler jobs ready for ${#INSTANCES[@]} instances"
