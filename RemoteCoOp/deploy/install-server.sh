#!/bin/bash
set -euo pipefail

stage_root=${1:-}
if [[ $EUID -ne 0 ]]; then
    printf 'Run this installer through sudo.\n' >&2
    exit 1
fi
if [[ -z "$stage_root" || ! -d "$stage_root/RemoteCoOp" ]]; then
    printf 'Usage: sudo %s STAGED_REPOSITORY_ROOT\n' "$0" >&2
    exit 2
fi

node_bin=/home/jayian/.local/node22/bin/node
app_root=/opt/pixelnow-remote-coop
web_root=/var/www/pixelnow-remote-coop
config_root=/etc/pixelnow-remote-coop
nginx_available=/etc/nginx/sites-available/pixelnow-remote-coop.conf
nginx_enabled=/etc/nginx/sites-enabled/pixelnow-remote-coop
service_name=pixelnow-remote-coop
turn_service_name=pixelnow-remote-coop-turn
nginx_site_before=''

fail() {
    printf 'PixelNOW Remote Co-Op install failed: %s\n' "$1" >&2
    exit 1
}

for command_name in install nginx systemctl turnserver openssl curl ss ip; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[[ -x "$node_bin" ]] || fail "Node.js is missing at $node_bin"
[[ -x /usr/bin/turnserver ]] || fail 'Coturn is missing at /usr/bin/turnserver'
[[ -r /etc/letsencrypt/live/jayian.dev/fullchain.pem && -r /etc/letsencrypt/live/jayian.dev/privkey.pem ]] || fail 'the existing jayian.dev TLS certificate is not readable'
getent passwd jayian >/dev/null || fail 'the jayian service account does not exist'
getent passwd turnserver >/dev/null || fail 'the turnserver account does not exist'
[[ -d /etc/nginx/sites-enabled ]] || fail 'Nginx sites-enabled directory is missing'

for managed_dir in "$app_root" "$web_root" "$config_root"; do
    if [[ -e "$managed_dir" && ! -f "$managed_dir/.managed-by-pixelnow-remote-coop" ]]; then
        fail "$managed_dir exists without the PixelNOW ownership marker; refusing to replace it"
    fi
done
if [[ -e "$nginx_available" ]] && ! grep -q '^# Managed by PixelNOW Remote Co-Op deployment\.$' "$nginx_available"; then
    fail "$nginx_available exists without the PixelNOW ownership marker; refusing to replace it"
fi
if [[ -e "$nginx_enabled" && ! -L "$nginx_enabled" ]]; then
    fail "$nginx_enabled exists and is not a symlink; refusing to replace it"
fi
if [[ -L "$nginx_enabled" ]] && [[ "$(readlink "$nginx_enabled")" != "$nginx_available" ]]; then
    fail "$nginx_enabled points to a different site; refusing to replace it"
fi

for port in 38473 38474 38475 32190; do
    if ss -H -lntu | awk '{print $5}' | grep -Eq ":${port}$"; then
        fail "required port $port is already in use; no service or Nginx config was changed"
    fi
done

