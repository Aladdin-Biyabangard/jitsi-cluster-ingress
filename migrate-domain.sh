#!/usr/bin/env bash
# ============================================================
# jitsi-cluster — domain köçürmə (OLD → NEW)
#
# Bütün VM-lərdə (control + jvb + recorders) Prosody/Nginx/config/
# Jicofo/JVB/Jibri + Let's Encrypt eyni anda yenilənir.
# Beləliklə nginx bir domain, Prosody başqa domain qalmır.
#
# İstifadə:
#   cp .env.example .env   # DOMAIN=yeni-domain
#   ./migrate-domain.sh --from meet.old.com --to meet.new.com
#
#   # NEW = .env DOMAIN, OLD avtomatik control-dan tapılır:
#   ./migrate-domain.sh --from meet.edulora.online
#
#   ./migrate-domain.sh --from OLD --to NEW --skip-le
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

chmod +x "${ROOT}/migrate-domain.sh" "${ROOT}/scripts/"*.sh 2>/dev/null || true

OLD=""
NEW=""
SKIP_LE=false
SKIP_DNS=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: ./migrate-domain.sh --from OLD_DOMAIN [--to NEW_DOMAIN] [options]

Options:
  --from DOMAIN     Köhnə meet domain (məcburi)
  --to DOMAIN       Yeni meet domain (default: .env DOMAIN)
  --skip-le         Let's Encrypt işə salma
  --skip-dns        Cloudflare DNS yeniləmə
  --dry-run         Yalnız planı göstər, dəyişmə
  -h, --help        Bu yardım

Nümunə:
  ./migrate-domain.sh --from meet.edulora.online --to meet.ingress.academy

Sonra portalda:
  JITSI_DOMAIN=<NEW>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) OLD="${2:-}"; shift 2 ;;
    --to)   NEW="${2:-}"; shift 2 ;;
    --skip-le)  SKIP_LE=true; shift ;;
    --skip-dns) SKIP_DNS=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Naməlum arg: $1 (./migrate-domain.sh --help)" ;;
  esac
done

[[ -n "${OLD}" ]] || die "--from OLD_DOMAIN lazımdır"

if [[ ! -f "${ROOT}/.env" ]]; then
  die ".env tapılmadı. Əvvəl: cp .env.example .env"
fi
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID .env-də lazımdır}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL .env-də lazımdır}"
GCP_ZONE="${GCP_ZONE:-europe-west1-b}"
GCP_REGION="${GCP_REGION:-europe-west1}"

if [[ -z "${NEW}" ]]; then
  NEW="${DOMAIN:-}"
fi
[[ -n "${NEW}" ]] || die "--to və ya .env DOMAIN lazımdır"
[[ "${OLD}" != "${NEW}" ]] || die "OLD və NEW eynidir: ${NEW}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || die "terraform/generated/outputs.json yoxdur — əvvəl deploy olunmalıdır"

CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip' "${OUTPUTS_JSON}")"
CONTROL_PRIVATE_IP="$(jq -r '.control_private_ip' "${OUTPUTS_JSON}")"
JVB_PUBLIC_IP="$(jq -r '.jvb_public_ip' "${OUTPUTS_JSON}")"
mapfile -t JIBRI_NAMES < <(jq -r '.jibri_names[]' "${OUTPUTS_JSON}")
mapfile -t JIBRI_PRIVATE_IPS < <(jq -r '.jibri_private_ips[]' "${OUTPUTS_JSON}")

SECRETS_DIR="${ROOT}/secrets"
SSH_PRIV="${SSH_PUBLIC_KEY_PATH:-}"
if [[ -n "${SSH_PRIV}" && -f "${SSH_PRIV}" ]]; then
  SSH_PRIV="${SSH_PRIV%.pub}"
else
  SSH_PRIV="${SECRETS_DIR}/deploy_key"
fi
[[ -f "${SSH_PRIV}" ]] || die "SSH private key yoxdur: ${SSH_PRIV}"

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -i "${SSH_PRIV}"
)

JUMP_OPTS=(
  -o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -i ${SSH_PRIV} -W %h:%p ubuntu@${CONTROL_PUBLIC_IP}"
)

cat <<EOF

