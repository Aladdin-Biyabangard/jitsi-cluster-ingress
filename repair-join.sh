#!/usr/bin/env bash
# ============================================================
# repair-join.sh — "Not ready yet" / fərqli UI düzəlişi
#
# Domain köçürməsindən sonra JVB/focus/Jibri Prosody-yə
# qoşula bilməyəndə conference request "Not ready yet" verir
# və full meet UI (record daxil) açılmır.
#
# İstifadə (Cloud Shell / lokal):
#   ./repair-join.sh
#   ./repair-join.sh --domain meet.ingress.academy
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

chmod +x "${ROOT}/repair-join.sh" "${ROOT}/scripts/"*.sh 2>/dev/null || true

DOMAIN_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: ./repair-join.sh [--domain meet.example.com]"
      exit 0
      ;;
    *) die "Naməlum arg: $1" ;;
  esac
done

[[ -f "${ROOT}/.env" ]] || die ".env yoxdur"
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

: "${GCP_PROJECT_ID:?}"
GCP_ZONE="${GCP_ZONE:-europe-west1-b}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || die "terraform/generated/outputs.json yoxdur"

CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip' "${OUTPUTS_JSON}")"
CONTROL_PRIVATE_IP="$(jq -r '.control_private_ip' "${OUTPUTS_JSON}")"
JVB_PUBLIC_IP="$(jq -r '.jvb_public_ip' "${OUTPUTS_JSON}")"
mapfile -t JIBRI_NAMES < <(jq -r '.jibri_names[]' "${OUTPUTS_JSON}")
mapfile -t JIBRI_PRIVATE_IPS < <(jq -r '.jibri_private_ips[]' "${OUTPUTS_JSON}")

DOMAIN="${DOMAIN_OVERRIDE:-${DOMAIN:-}}"
[[ -n "${DOMAIN}" ]] || die "DOMAIN .env-də və ya --domain ilə lazımdır"

SECRETS_DIR="${ROOT}/secrets"
SSH_PRIV="${SSH_PUBLIC_KEY_PATH:-}"
if [[ -n "${SSH_PRIV}" && -f "${SSH_PRIV}" ]]; then
  SSH_PRIV="${SSH_PRIV%.pub}"
else
  SSH_PRIV="${SECRETS_DIR}/deploy_key"
fi
[[ -f "${SSH_PRIV}" ]] || die "SSH key yoxdur: ${SSH_PRIV}"

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

log "Repair join: domain=${DOMAIN}"
log "Control=${CONTROL_PUBLIC_IP}  JVB=${JVB_PUBLIC_IP}"

# ---------- 1) Control: Prosody users + restart ----------
log "Control: Prosody user-lər yenilənir..."
ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
DOMAIN='${DOMAIN}'
if [[ ! -f /opt/jitsi-cluster/cluster.env ]]; then
  echo "cluster.env yoxdur" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source /opt/jitsi-cluster/cluster.env
set +a
# DOMAIN cluster.env-də köhnə ola bilər — override
export DOMAIN

: "\${JVB_PASSWORD:?}"
: "\${JICOFO_PASSWORD:?}"
: "\${JIBRI_XMPP_PASS:?}"
: "\${JIBRI_RECORDER_PASS:?}"

# cluster.env DOMAIN-i də yeni saxla
if grep -q '^DOMAIN=' /opt/jitsi-cluster/cluster.env; then
  sed -i "s/^DOMAIN=.*/DOMAIN=\${DOMAIN}/" /opt/jitsi-cluster/cluster.env
else
  echo "DOMAIN=\${DOMAIN}" >> /opt/jitsi-cluster/cluster.env
fi

prosodyctl unregister jvb "auth.\${DOMAIN}" 2>/dev/null || true
prosodyctl unregister focus "auth.\${DOMAIN}" 2>/dev/null || true
prosodyctl unregister jibri "auth.\${DOMAIN}" 2>/dev/null || true
prosodyctl unregister recorder "recorder.\${DOMAIN}" 2>/dev/null || true

prosodyctl register jvb "auth.\${DOMAIN}" "\${JVB_PASSWORD}"
prosodyctl register focus "auth.\${DOMAIN}" "\${JICOFO_PASSWORD}"
prosodyctl register jibri "auth.\${DOMAIN}" "\${JIBRI_XMPP_PASS}"
prosodyctl register recorder "recorder.\${DOMAIN}" "\${JIBRI_RECORDER_PASS}"

