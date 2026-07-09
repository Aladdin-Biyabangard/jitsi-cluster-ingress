#!/usr/bin/env bash
# Bütün infrastrukturu silir (VM, IP, firewall, scheduler)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${ROOT}/.env" ]]; then
  echo ".env lazımdır"
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

echo "⚠️  Bu ${GCP_PROJECT_ID} layihəsindəki Jitsi resurslarını SİLƏCƏK."
read -r -p "Davam? (yes yazın): " ans
[[ "${ans}" == "yes" ]] || exit 1

gcloud config set project "${GCP_PROJECT_ID}" >/dev/null

# shellcheck source=scripts/install-prereqs.sh
source "${ROOT}/scripts/install-prereqs.sh"
ensure_deploy_prerequisites

# Scheduler jobs
GCP_REGION="${GCP_REGION:-europe-west1}"
if gcloud scheduler jobs list --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --format='value(name)' 2>/dev/null | grep -q jitsi; then
  while read -r job; do
    [[ -z "${job}" ]] && continue
    gcloud scheduler jobs delete "${job}" --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --quiet || true
  done < <(gcloud scheduler jobs list --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --format='value(name)' | grep jitsi || true)
fi

# Terraform state yoxdursa — qalan VM/IP-ləri gcloud ilə təmizlə
if [[ -d "${ROOT}/terraform/.terraform" ]] || [[ -f "${ROOT}/terraform/terraform.tfstate" ]]; then
  terraform -chdir="${ROOT}/terraform" init -input=false >/dev/null 2>&1 || true
  terraform -chdir="${ROOT}/terraform" destroy -auto-approve -input=false || true
fi

echo "[+] Qalan Jitsi VM / IP / firewall təmizlənir (gcloud)..."
ZONE="${GCP_ZONE:-europe-west1-b}"
REGION="${GCP_REGION:-europe-west1}"

while read -r name; do
  [[ -z "${name}" ]] && continue
  echo "  delete instance: ${name}"
  gcloud compute instances delete "${name}" --project="${GCP_PROJECT_ID}" --zone="${ZONE}" --quiet || true
done < <(gcloud compute instances list --project="${GCP_PROJECT_ID}" \
  --filter="name~(^meet-control$|^meet-jvb$|^recorder-|^jibri-)" \
  --format='value(name)' 2>/dev/null || true)

while read -r name; do
  [[ -z "${name}" ]] && continue
  echo "  delete address: ${name}"
  gcloud compute addresses delete "${name}" --project="${GCP_PROJECT_ID}" --region="${REGION}" --quiet || true
done < <(gcloud compute addresses list --project="${GCP_PROJECT_ID}" \
  --filter="name~(jitsi-control-ip|jitsi-jvb-ip)" \
  --format='value(name)' 2>/dev/null || true)

while read -r name; do
  [[ -z "${name}" ]] && continue
  echo "  delete firewall: ${name}"
  gcloud compute firewall-rules delete "${name}" --project="${GCP_PROJECT_ID}" --quiet || true
done < <(gcloud compute firewall-rules list --project="${GCP_PROJECT_ID}" \
  --filter="name~^jitsi-allow-" \
  --format='value(name)' 2>/dev/null || true)

# Köhnə state qarışıqlığı (jibri-* vs recorder-*) — təmiz start
echo "[+] Terraform state təmizlənir..."
rm -f "${ROOT}/terraform/terraform.tfstate" \
      "${ROOT}/terraform/terraform.tfstate.backup" \
      "${ROOT}/terraform/.terraform.lock.hcl" 2>/dev/null || true
rm -rf "${ROOT}/terraform/.terraform" 2>/dev/null || true

echo "Silindi."
