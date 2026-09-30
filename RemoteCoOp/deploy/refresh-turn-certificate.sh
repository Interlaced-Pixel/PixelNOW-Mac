#!/bin/sh
set -eu

certificate_dir=/etc/letsencrypt/live/jayian.dev
destination_dir=/etc/pixelnow-remote-coop/tls
service_name=pixelnow-remote-coop-turn.service

[ -r "$certificate_dir/fullchain.pem" ]
[ -r "$certificate_dir/privkey.pem" ]
install -d -o turnserver -g turnserver -m 0750 "$destination_dir"
install -o turnserver -g turnserver -m 0640 "$certificate_dir/fullchain.pem" "$destination_dir/fullchain.pem"
install -o turnserver -g turnserver -m 0640 "$certificate_dir/privkey.pem" "$destination_dir/privkey.pem"
if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    systemctl restart "$service_name"
fi
