#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--stage-only] [ssh-target]\n' "$0"
}

stage_only=0
if [ "${1:-}" = "--stage-only" ]; then
    stage_only=1
    shift
fi
target=${1:-jayian}
case "$target" in
    -*|'') usage >&2; exit 2 ;;
esac

ssh_remote() {
    if [ "$target" = "jayian" ]; then
        ssh -o HostKeyAlias=jayian jayian@198.12.95.48 "$@"
    else
        ssh "$target" "$@"
    fi
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
remote_stage=".cache/pixelnow-remote-coop-stage"

command -v ssh >/dev/null 2>&1 || { printf 'ssh is required.\n' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { printf 'tar is required.\n' >&2; exit 1; }

COPYFILE_DISABLE=1 tar --format=ustar -C "$repo_root" -czf - \
    RemoteCoOp/browser/app.js \
    RemoteCoOp/browser/index.html \
    RemoteCoOp/browser/styles.css \
    RemoteCoOp/server/direct-signaling.mjs \
    RemoteCoOp/deploy/install-server.sh \
    RemoteCoOp/deploy/nginx/pixelnow-remote-coop.conf \
    RemoteCoOp/deploy/systemd/pixelnow-remote-coop.service \
    RemoteCoOp/deploy/systemd/pixelnow-remote-coop-turn.service \
    RemoteCoOp/deploy/refresh-turn-certificate.sh \
    RemoteCoOp/deploy/uninstall-server.sh |
    ssh_remote "mkdir -p '$remote_stage' && tar -xzf - -C '$remote_stage'"

printf 'Staged Remote Co-Op deployment at %s:~/%s\n' "$target" "$remote_stage"
if [ "$stage_only" -eq 1 ]; then
    if [ "$target" = "jayian" ]; then
        printf 'Run the installer with: ssh -t -o HostKeyAlias=jayian jayian@198.12.95.48 '
    else
        printf 'Run the installer with: ssh -t %s ' "$target"
    fi
    printf "'sudo /bin/bash ~/%s/RemoteCoOp/deploy/install-server.sh ~/%s'\n" "$remote_stage" "$remote_stage"
    exit 0
fi

ssh_remote -t "sudo /bin/bash ~/$remote_stage/RemoteCoOp/deploy/install-server.sh ~/$remote_stage"
