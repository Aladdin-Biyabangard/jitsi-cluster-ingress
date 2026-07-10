#!/usr/bin/env bash
# Scheduler deaktivdirsə → resume edir; indi schedule pəncərəsindədirsə VM-ləri start edir.
#
# İstifadə:
#   ./scripts/scheduler-resume.sh

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
TZ_NAME="${SCHEDULE_TIMEZONE:-UTC}"
START_HHMM="${SCHEDULE_START_UTC:-03:30}"
STOP_HHMM="${SCHEDULE_STOP_UTC:-06:05}"
WEEKDAYS="${SCHEDULE_WEEKDAYS:-1-5}"
SAT_START="${SCHEDULE_SAT_START_UTC:-}"
SAT_STOP="${SCHEDULE_SAT_STOP_UTC:-}"

hhmm_to_int() {
  # "19:30" → 1930
  local t="$1"
  local hh="${t%%:*}"
  local mm="${t##*:}"
  # strip leading zeros for arithmetic
  hh=$((10#$hh))
  mm=$((10#$mm))
  echo $((hh * 100 + mm))
}

dow_in_weekdays() {
  # WEEKDAYS like "1-5" or "1,2,3,4,5" or "1-5,6"
  local dow="$1"
  local part
  local IFS=','
  for part in ${WEEKDAYS}; do
    if [[ "${part}" == *-* ]]; then
      local a="${part%%-*}" b="${part##*-}"
      if (( dow >= a && dow <= b )); then
        return 0
      fi
    elif [[ "${part}" == "${dow}" ]]; then
      return 0
    fi
  done
  return 1
}

in_schedule_window() {
  local dow now_int start_i stop_i
  dow="$(TZ="${TZ_NAME}" date +%u)"   # 1=Mon … 7=Sun
  now_int="$(TZ="${TZ_NAME}" date +%H%M)"
  now_int=$((10#$now_int))

  # Şənbə pəncərəsi
  if [[ "${dow}" == "6" && -n "${SAT_START}" && -n "${SAT_STOP}" ]]; then
    start_i="$(hhmm_to_int "${SAT_START}")"
    stop_i="$(hhmm_to_int "${SAT_STOP}")"
    if (( now_int >= start_i && now_int < stop_i )); then
      return 0
    fi
    return 1
  fi

  # Həftəiçi (və digər WEEKDAYS)
  if dow_in_weekdays "${dow}"; then
    start_i="$(hhmm_to_int "${START_HHMM}")"
    stop_i="$(hhmm_to_int "${STOP_HHMM}")"
    if (( now_int >= start_i && now_int < stop_i )); then
      return 0
    fi
  fi
  return 1
}

any_paused() {
  local name state
  while IFS=$'\t' read -r name state; do
    [[ -z "${name}" ]] && continue
    case "${name}" in
      *jitsi*) ;;
      *) continue ;;
    esac
    if [[ "${state}" == "PAUSED" ]]; then
      return 0
    fi
  done < <(gcloud scheduler jobs list \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --format='value(name,state)' 2>/dev/null || true)
  return 1
}

JOBS="$(gcloud scheduler jobs list \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(name)' 2>/dev/null | grep jitsi || true)"

if [[ -z "${JOBS}" ]]; then
  echo "[x] jitsi scheduler job tapılmadı — əvvəl deploy / install-scheduler-jobs.sh lazımdır" >&2
  exit 1
fi

if any_paused; then
  echo "[+] Scheduler deaktivdir — resume edilir..."
  while IFS= read -r job; do
    [[ -z "${job}" ]] && continue
    echo "    resume: ${job}"
    gcloud scheduler jobs resume "${job}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --quiet 2>/dev/null || echo "    [!] ${job} resume uğursuz (artıq ENABLED ola bilər)"
  done <<< "${JOBS}"
else
  echo "[+] Scheduler artıq aktivdir (ENABLED) — skip resume"
fi

NOW_LOCAL="$(TZ="${TZ_NAME}" date '+%a %H:%M %Z')"
if in_schedule_window; then
  echo "[+] İndi schedule pəncərəsindədir (${NOW_LOCAL}) — VM-lər start..."
  export GCP_PROJECT_ID="${PROJECT_ID}" GCP_ZONE="${ZONE}"
  bash "${ROOT}/scripts/schedule-all.sh" start
else
  echo "[+] İndi schedule pəncərəsi xaricindədir (${NOW_LOCAL}) — VM start edilmir"
  echo "    Həftəiçi: ${START_HHMM}→${STOP_HHMM} (${WEEKDAYS})"
  if [[ -n "${SAT_START}" && -n "${SAT_STOP}" ]]; then
    echo "    Şənbə:    ${SAT_START}→${SAT_STOP}"
  fi
  echo "    Timezone: ${TZ_NAME}"
fi

echo "Done: scheduler resume"
