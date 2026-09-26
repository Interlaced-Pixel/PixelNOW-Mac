# PixelNOW Remote Co-Op

Remote Co-Op uses a relayless peer-to-peer topology:

```text
guest browser ── direct WebRTC media/data ── host app
      \────── short-lived room rendezvous ──────/
```

The server only holds a room while the host and guest exchange WebRTC
offers, answers, and candidates. It never carries video, audio, or controller
input. A direct connection failure is reported to the user; there is no
server-side media fallback.

## Components

- `browser/index.html` and `browser/app.js` are the guest client.
- `server/direct-signaling.mjs` is the room rendezvous service.
- `run-servers.mjs` starts exactly one rendezvous service.
- `App/RemoteCoOp/remote-coop-direct-config.json` documents the direct-only WebRTC policy.

## Run the rendezvous service

```sh
node RemoteCoOp/run-servers.mjs
```

Defaults bind the service to `198.12.95.48:32189`. For a LAN deployment:

```sh
PIXELNOW_REMOTE_COOP_DIRECT_BIND_HOST=192.168.1.25 \
PIXELNOW_REMOTE_COOP_DIRECT_PORT=32189 \
node RemoteCoOp/run-servers.mjs
```

Use `PIXELNOW_REMOTE_COOP_DIRECT_CERT` and
`PIXELNOW_REMOTE_COOP_DIRECT_KEY` together for encrypted signaling in a
deployed environment. The guest endpoint is:

```text
wss://host:32189/remote-coop-direct
```

## Direct connection contract

- WebRTC ICE policy is `all`; configured ICE servers are discovery-only.
- The default configuration contains no server-side media route.
- Controller input uses a WebRTC data channel.
- WebSocket signaling is used only for room membership and peer negotiation.
- Bonjour, manual host address, and six-character room code are supported for discovery and admission.
- Room admission is host-authoritative and expires with the invite.
- NAT or firewall incompatibility produces an explicit connection error.

Relayless networking cannot traverse every symmetric NAT or restrictive
firewall. That limitation is intentional: the product does not silently add
a media service that changes the topology or its privacy characteristics.