# Jicofo brewery domain
if [[ -f /etc/jitsi/jicofo/jicofo.conf ]]; then
  sed -i "s/internal\\.auth\\.[a-zA-Z0-9.-]*/internal.auth.\${DOMAIN}/g" /etc/jitsi/jicofo/jicofo.conf || true
  sed -i "s/auth\\.[a-zA-Z0-9.-]*/auth.\${DOMAIN}/g" /etc/jitsi/jicofo/jicofo.conf || true
fi

systemctl restart prosody
sleep 2
systemctl restart jicofo
systemctl is-active prosody jicofo
echo "CONTROL_OK"
REMOTE

# Şifrələri control-dan oxu (JVB conf yeniləmək üçün)
PASSWORDS="$(ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" \
  "sudo grep -E '^(JVB_PASSWORD|JICOFO_PASSWORD|JIBRI_XMPP_PASS|JIBRI_RECORDER_PASS)=' /opt/jitsi-cluster/cluster.env")"
JVB_PASSWORD="$(echo "${PASSWORDS}" | sed -n 's/^JVB_PASSWORD=//p' | tr -d '\r')"
JIBRI_XMPP_PASS="$(echo "${PASSWORDS}" | sed -n 's/^JIBRI_XMPP_PASS=//p' | tr -d '\r')"
JIBRI_RECORDER_PASS="$(echo "${PASSWORDS}" | sed -n 's/^JIBRI_RECORDER_PASS=//p' | tr -d '\r')"
[[ -n "${JVB_PASSWORD}" ]] || die "JVB_PASSWORD oxuna bilmədi"

# ---------- 2) JVB: domain + password + restart ----------
log "JVB: conf + hosts + restart..."
ssh "${ssh_opts[@]}" "ubuntu@${JVB_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
DOMAIN='${DOMAIN}'
CONTROL_IP='${CONTROL_PRIVATE_IP}'
JVB_PASSWORD='${JVB_PASSWORD}'

# hosts
sed -i "/meet\\.edulora\\.online/d" /etc/hosts 2>/dev/null || true
grep -q "\${DOMAIN}" /etc/hosts || echo "\${CONTROL_IP} \${DOMAIN}" >> /etc/hosts
grep -q "auth.\${DOMAIN}" /etc/hosts || echo "\${CONTROL_IP} auth.\${DOMAIN}" >> /etc/hosts

if [[ ! -f /etc/jitsi/videobridge/jvb.conf ]]; then
  echo "jvb.conf yoxdur" >&2
  exit 1
fi

# Domain + password sync (köhnə domain qalıqlarını sil)
sed -i "s/meet\\.edulora\\.online/\${DOMAIN}/g" /etc/jitsi/videobridge/jvb.conf
sed -i "s/DOMAIN=\"auth\\.[^\"]*\"/DOMAIN=\"auth.\${DOMAIN}\"/" /etc/jitsi/videobridge/jvb.conf
sed -i "s/MUC_JIDS=\"jvbbrewery@internal\\.auth\\.[^\"]*\"/MUC_JIDS=\"jvbbrewery@internal.auth.\${DOMAIN}\"/" /etc/jitsi/videobridge/jvb.conf
sed -i "s/PASSWORD=\"[^\"]*\"/PASSWORD=\"\${JVB_PASSWORD}\"/" /etc/jitsi/videobridge/jvb.conf
# HOSTNAME should be control private IP
sed -i "s/HOSTNAME=\"[^\"]*\"/HOSTNAME=\"\${CONTROL_IP}\"/" /etc/jitsi/videobridge/jvb.conf

hostnamectl set-hostname "jvb.\${DOMAIN}" 2>/dev/null || true
systemctl restart jitsi-videobridge2
sleep 6
systemctl is-active jitsi-videobridge2
echo "=== jvb.conf shard ==="
grep -E 'HOSTNAME|DOMAIN|MUC_JIDS|USERNAME' /etc/jitsi/videobridge/jvb.conf || true
echo "=== jvb log ==="
journalctl -u jitsi-videobridge2 --since '45 sec ago' --no-pager | tail -40
REMOTE

