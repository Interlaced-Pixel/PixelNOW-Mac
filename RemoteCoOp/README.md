# PixelNOW Remote Co-Op

Remote Co-Op keeps the six-character PIN invite. The guest opens the link
copied by the host and enters the PIN if the link did not prefill it. A
signaling service matches the room and forwards WebRTC negotiation messages;
media and controller input use a direct peer connection whenever possible.
Coturn provides a TURN path when direct connectivity fails.

```text
host app ── WSS signaling ── guest browser
host app ══ direct WebRTC, or TURN-relayed WebRTC ══ guest browser
```

## Public service

- Guest page and HTTPS/WSS endpoint: `https://jayian.dev:38473/`
- Signaling path: `wss://jayian.dev:38473/remote-coop-direct`
- TURN over UDP/TCP: `jayian.dev:38474`
- TURN over TLS/TCP: `jayian.dev:38475`
- TURN UDP relay range: `40000-40100`

Port 38473 is an additive Nginx listener. The existing website on ports 80 and
443 is served by its current configuration and is not replaced or edited. The
new listener reuses the existing `jayian.dev` certificate. Node signaling is
bound to localhost on port 32190. Coturn runs as a separate service with its
own configuration and time-limited room credentials.

## Install and operate

From this repository checkout:

```sh
RemoteCoOp/deploy/deploy.sh jayian
```

The deploy command stages the service files over SSH and invokes the isolated
server installer with `sudo` (the server may prompt for its admin password).
To stage without installing, use `RemoteCoOp/deploy/deploy.sh --stage-only jayian`.
The installer checks the required ports and certificate,
installs separate PixelNOW systemd services and an additive Nginx site file,
tests the Nginx configuration before reload, and adds only the required
firewall rules. It does not edit the existing website files or listeners.

To inspect the service after deployment:

```sh
ssh jayian 'sudo systemctl status pixelnow-remote-coop pixelnow-remote-coop-turn'
ssh jayian 'sudo journalctl -u pixelnow-remote-coop -u pixelnow-remote-coop-turn -f'
```

To remove this deployment later, run `sudo /bin/bash ~/.cache/pixelnow-remote-coop-stage/RemoteCoOp/deploy/uninstall-server.sh` on the server. It removes only the PixelNOW Remote Co-Op units, files, firewall rules, and the added port 38473 Nginx site.

## Security and connection behavior

- The signaling server forwards room and peer-negotiation messages. It does
  not receive video, audio, or controller input.
- TURN credentials are generated per room, signed on the server, and expire.
- The signaling service limits message size and invite attempts and does not
  log room PINs, SDP, or TURN credentials.
- Direct ICE candidates are preferred. TURN carries media only when WebRTC
  cannot establish a direct route.
- STUN services provide address discovery; TURN is the media relay fallback.
- Restrictive firewalls can still block both direct and relay paths. External
  access must be verified after deployment from a network outside the host.
