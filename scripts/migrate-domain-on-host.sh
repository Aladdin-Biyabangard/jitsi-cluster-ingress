#!/usr/bin/env bash
# ============================================================
# Bir VM-də domain köçürmə (control | jvb | jibri)
# Çağırış: ROLE=control OLD=... NEW=... sudo bash migrate-domain-on-host.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root

ROLE="${ROLE:?ROLE=control|jvb|jibri}"
OLD="${OLD:?OLD domain required}"
NEW="${NEW:?NEW domain required}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SKIP_LE="${SKIP_LE:-false}"
CONTROL_PRIVATE_IP="${CONTROL_PRIVATE_IP:-}"

if [[ "${OLD}" == "${NEW}" ]]; then
  die "OLD və NEW eynidir: ${NEW}"
fi

# sed üçün domain escape (nöqtələr)
esc() { printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'; }
OLD_ESC="$(esc "${OLD}")"
NEW_ESC="$(esc "${NEW}")"

replace_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qF "${OLD}" "$f" 2>/dev/null; then
    sed -i "s/${OLD_ESC}/${NEW}/g" "$f"
    log "  updated: $f"
  fi
}

replace_tree() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  # Only text-ish configs; skip binaries / recordings
  while IFS= read -r -d '' f; do
    replace_in_file "$f"
  done < <(find "$dir" -type f \
    \( -name '*.conf' -o -name '*.cfg' -o -name '*.cfg.lua' -o -name '*.js' \
       -o -name '*.json' -o -name '*.env' -o -name '*.sh' -o -name '*.yml' \
       -o -name '*.yaml' -o -name '*.properties' -o -name '*.xml' \
       -o -name '*.service' -o -name 'config' -o -name 'sip-communicator.properties' \) \
    -print0 2>/dev/null)
}

ensure_hosts_line() {
  local ip="$1"
  shift
  local names=("$@")
  local line="${ip}"
  local n
  for n in "${names[@]}"; do
    line+=" ${n}"
  done
  # Remove old domain mentions from /etc/hosts lines we manage
  sed -i "/${OLD_ESC}/d" /etc/hosts 2>/dev/null || true
  for n in "${names[@]}"; do
    grep -qE "[[:space:]]${n//./\\.}([[:space:]]|$)" /etc/hosts 2>/dev/null || true
  done
  # Drop stale lines that only had OLD; add fresh
  if ! grep -qF "${NEW}" /etc/hosts 2>/dev/null; then
    echo "${line}" >> /etc/hosts
    log "  /etc/hosts += ${line}"
  else
    # Ensure auth/recorder aliases exist
    for n in "${names[@]}"; do
      if ! grep -qE "[[:space:]]${n//./\\.}([[:space:]]|$)" /etc/hosts; then
        echo "${ip} ${n}" >> /etc/hosts
        log "  /etc/hosts += ${ip} ${n}"
      fi
    done
  fi
}