${GREEN}========================================${NC}
${GREEN}  Domain migrate${NC}
${GREEN}========================================${NC}
  OLD:     ${OLD}
  NEW:     ${NEW}
  Control: ${CONTROL_PUBLIC_IP}
  JVB:     ${JVB_PUBLIC_IP}
  Recorders: ${#JIBRI_NAMES[@]}
  LE:      $([[ "${SKIP_LE}" == "true" ]] && echo skip || echo "yes (${ADMIN_EMAIL})")
  DNS:     $([[ "${SKIP_DNS}" == "true" ]] && echo skip || echo "cloudflare if token set")

EOF

# DNS preflight for NEW
NEW_IP="$(dig +short "${NEW}" A @8.8.8.8 2>/dev/null | head -1 || true)"
if [[ -z "${NEW_IP}" ]]; then
  warn "DNS: ${NEW} A record tapılmadı (8.8.8.8) — LE uğursuz ola bilər"
elif [[ "${NEW_IP}" != "${CONTROL_PUBLIC_IP}" ]]; then
  warn "DNS: ${NEW} → ${NEW_IP}, amma control ${CONTROL_PUBLIC_IP} — LE/SNI problem ola bilər"
else
  log "DNS OK: ${NEW} → ${CONTROL_PUBLIC_IP}"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  log "Dry-run — heç nə dəyişmədi"
  exit 0
fi

remote_sync() {
  local host="$1"
  shift
  local extra_opts=("$@")
  ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" \
    "sudo mkdir -p /tmp/jitsi-cluster && sudo chown ubuntu:ubuntu /tmp/jitsi-cluster"
  scp -q "${ssh_opts[@]}" "${extra_opts[@]}" -r \
    "${ROOT}/scripts" \
    "ubuntu@${host}:/tmp/jitsi-cluster/"
  ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" \
    "chmod +x /tmp/jitsi-cluster/scripts/*.sh"
}

run_role() {
  local host="$1"
  local role="$2"
  shift 2
  local extra_opts=("$@")
  log "→ ${role} @ ${host}"
  ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" "sudo bash -s" <<REMOTE
set -euo pipefail
export ROLE='${role}'
export OLD='${OLD}'
export NEW='${NEW}'
export ADMIN_EMAIL='${ADMIN_EMAIL}'
export SKIP_LE='${SKIP_LE}'
export CONTROL_PRIVATE_IP='${CONTROL_PRIVATE_IP}'
bash /tmp/jitsi-cluster/scripts/migrate-domain-on-host.sh
REMOTE
}

# ---------- Control ----------
log "Skriptlər control-a kopyalanır..."
remote_sync "${CONTROL_PUBLIC_IP}"
run_role "${CONTROL_PUBLIC_IP}" control

# ---------- JVB ----------
log "Skriptlər jvb-yə kopyalanır..."
remote_sync "${JVB_PUBLIC_IP}"
run_role "${JVB_PUBLIC_IP}" jvb

# ---------- Recorders ----------
for idx in "${!JIBRI_NAMES[@]}"; do
  name="${JIBRI_NAMES[$idx]}"
  ip="${JIBRI_PRIVATE_IPS[$idx]}"
  log "Recorder: ${name} (${ip})"
  remote_sync "${ip}" "${JUMP_OPTS[@]}"
  run_role "${ip}" jibri "${JUMP_OPTS[@]}"
done

# ---------- Local .env DOMAIN ----------
if grep -q '^DOMAIN=' "${ROOT}/.env"; then
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i.bak "s/^DOMAIN=.*/DOMAIN=${NEW}/" "${ROOT}/.env"
    rm -f "${ROOT}/.env.bak"
  else
    sed -i "s/^DOMAIN=.*/DOMAIN=${NEW}/" "${ROOT}/.env"
  fi
  log ".env DOMAIN → ${NEW}"
fi

# ---------- Cloudflare DNS (optional) ----------
if [[ "${SKIP_DNS}" != "true" && -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
  log "Cloudflare DNS: ${NEW} → ${CONTROL_PUBLIC_IP}"
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID
  export CLOUDFLARE_RECORD_NAME="${NEW}"
  export CONTROL_PUBLIC_IP
  bash "${ROOT}/scripts/update-dns-cloudflare.sh" || warn "DNS update uğursuz"
else
  warn "Cloudflare skip — əl ilə: ${NEW}  A  ${CONTROL_PUBLIC_IP}"
fi

# ---------- Verify ----------
log "Sertifikat yoxlanır..."
sleep 2
CERT_CN="$(echo | openssl s_client -connect "${NEW}:443" -servername "${NEW}" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null || true)"
echo "  ${CERT_CN:-openssl failed}"
if echo "${CERT_CN}" | grep -qF "${NEW}"; then
  log "TLS OK"
else
  warn "TLS hələ ${NEW} göstərmir — DNS/LE və nginx sites-enabled yoxlayın"
fi

CFG_SNIPPET="$(curl -fsS --max-time 10 "https://${NEW}/config.js" 2>/dev/null \
  | grep -E 'hosts\.domain|conferenceRequestUrl' | head -5 || true)"
if [[ -n "${CFG_SNIPPET}" ]]; then
  echo "${CFG_SNIPPET}"
  if echo "${CFG_SNIPPET}" | grep -qF "${OLD}"; then
    warn "config.js hələ OLD domain ehtiva edir!"
  else
    log "config.js NEW domain istifadə edir"
  fi
else
  warn "config.js oxuna bilmədi (TLS/DNS?)"
fi

cat <<EOF

${GREEN}========================================${NC}
${GREEN}  Migrate tamamlandı${NC}
${GREEN}========================================${NC}

  Meet URL:  https://${NEW}

  Portal (vacib):
    JITSI_DOMAIN=${NEW}
    # production .env / secret → restart portal

  Yoxla:
    echo | openssl s_client -connect ${NEW}:443 -servername ${NEW} 2>/dev/null \\
      | openssl x509 -noout -subject -ext subjectAltName
    curl -sS https://${NEW}/config.js | grep hosts.domain

  Köhnə domain (${OLD}) artıq istifadə olunmamalıdır.

EOF
