#!/usr/bin/env bash
# Scheduler aktivdirsə → pause edir və VM-ləri açıq saxlayır (lazımdırsa start).
#
# İstifadə:
#   ./scripts/scheduler-pause-keep-on.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

PROJECT_ID="${GCP_PROJECT_ID:?GCP_PROJECT_ID lazımdır (.env)}"
REGION="${GCP_REGION:?GCP_REGION lazımdır (.env)}"
ZONE="${GCP_ZONE:?GCP_ZONE lazımdır (.env)}"

list_jitsi_jobs() {
  gcloud scheduler jobs list \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --format='value(name)' 2>/dev/null | grep jitsi || true
}

any_enabled() {
  local name state
  while IFS=$'\t' read -r name state; do
    [[ -z "${name}" ]] && continue
    case "${name}" in
      *jitsi*) ;;
      *) continue ;;
    esac
    if [[ "${state}" == "ENABLED" ]]; then
      return 0
    fi
  done < <(gcloud scheduler jobs list \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --format='value(name,state)' 2>/dev/null || true)
  return 1
}

JOBS="$(list_jitsi_jobs)"
if [[ -z "${JOBS}" ]]; then
  echo "[!] jitsi scheduler job tapılmadı — yalnız VM-lər start ediləcək"
else
  if any_enabled; then
    echo "[+] Scheduler aktivdir — pause edilir..."
    while IFS= read -r job; do
      [[ -z "${job}" ]] && continue
      echo "    pause: ${job}"
      gcloud scheduler jobs pause "${job}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet 2>/dev/null || echo "    [!] ${job} pause uğursuz (artıq PAUSED ola bilər)"
    done <<< "${JOBS}"
  else
    echo "[+] Scheduler artıq deaktivdir (PAUSED) — skip"
  fi
fi

echo "[+] VM-lər açıq saxlanılır (start)..."
export GCP_PROJECT_ID="${PROJECT_ID}" GCP_ZONE="${ZONE}"
bash "${ROOT}/scripts/schedule-all.sh" start

echo "Done: scheduler pause + server aktiv"