migrate_control() {
  log "CONTROL: ${OLD} → ${NEW}"

  # --- Prosody ---
  local old_prosody="/etc/prosody/conf.avail/${OLD}.cfg.lua"
  local new_prosody="/etc/prosody/conf.avail/${NEW}.cfg.lua"
  if [[ -f "${old_prosody}" ]]; then
    cp -a "${old_prosody}" "${new_prosody}"
    sed -i "s/${OLD_ESC}/${NEW}/g" "${new_prosody}"
    log "  prosody cfg: ${new_prosody}"
  elif [[ -f "${new_prosody}" ]]; then
    warn "  prosody artıq ${NEW} — yalnız sed/təmizlik"
    sed -i "s/${OLD_ESC}/${NEW}/g" "${new_prosody}" || true
  else
    die "Prosody cfg tapılmadı: ${old_prosody} və ${new_prosody}"
  fi
  rm -f "/etc/prosody/conf.d/${OLD}.cfg.lua"
  ln -sfn "${new_prosody}" "/etc/prosody/conf.d/${NEW}.cfg.lua"

  # --- Meet config.js ---
  local old_cfg="/etc/jitsi/meet/${OLD}-config.js"
  local new_cfg="/etc/jitsi/meet/${NEW}-config.js"
  if [[ -f "${old_cfg}" ]]; then
    cp -a "${old_cfg}" "${new_cfg}"
    sed -i "s/${OLD_ESC}/${NEW}/g" "${new_cfg}"
  elif [[ -f "${new_cfg}" ]]; then
    sed -i "s/${OLD_ESC}/${NEW}/g" "${new_cfg}"
  else
    die "Meet config tapılmadı: ${old_cfg}"
  fi
  # Interface / other meet files
  for f in /etc/jitsi/meet/*; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.crt|*.key|*.pem) continue ;;
    esac
    replace_in_file "$f"
  done

  # Copy LE/self-signed certs if NEW missing but OLD exists (before LE)
  if [[ ! -f "/etc/jitsi/meet/${NEW}.crt" && -f "/etc/jitsi/meet/${OLD}.crt" ]]; then
    cp -a "/etc/jitsi/meet/${OLD}.crt" "/etc/jitsi/meet/${NEW}.crt"
    cp -a "/etc/jitsi/meet/${OLD}.key" "/etc/jitsi/meet/${NEW}.key"
    log "  temporary cert copied ${OLD} → ${NEW} (LE sonra yeniləyəcək)"
  fi

  # Prosody certs: main domain = LE/meet cert; auth.* = CN-specific self-signed
  mkdir -p /etc/prosody/certs
  if [[ -f "/etc/jitsi/meet/${NEW}.crt" ]]; then
    cp -f "/etc/jitsi/meet/${NEW}.crt" "/etc/prosody/certs/${NEW}.crt"
    cp -f "/etc/jitsi/meet/${NEW}.key" "/etc/prosody/certs/${NEW}.key"
  fi
  for h in "auth.${NEW}" "guest.${NEW}" "recorder.${NEW}" "conference.${NEW}" "internal.auth.${NEW}" "focus.${NEW}"; do
    openssl req -new -x509 -days 3650 -nodes \
      -out "/etc/prosody/certs/${h}.crt" \
      -keyout "/etc/prosody/certs/${h}.key" \
      -subj "/CN=${h}" >/dev/null 2>&1 || true
  done
  chown -R root:prosody /etc/prosody/certs 2>/dev/null || chown -R prosody:prosody /etc/prosody/certs || true
  chmod 640 /etc/prosody/certs/*.key 2>/dev/null || true
  chmod 644 /etc/prosody/certs/*.crt 2>/dev/null || true

  # Jicofo: brewery lowercase + disable cert verify (LE SAN ≠ auth.*)
  if [[ -f /etc/jitsi/jicofo/jicofo.conf ]]; then
    sed -i "s/${OLD_ESC}/${NEW}/g" /etc/jitsi/jicofo/jicofo.conf
    sed -i 's/JvbBrewery@/jvbbrewery@/g; s/JibriBrewery@/jibribrewery@/g' /etc/jitsi/jicofo/jicofo.conf
    if ! grep -q 'disable-certificate-verification' /etc/jitsi/jicofo/jicofo.conf; then
      sed -i '/username: "focus"/a\      disable-certificate-verification: true' /etc/jitsi/jicofo/jicofo.conf || true
    fi
  fi

  # --- Nginx ---
  local old_ngx="/etc/nginx/sites-available/${OLD}.conf"
  local new_ngx="/etc/nginx/sites-available/${NEW}.conf"
  if [[ -f "${old_ngx}" ]]; then
    cp -a "${old_ngx}" "${new_ngx}"
  fi
  if [[ -f "${new_ngx}" ]]; then
    sed -i "s/${OLD_ESC}/${NEW}/g" "${new_ngx}"
  elif [[ -f "${old_ngx}" ]]; then
    die "nginx conf copy failed"
  else
    # Maybe already renamed path but content still OLD, or only NEW name with OLD content
    if [[ -f "/etc/nginx/sites-available/${NEW}.conf" ]]; then
      sed -i "s/${OLD_ESC}/${NEW}/g" "/etc/nginx/sites-available/${NEW}.conf"
    else
      warn "nginx site conf tapılmadı — əl ilə yoxlayın"
    fi
  fi
  rm -f "/etc/nginx/sites-enabled/${OLD}.conf"
  rm -f "/etc/nginx/sites-enabled/${OLD}"
  if [[ -f "${new_ngx}" ]]; then
    ln -sfn "${new_ngx}" "/etc/nginx/sites-enabled/${NEW}.conf"
  fi
  # Disable any leftover enabled sites still naming OLD
  find /etc/nginx/sites-enabled -maxdepth 1 -type l 2>/dev/null | while read -r link; do
    if readlink "$link" 2>/dev/null | grep -qF "${OLD}"; then
      rm -f "$link"
      log "  removed stale nginx link: $link"
    fi
  done

  # --- Jicofo / coturn / sip ---
  replace_tree /etc/jitsi/jicofo
  replace_in_file /etc/turnserver.conf
  replace_in_file /etc/jitsi/videobridge/sip-communicator.properties
  replace_tree /etc/jitsi/videobridge

  # cluster.env
  if [[ -f /opt/jitsi-cluster/cluster.env ]]; then
    replace_in_file /opt/jitsi-cluster/cluster.env
    # Ensure DOMAIN= line
    if grep -q '^DOMAIN=' /opt/jitsi-cluster/cluster.env; then
      sed -i "s/^DOMAIN=.*/DOMAIN=${NEW}/" /opt/jitsi-cluster/cluster.env
    else
      echo "DOMAIN=${NEW}" >> /opt/jitsi-cluster/cluster.env
    fi
  fi

  hostnamectl set-hostname "${NEW}" || true
  local cip
  cip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ensure_hosts_line "${cip:-127.0.0.1}" "${NEW}"

  # Prosody users (passwords from cluster.env)
  if [[ -f /opt/jitsi-cluster/cluster.env ]]; then
    # shellcheck disable=SC1091
    set -a
    # shellcheck source=/dev/null
    source /opt/jitsi-cluster/cluster.env
    set +a
  fi
  : "${JVB_PASSWORD:?cluster.env-də JVB_PASSWORD yoxdur}"
  : "${JICOFO_PASSWORD:?cluster.env-də JICOFO_PASSWORD yoxdur}"
  : "${JIBRI_XMPP_PASS:?cluster.env-də JIBRI_XMPP_PASS yoxdur}"
  : "${JIBRI_RECORDER_PASS:?cluster.env-də JIBRI_RECORDER_PASS yoxdur}"

  log "Prosody istifadəçiləri (${NEW})..."
  prosodyctl unregister jvb "auth.${NEW}" 2>/dev/null || true
  prosodyctl unregister focus "auth.${NEW}" 2>/dev/null || true
  prosodyctl unregister jibri "auth.${NEW}" 2>/dev/null || true
  prosodyctl unregister recorder "recorder.${NEW}" 2>/dev/null || true
  prosodyctl register jvb "auth.${NEW}" "${JVB_PASSWORD}"
  prosodyctl register focus "auth.${NEW}" "${JICOFO_PASSWORD}"
  prosodyctl register jibri "auth.${NEW}" "${JIBRI_XMPP_PASS}"
  prosodyctl register recorder "recorder.${NEW}" "${JIBRI_RECORDER_PASS}"

  # Let's Encrypt
  if [[ "${SKIP_LE}" != "true" ]]; then
    local email="${ADMIN_EMAIL:-}"
    if [[ -z "${email}" ]]; then
      warn "ADMIN_EMAIL boş — LE skip"
    elif [[ -x /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh ]]; then
      log "Let's Encrypt: ${NEW}..."
      nginx -t && systemctl reload nginx || systemctl restart nginx
      set +e
      echo "y" | /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh "${email}" "${NEW}"
      local le_rc=$?
      set -e
      if [[ "${le_rc}" -ne 0 ]]; then
        warn "Let's Encrypt uğursuz (DNS/80?) — self-signed/köhnə cert qala bilər"
      else
        # Refresh prosody certs from LE install path (main domain only;
        # auth.* must stay CN-specific self-signed)
        if [[ -f "/etc/jitsi/meet/${NEW}.crt" ]]; then
          cp -f "/etc/jitsi/meet/${NEW}.crt" "/etc/prosody/certs/${NEW}.crt"
          cp -f "/etc/jitsi/meet/${NEW}.key" "/etc/prosody/certs/${NEW}.key"
          for h in "auth.${NEW}" "guest.${NEW}" "recorder.${NEW}" "conference.${NEW}" "internal.auth.${NEW}" "focus.${NEW}"; do
            openssl req -new -x509 -days 3650 -nodes \
              -out "/etc/prosody/certs/${h}.crt" \
              -keyout "/etc/prosody/certs/${h}.key" \
              -subj "/CN=${h}" >/dev/null 2>&1 || true
          done
          chown -R root:prosody /etc/prosody/certs 2>/dev/null || true
          chmod 640 /etc/prosody/certs/*.key 2>/dev/null || true
        fi
      fi
    else
      warn "install-letsencrypt-cert.sh yoxdur"
    fi
  else
    warn "SKIP_LE=true — sertifikat əl ilə"
  fi

  nginx -t
  systemctl restart prosody
  systemctl restart jicofo
  systemctl restart coturn 2>/dev/null || systemctl restart turnserver 2>/dev/null || true
  systemctl reload nginx || systemctl restart nginx

  log "CONTROL yoxlama:"
  grep -E "hosts\.domain|conferenceRequestUrl|websocket" "/etc/jitsi/meet/${NEW}-config.js" | head -8 || true
  ls -la /etc/nginx/sites-enabled/ || true
  ls /etc/prosody/conf.d/ || true
  for svc in prosody jicofo nginx; do
    systemctl is-active --quiet "$svc" && echo "  ✓ $svc" || echo "  ✗ $svc"
  done
}

migrate_jvb() {
  log "JVB: ${OLD} → ${NEW}"
  : "${CONTROL_PRIVATE_IP:?CONTROL_PRIVATE_IP lazımdır}"

  replace_in_file /etc/jitsi/videobridge/jvb.conf
  replace_tree /etc/jitsi/videobridge
  replace_in_file /etc/jitsi/videobridge/sip-communicator.properties

  hostnamectl set-hostname "jvb.${NEW}" || true
  ensure_hosts_line "${CONTROL_PRIVATE_IP}" "${NEW}" "auth.${NEW}"

  systemctl restart jitsi-videobridge2
  systemctl is-active --quiet jitsi-videobridge2 && echo "  ✓ jitsi-videobridge2" || echo "  ✗ jitsi-videobridge2"
  grep -E 'DOMAIN|HOSTNAME|MUC_JIDS' /etc/jitsi/videobridge/jvb.conf | head -10 || true
}

migrate_jibri() {
  log "JIBRI: ${OLD} → ${NEW}"
  : "${CONTROL_PRIVATE_IP:?CONTROL_PRIVATE_IP lazımdır}"

  replace_tree /etc/jitsi/jibri
  replace_tree /opt/jitsi-jibri
  replace_in_file /opt/jitsi-jibri/bunny.env
  # instance confs
  if [[ -d /etc/jitsi/jibri/instances ]]; then
    replace_tree /etc/jitsi/jibri/instances
  fi

  ensure_hosts_line "${CONTROL_PRIVATE_IP}" "${NEW}" "auth.${NEW}" "recorder.${NEW}"

  # Restart all jibri slots
  if systemctl list-unit-files 'jibri@*' >/dev/null 2>&1; then
    systemctl restart 'jibri@*' 2>/dev/null || true
    # Explicit 1..8 common range
    local i
    for i in $(seq 1 8); do
      systemctl restart "jibri@${i}" 2>/dev/null || true
    done
  else
    systemctl restart jibri 2>/dev/null || true
  fi
  systemctl list-units 'jibri*' --state=running --no-pager 2>/dev/null | head -20 || true
}

case "${ROLE}" in
  control) migrate_control ;;
  jvb)     migrate_jvb ;;
  jibri)   migrate_jibri ;;
  *)       die "Naməlum ROLE=${ROLE}" ;;
esac

log "ROLE=${ROLE} tamam: ${OLD} → ${NEW}"
