#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    printf 'Run this script through sudo.\n' >&2
    exit 1
fi

for managed_dir in /opt/pixelnow-remote-coop /var/www/pixelnow-remote-coop /etc/pixelnow-remote-coop; do
    if [[ -e "$managed_dir" && ! -f "$managed_dir/.managed-by-pixelnow-remote-coop" ]]; then
        printf 'Refusing to remove unmarked directory: %s\n' "$managed_dir" >&2
        exit 1
    fi
done

systemctl disable --now pixelnow-remote-coop.service pixelnow-remote-coop-turn.service 2>/dev/null || true
rm -f /etc/systemd/system/pixelnow-remote-coop.service
rm -f /etc/systemd/system/pixelnow-remote-coop-turn.service
rm -f /etc/nginx/sites-enabled/pixelnow-remote-coop
rm -f /etc/nginx/sites-available/pixelnow-remote-coop.conf
rm -f /etc/letsencrypt/renewal-hooks/deploy/pixelnow-remote-coop-turn
rm -f /usr/local/sbin/pixelnow-remote-coop-refresh-turn-certificate
systemctl daemon-reload
nginx -t
systemctl reload nginx
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw --force delete allow 38473/tcp comment 'PixelNOW Remote Co-Op HTTPS and signaling' || true
    ufw --force delete allow 38474/tcp comment 'PixelNOW Remote Co-Op TURN TCP' || true
    ufw --force delete allow 38474/udp comment 'PixelNOW Remote Co-Op TURN UDP' || true
    ufw --force delete allow 38475/tcp comment 'PixelNOW Remote Co-Op TURN TLS' || true
    ufw --force delete allow 40000:40100/udp comment 'PixelNOW Remote Co-Op TURN relay range' || true
fi
rm -rf /opt/pixelnow-remote-coop /var/www/pixelnow-remote-coop /etc/pixelnow-remote-coop
printf 'Removed the PixelNOW Remote Co-Op service files and its dedicated firewall rules.\n'