# ---------- 3) Recorders ----------
for idx in "${!JIBRI_NAMES[@]}"; do
  name="${JIBRI_NAMES[$idx]}"
  ip="${JIBRI_PRIVATE_IPS[$idx]}"
  log "Recorder ${name} (${ip})..."
  ssh "${ssh_opts[@]}" "${JUMP_OPTS[@]}" "ubuntu@${ip}" "sudo bash -s" <<REMOTE
set -euo pipefail
DOMAIN='${DOMAIN}'
CONTROL_IP='${CONTROL_PRIVATE_IP}'
JIBRI_XMPP_PASS='${JIBRI_XMPP_PASS}'
JIBRI_RECORDER_PASS='${JIBRI_RECORDER_PASS}'

sed -i "/meet\\.edulora\\.online/d" /etc/hosts 2>/dev/null || true
grep -q "\${DOMAIN}" /etc/hosts || echo "\${CONTROL_IP} \${DOMAIN} auth.\${DOMAIN} recorder.\${DOMAIN}" >> /etc/hosts

if [[ -d /etc/jitsi/jibri/instances ]]; then
  for f in /etc/jitsi/jibri/instances/*.conf; do
    [[ -f "\$f" ]] || continue
    sed -i "s/meet\\.edulora\\.online/\${DOMAIN}/g" "\$f"
    sed -i "s/xmpp-domain = \"[^\"]*\"/xmpp-domain = \"\${DOMAIN}\"/" "\$f"
    sed -i "s/domain = \"internal\\.auth\\.[^\"]*\"/domain = \"internal.auth.\${DOMAIN}\"/" "\$f"
    sed -i "s/domain = \"auth\\.[^\"]*\"/domain = \"auth.\${DOMAIN}\"/" "\$f"
    sed -i "s/domain = \"recorder\\.[^\"]*\"/domain = \"recorder.\${DOMAIN}\"/" "\$f"
  done
  # control-login password (jibri) — ilk password= sətri adətən control-login-dadır
  # call-login password (recorder) — ikinci
  for f in /etc/jitsi/jibri/instances/*.conf; do
    [[ -f "\$f" ]] || continue
    awk -v jp="\${JIBRI_XMPP_PASS}" -v rp="\${JIBRI_RECORDER_PASS}" '
      /control-login/ { in_ctrl=1; in_call=0 }
      /call-login/ { in_call=1; in_ctrl=0 }
      in_ctrl && /password[[:space:]]*=/ && !done_ctrl {
        sub(/password[[:space:]]*=[[:space:]]*"[^"]*"/, "password = \"" jp "\"")
        done_ctrl=1
      }
      in_call && /password[[:space:]]*=/ && !done_call {
        sub(/password[[:space:]]*=[[:space:]]*"[^"]*"/, "password = \"" rp "\"")
        done_call=1
      }
      { print }
    ' "\$f" > "\$f.tmp" && mv "\$f.tmp" "\$f"
  done
fi

systemctl daemon-reload 2>/dev/null || true
for i in 1 2 3 4 5; do
  systemctl restart "jibri@\${i}" 2>/dev/null || true
done
sleep 3
systemctl is-active jibri@{1..5} 2>/dev/null || true
REMOTE
done

# ---------- 4) Verify from control ----------
log "Jicofo / bridge yoxlanır..."
ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
sleep 3
echo "=== jicofo (bridge/jibri) ==="
journalctl -u jicofo --since '2 min ago' --no-pager | grep -iE 'bridge|jvb|jibri|brewery|ready|error' | tail -40 || true
echo "=== prosody auth ==="
journalctl -u prosody --since '2 min ago' --no-pager | grep -iE 'jvb|focus|fail|error|not-authorized' | tail -20 || true
REMOTE

cat <<EOF

${GREEN}========================================${NC}
${GREEN}  repair-join tamamlandı${NC}
${GREEN}========================================${NC}

  Test (Incognito):
    https://${DOMAIN}/repair-test-\$(date +%s)

  Console-da "Not ready yet" OLMAMALIDIR.
  Otağa düşəndə toolbar + record ( ... menyusu) görünməlidir.

  Portal:
    JITSI_DOMAIN=${DOMAIN}

  JVB logda Authenticated/Joined yoxdursa:
    gcloud compute ssh meet-jvb --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} -- \\
      "sudo journalctl -u jitsi-videobridge2 -n 80 --no-pager"

EOF
