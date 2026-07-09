#!/usr/bin/env bash
# meet-jvb: dedicated Videobridge (remote XMPP to meet-control)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root

DOMAIN="${DOMAIN:?}"
CONTROL_PRIVATE_IP="${CONTROL_PRIVATE_IP:?}"
JVB_PASSWORD="${JVB_PASSWORD:?}"
JVB_PUBLIC_IP="${JVB_PUBLIC_IP:-$(public_ip)}"
LOCAL_IP="$(private_ip)"

log "JVB setup: public=${JVB_PUBLIC_IP} private=${LOCAL_IP} control=${CONTROL_PRIVATE_IP}"

install_base
add_jitsi_repo
apply_sysctl "${SCRIPT_DIR}/../config/sysctl-jitsi.conf"

hostnamectl set-hostname "jvb.${DOMAIN}"
grep -q "${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} ${DOMAIN} auth.${DOMAIN}" >> /etc/hosts
grep -q "auth.${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} auth.${DOMAIN}" >> /etc/hosts

debconf-set-selections <<EOF
jitsi-videobridge2 jitsi-videobridge/jvb-hostname string ${DOMAIN}
EOF

wait_apt
apt-get install -y jitsi-videobridge2

# Heap for 9 concurrent rooms
mkdir -p /etc/systemd/system/jitsi-videobridge2.service.d
cat > /etc/systemd/system/jitsi-videobridge2.service.d/override.conf <<EOF
[Service]
Environment="VIDEOBRIDGE_MAX_MEMORY=12288m"
LimitNOFILE=65000
LimitNPROC=65000
LimitMEMLOCK=infinity
EOF

NICKNAME="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

# Live server jvb-custom.conf + remote XMPP / ICE mapping
cat > /etc/jitsi/videobridge/jvb.conf <<JVB
videobridge {
    cc {
        use-vla-target-bitrate = true
        trust-bwe = true
    }
    ice {
        udp {
            port = 10000
        }
        tcp {
            port = 4443
            enabled = true
        }
        advertise-private-addresses = false
    }
    apis {
        xmpp-client {
            configs {
                shard {
                    HOSTNAME="${CONTROL_PRIVATE_IP}"
                    PORT="5222"
                    DOMAIN="auth.${DOMAIN}"
                    USERNAME="jvb"
                    PASSWORD="${JVB_PASSWORD}"
                    MUC_JIDS="jvbbrewery@internal.auth.${DOMAIN}"
                    MUC_NICKNAME="${NICKNAME}"
                    DISABLE_CERTIFICATE_VERIFICATION=true
                }
            }
        }
    }
    sctp {
        enabled = true
    }
    stats {
        enabled = true
    }
    load {
        last-n = 20
    }
}
ice4j {
    harvest {
        mapping {
            static-mappings = [
                {
                    local-address = "${LOCAL_IP}"
                    public-address = "${JVB_PUBLIC_IP}"
                }
            ]
            stun {
                addresses = ["meet-jit-si-turnrelay.jitsi.net:443"]
            }
            aws {
                enabled = false
            }
        }
    }
}
JVB

ufw_base
ufw allow 10000/udp
ufw allow 4443/tcp
ufw --force enable

systemctl daemon-reload
systemctl restart jitsi-videobridge2
systemctl enable jitsi-videobridge2

sleep 3
if journalctl -u jitsi-videobridge2 --no-pager -n 30 | grep -qi "Authenticated\|Joined MUC\|Connected"; then
  log "JVB Prosody-yə qoşuldu"
else
  warn "JVB loglarını yoxlayın: journalctl -u jitsi-videobridge2 -n 50"
fi

log "JVB hazır"
