#!/usr/bin/env bash
# GCP-də artıq olan Jitsi resurslarını Terraform state-ə import edir.
# Yarımçıq destroy / itmiş tfstate / Cloud Shell yenidən deploy zamanı 409 alreadyExists həll edir.
#
# İstifadə (deploy.sh çağırır):
#   GCP_PROJECT_ID=... GCP_REGION=... GCP_ZONE=... RECORDER_COUNT=2 ENABLE_SCHEDULE=true \
#     bash scripts/tf-import-existing.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

: "${GCP_PROJECT_ID:?}"
GCP_REGION="${GCP_REGION:-europe-west1}"
GCP_ZONE="${GCP_ZONE:-europe-west1-b}"
RECORDER_COUNT="${RECORDER_COUNT:-2}"
ENABLE_SCHEDULE="${ENABLE_SCHEDULE:-true}"

_log()  { echo -e "\033[0;32m[+]\033[0m $*"; }
_warn() { echo -e "\033[1;33m[!]\033[0m $*"; }

in_state() {
  terraform -chdir="${TF_DIR}" state show "$1" >/dev/null 2>&1
}

tf_import() {
  local addr="$1"
  shift
  local id err
  if in_state "${addr}"; then
    return 0
  fi
  # Bir neçə ID formatı cəhd et (provider versiyasına görə fərqlənə bilər)
  for id in "$@"; do
    _log "Import: ${addr} ← ${id}"
    err="$(mktemp)"
    if terraform -chdir="${TF_DIR}" import -input=false "${addr}" "${id}" >/dev/null 2>"${err}"; then
      rm -f "${err}"
      return 0
    fi
    # Artıq state-dədirsə — OK
    if in_state "${addr}"; then
      rm -f "${err}"
      return 0
    fi
    _warn "  cəhd uğursuz: $(tr '\n' ' ' <"${err}" | head -c 200)"
    rm -f "${err}"
  done
  _warn "Import alınmadı: ${addr}"
  return 0
}

addr_exists() {
  gcloud compute addresses describe "$1" \
    --project="${GCP_PROJECT_ID}" --region="${GCP_REGION}" \
    --format='value(name)' >/dev/null 2>&1
}

fw_exists() {
  gcloud compute firewall-rules describe "$1" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(name)' >/dev/null 2>&1
}

inst_exists() {
  gcloud compute instances describe "$1" \
    --project="${GCP_PROJECT_ID}" --zone="${GCP_ZONE}" \
    --format='value(name)' >/dev/null 2>&1
}

sa_exists() {
  gcloud iam service-accounts describe \
    "jitsi-scheduler@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(email)' >/dev/null 2>&1
}

_log "Mövcud GCP resursları Terraform state-ə yoxlanır/import edilir..."

# Cloud NAT (destroy yarımçıq qalanda tez-tez 409 alreadyExists verir)
router_exists() {
  gcloud compute routers describe "$1" \
    --project="${GCP_PROJECT_ID}" --region="${GCP_REGION}" \
    --format='value(name)' >/dev/null 2>&1
}
nat_exists() {
  gcloud compute routers nats describe "$1" \
    --router="$2" \
    --project="${GCP_PROJECT_ID}" --region="${GCP_REGION}" \
    --format='value(name)' >/dev/null 2>&1
}

if router_exists "jitsi-nat-router"; then
  tf_import 'google_compute_router.nat' \
    "projects/${GCP_PROJECT_ID}/regions/${GCP_REGION}/routers/jitsi-nat-router" \
    "${GCP_PROJECT_ID}/${GCP_REGION}/jitsi-nat-router"
fi
if nat_exists "jitsi-nat" "jitsi-nat-router"; then
  # google provider ID formatları
  tf_import 'google_compute_router_nat.nat' \
    "${GCP_PROJECT_ID}/${GCP_REGION}/jitsi-nat-router/jitsi-nat" \
    "projects/${GCP_PROJECT_ID}/regions/${GCP_REGION}/routers/jitsi-nat-router/nats/jitsi-nat"
fi

if addr_exists "jitsi-control-ip"; then
  tf_import 'google_compute_address.control' \
    "projects/${GCP_PROJECT_ID}/regions/${GCP_REGION}/addresses/jitsi-control-ip" \
    "${GCP_PROJECT_ID}/${GCP_REGION}/jitsi-control-ip"
fi
if addr_exists "jitsi-jvb-ip"; then
  tf_import 'google_compute_address.jvb' \
    "projects/${GCP_PROJECT_ID}/regions/${GCP_REGION}/addresses/jitsi-jvb-ip" \
    "${GCP_PROJECT_ID}/${GCP_REGION}/jitsi-jvb-ip"
fi

if fw_exists "jitsi-allow-web"; then
  tf_import 'google_compute_firewall.jitsi_web' \
    "projects/${GCP_PROJECT_ID}/global/firewalls/jitsi-allow-web" \
    "${GCP_PROJECT_ID}/jitsi-allow-web"
fi
if fw_exists "jitsi-allow-ssh"; then
  tf_import 'google_compute_firewall.jitsi_ssh' \
    "projects/${GCP_PROJECT_ID}/global/firewalls/jitsi-allow-ssh" \
    "${GCP_PROJECT_ID}/jitsi-allow-ssh"
fi
if fw_exists "jitsi-allow-media"; then
  tf_import 'google_compute_firewall.jitsi_media' \
    "projects/${GCP_PROJECT_ID}/global/firewalls/jitsi-allow-media" \
    "${GCP_PROJECT_ID}/jitsi-allow-media"
fi
if fw_exists "jitsi-allow-internal"; then
  tf_import 'google_compute_firewall.jitsi_internal' \
    "projects/${GCP_PROJECT_ID}/global/firewalls/jitsi-allow-internal" \
    "${GCP_PROJECT_ID}/jitsi-allow-internal"
fi

if inst_exists "meet-control"; then
  tf_import 'google_compute_instance.control' \
    "projects/${GCP_PROJECT_ID}/zones/${GCP_ZONE}/instances/meet-control" \
    "${GCP_PROJECT_ID}/${GCP_ZONE}/meet-control"
fi
if inst_exists "meet-jvb"; then
  tf_import 'google_compute_instance.jvb' \
    "projects/${GCP_PROJECT_ID}/zones/${GCP_ZONE}/instances/meet-jvb" \
    "${GCP_PROJECT_ID}/${GCP_ZONE}/meet-jvb"
fi

i=0
while (( i < RECORDER_COUNT )); do
  name="recorder-$((i + 1))"
  if inst_exists "${name}"; then
    tf_import "google_compute_instance.jibri[${i}]" \
      "projects/${GCP_PROJECT_ID}/zones/${GCP_ZONE}/instances/${name}" \
      "${GCP_PROJECT_ID}/${GCP_ZONE}/${name}"
  fi
  old="jibri-$((i + 1))"
  if inst_exists "${old}" && ! inst_exists "${name}"; then
    _warn "Köhnə VM ${old} var — əl ilə silin (indi recorder-* gözlənilir)"
  fi
  i=$((i + 1))
done

if [[ "${ENABLE_SCHEDULE}" == "true" ]] && sa_exists; then
  SA_EMAIL="jitsi-scheduler@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  tf_import 'google_service_account.scheduler[0]' \
    "projects/${GCP_PROJECT_ID}/serviceAccounts/${SA_EMAIL}" \
    "${SA_EMAIL}"
fi

_log "Import yoxlaması bitdi"
