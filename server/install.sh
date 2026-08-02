#!/bin/bash
# install.sh — place the wid-dle-wemote server components and generate the
# on-box secrets. Idempotent: safe to re-run. Never overwrites existing secrets.
#
#   sudo ./install.sh
#
# Prerequisites (not installed here — they involve a third-party apt key and
# your own review; see server/README.md):
#   - Kismet (kismet-core, kismet-capture-linux-wifi) from kismetwireless.net
#   - mosquitto, redis-server, iw, rfkill, tcpdump, bc
#   - python3 packages: paho-mqtt, redis, prometheus-client, scapy, pyyaml
#   - AR9271 firmware if you use those radios (see README §1)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo ./install.sh"; exit 1; }

echo "==> directories"
install -d -m 750 /etc/wids
install -d -m 755 /var/lib/wids
install -d -m 700 /root/.kismet

echo "==> operator tools -> /usr/local/sbin"
for f in "$HERE"/bin/*; do
    install -m 755 "$f" "/usr/local/sbin/$(basename "$f")"
done

echo "==> config"
install -m 640 "$HERE/config/wids.yaml"                 /etc/wids/wids.yaml
install -m 644 "$HERE/config/radios.conf"               /etc/wids/radios.conf
install -m 644 "$HERE/README.md"                        /etc/wids/README.md
install -m 644 "$HERE/config/dnsmasq-wlp2s0-ap.conf"    /etc/dnsmasq.d/wlp2s0-ap.conf
install -m 644 "$HERE/config/mosquitto-wids.conf"       /etc/mosquitto/conf.d/wids.conf
install -m 644 "$HERE/config/udev-70-wids-monitor-names.rules" /etc/udev/rules.d/70-wids-monitor-names.rules
install -m 600 "$HERE/config/netplan-60-wlp2s0-ap.yaml" /etc/netplan/60-wlp2s0-ap.yaml
install -d -m 755 /etc/hostapd
install -m 600 "$HERE/config/hostapd.conf"              /etc/hostapd/hostapd.conf
install -d -m 755 /etc/kismet
# kismet_site.conf is group-readable by kismet
install -m 640 "$HERE/config/kismet_site.conf"          /etc/kismet/kismet_site.conf
getent group kismet >/dev/null && chgrp kismet /etc/kismet/kismet_site.conf || true

echo "==> systemd units"
for u in "$HERE"/systemd/*.service "$HERE"/systemd/*.timer; do
    install -m 644 "$u" "/etc/systemd/system/$(basename "$u")"
done
for d in "$HERE"/systemd/*.service.d; do
    [[ -d $d ]] || continue
    name="$(basename "$d")"
    install -d -m 755 "/etc/systemd/system/$name"
    for c in "$d"/*.conf; do
        install -m 644 "$c" "/etc/systemd/system/$name/$(basename "$c")"
    done
done

echo "==> secrets (generated once, never shipped)"
if [[ ! -f /etc/wids/kismet.creds ]]; then
    umask 077
    { echo "KISMET_USER=widsro"
      echo "KISMET_PASS=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
    } > /etc/wids/kismet.creds
    chmod 600 /etc/wids/kismet.creds
    echo "    generated /etc/wids/kismet.creds"
else
    echo "    /etc/wids/kismet.creds exists — left as-is"
fi
# Kismet reads its httpd credential from here
if [[ ! -f /root/.kismet/kismet_httpd.conf ]]; then
    . /etc/wids/kismet.creds
    umask 077
    { echo "httpd_username=${KISMET_USER}"
      echo "httpd_password=${KISMET_PASS}"
    } > /root/.kismet/kismet_httpd.conf
    chmod 600 /root/.kismet/kismet_httpd.conf
    echo "    generated /root/.kismet/kismet_httpd.conf"
fi

# AP passphrase: offer to generate one if still the placeholder
if grep -q '^wpa_passphrase=CHANGE_ME_PSK' /etc/hostapd/hostapd.conf; then
    PSK="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
    sed -i "s|^wpa_passphrase=CHANGE_ME_PSK|wpa_passphrase=${PSK}|" /etc/hostapd/hostapd.conf
    echo "    set a random AP passphrase (read it: grep ^wpa_passphrase= /etc/hostapd/hostapd.conf)"
fi

echo "==> reload"
systemctl daemon-reload
udevadm control --reload-rules

cat <<'NEXT'

Installed. Next:
  1. Edit /etc/wids/radios.conf — replace the placeholder MACs with your radios'
     real MACs (ip -br link), and the udev rules file to match. Or use
     wids-add-radio per stick.
  2. Enable + start the stack:
       systemctl enable --now hostapd dnsmasq mosquitto redis-server
       systemctl enable --now wids-monitor.service wids-monitor-watchdog.timer
       systemctl enable --now kismet wids-detect wids-chanctl
  3. Verify:  sudo wids-healthcheck
Full manual: /etc/wids/README.md
NEXT