site_before=$(curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' --resolve jayian.dev:443:127.0.0.1 https://jayian.dev/ 2>/dev/null || true)
[[ "$site_before" =~ ^[23][0-9][0-9]$ ]] || fail 'could not verify the existing jayian.dev website through its 443 listener'

install -d -o jayian -g jayian -m 0755 "$app_root/server"
install -d -o www-data -g www-data -m 0755 "$web_root"
install -d -o root -g root -m 0751 "$config_root"
for managed_dir in "$app_root" "$web_root" "$config_root"; do
    install -o root -g root -m 0644 /dev/null "$managed_dir/.managed-by-pixelnow-remote-coop"
done
install -o jayian -g jayian -m 0644 "$stage_root/RemoteCoOp/server/direct-signaling.mjs" "$app_root/server/direct-signaling.mjs"
install -o www-data -g www-data -m 0644 "$stage_root/RemoteCoOp/browser/app.js" "$web_root/app.js"
install -o www-data -g www-data -m 0644 "$stage_root/RemoteCoOp/browser/index.html" "$web_root/index.html"
install -o www-data -g www-data -m 0644 "$stage_root/RemoteCoOp/browser/styles.css" "$web_root/styles.css"

shared_secret=''
if [[ -r "$config_root/server.env" ]]; then
    shared_secret=$(sed -n 's/^PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=//p' "$config_root/server.env" | head -n 1)
fi
if [[ ! "$shared_secret" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    shared_secret=$(openssl rand -hex 32)
fi
umask 077
cat > "$config_root/server.env" <<EOF
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=$shared_secret
PIXELNOW_REMOTE_COOP_MAX_GUESTS=3
EOF
chown root:jayian "$config_root/server.env"
chmod 0640 "$config_root/server.env"

install -d -o turnserver -g turnserver -m 0750 "$config_root/tls"
install -o turnserver -g turnserver -m 0640 /etc/letsencrypt/live/jayian.dev/fullchain.pem "$config_root/tls/fullchain.pem"
install -o turnserver -g turnserver -m 0640 /etc/letsencrypt/live/jayian.dev/privkey.pem "$config_root/tls/privkey.pem"
public_ipv4=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
[[ "$public_ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'could not determine the server public IPv4 address'

cat > "$config_root/turnserver.conf" <<EOF
listening-ip=0.0.0.0
relay-ip=$public_ipv4
external-ip=$public_ipv4
listening-port=38474
tls-listening-port=38475
min-port=40000
max-port=40100
realm=jayian.dev
server-name=jayian.dev
use-auth-secret
static-auth-secret=$shared_secret
cert=$config_root/tls/fullchain.pem
pkey=$config_root/tls/privkey.pem
fingerprint
no-cli
no-loopback-peers
no-multicast-peers
no-tlsv1
no-tlsv1_1
stale-nonce=600
log-file=stdout
simple-log
EOF
chown root:turnserver "$config_root/turnserver.conf"
chmod 0640 "$config_root/turnserver.conf"

install -o root -g root -m 0644 "$stage_root/RemoteCoOp/deploy/nginx/pixelnow-remote-coop.conf" "$nginx_available"
install -o root -g root -m 0644 "$stage_root/RemoteCoOp/deploy/systemd/pixelnow-remote-coop.service" "/etc/systemd/system/$service_name.service"
install -o root -g root -m 0644 "$stage_root/RemoteCoOp/deploy/systemd/pixelnow-remote-coop-turn.service" "/etc/systemd/system/$turn_service_name.service"
install -o root -g root -m 0750 "$stage_root/RemoteCoOp/deploy/refresh-turn-certificate.sh" /usr/local/sbin/pixelnow-remote-coop-refresh-turn-certificate
install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy

if [[ -e "$nginx_enabled" && ! -L "$nginx_enabled" ]]; then
    fail "$nginx_enabled exists and is not a symlink; refusing to replace it"
fi
if [[ -L "$nginx_enabled" ]]; then
    nginx_site_before=$(readlink "$nginx_enabled")
fi
ln -sfn "$nginx_available" "$nginx_enabled"
if ! nginx -t; then
    if [[ -n "$nginx_site_before" ]]; then
        ln -sfn "$nginx_site_before" "$nginx_enabled"
    else
        rm -f "$nginx_enabled"
    fi
    fail 'Nginx rejected the additive 38473 configuration; restored its previous site link'
fi

install -o root -g root -m 0755 "$stage_root/RemoteCoOp/deploy/refresh-turn-certificate.sh" /etc/letsencrypt/renewal-hooks/deploy/pixelnow-remote-coop-turn
systemctl daemon-reload
systemctl enable --now "$turn_service_name.service"
systemctl enable --now "$service_name.service"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 38473/tcp comment 'PixelNOW Remote Co-Op HTTPS and signaling'
    ufw allow 38474/tcp comment 'PixelNOW Remote Co-Op TURN TCP'
    ufw allow 38474/udp comment 'PixelNOW Remote Co-Op TURN UDP'
    ufw allow 38475/tcp comment 'PixelNOW Remote Co-Op TURN TLS'
    ufw allow 40000:40100/udp comment 'PixelNOW Remote Co-Op TURN relay range'
fi

nginx -t
systemctl reload nginx
sleep 1
curl --silent --show-error --fail --max-time 10 --resolve jayian.dev:32190:127.0.0.1 http://jayian.dev:32190/health >/dev/null
curl --silent --show-error --fail --max-time 10 --resolve jayian.dev:38473:127.0.0.1 https://jayian.dev:38473/health >/dev/null
site_after=$(curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' --resolve jayian.dev:443:127.0.0.1 https://jayian.dev/ 2>/dev/null || true)
[[ "$site_after" == "$site_before" ]] || fail "website response changed across the 443 reload (before=$site_before after=$site_after)"

printf 'PixelNOW Remote Co-Op is installed.\n'
printf 'Invite page: https://jayian.dev:38473/\n'
printf 'Signaling health: https://jayian.dev:38473/health\n'
printf 'Existing website response stayed HTTP %s on port 443.\n' "$site_after"
