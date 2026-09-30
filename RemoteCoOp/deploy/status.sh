#!/bin/sh
set -eu

target=${1:-jayian}
if [ "$target" = "jayian" ]; then
    ssh -o HostKeyAlias=jayian jayian@198.12.95.48 'systemctl --no-pager --full status pixelnow-remote-coop.service pixelnow-remote-coop-turn.service; printf "\nPublic health: "; curl --silent --show-error --max-time 10 https://jayian.dev:38473/health; printf "\n"'
else
    ssh "$target" 'systemctl --no-pager --full status pixelnow-remote-coop.service pixelnow-remote-coop-turn.service; printf "\nPublic health: "; curl --silent --show-error --max-time 10 https://jayian.dev:38473/health; printf "\n"'
fi
