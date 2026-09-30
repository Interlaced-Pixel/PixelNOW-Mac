# PixelNOW Remote Co-Op technical design

## Endpoints and isolation

The guest page and secure signaling share `jayian.dev:38473`. Nginx adds a
new TLS server on that port and proxies `/remote-coop-direct` and `/health` to
the Node service at `127.0.0.1:32190`. This listener uses the existing domain
certificate. The current website listeners on ports 80 and 443 and their site
files remain unchanged.

Coturn runs as an independent systemd service with its own configuration:
UDP/TCP listener 38474, TLS/TCP listener 38475, and UDP relay range
40000-40100. It uses the existing domain certificate and a shared secret that
is stored only on the host. The signaling process issues room-scoped,
time-limited TURN REST credentials and sends them to the host and admitted
guests. No long-lived TURN password is embedded in PixelNOW.

## Connection lifecycle

1. The host creates an invite with a six-character PIN and registers it over
   WSS.
2. The signaling service creates ephemeral TURN credentials and returns the
   ICE configuration to the host.
3. The guest opens the shared invite link and joins the PIN room over WSS.
4. The signaling service returns the room ICE configuration and notifies the
   host of the guest.
5. The host creates an offer; the guest returns an answer. Both gather ICE
   candidates before sending SDP, so the forwarded descriptions include
   direct and TURN candidates.
6. WebRTC selects a direct route when available, with TURN as the relay
   fallback. Controller input uses the WebRTC data channel.
7. Room and credentials expire; disconnect and host shutdown remove room
   state.

The host remains authoritative for invite validity, participant registration,
slot assignment, input enablement, and disconnect cleanup. Signaling is not a
media path.

## Implementation layers

- `RemoteCoOpDirectSignalingSession` maintains the host WSS connection and
  carries room, participant, and peer messages.
- `RemoteCoOpDirectHostSessionManager` creates the PIN invite, waits for host
  registration and its ICE configuration, and connects the native peer
  controller.
- `RemoteCoOpHostSession` and `RemoteCoOpHostCoordinator` enforce admission and
  route participant input.
- `RemoteCoOpWebRTCHostPeer` builds the host offer and streams media/input.
- `browser/app.js` joins the room, builds the guest answer, renders media, and
  samples gamepad input.
- `server/direct-signaling.mjs` maintains short-lived rooms, rate limits
  admissions, issues TURN REST credentials, and forwards signaling only.
- `deploy/` contains the isolated Nginx, systemd, coturn, and SSH installer
  files.

## Deployment safety

The installer writes a separate Nginx configuration listening only on port
38473. It runs `nginx -t` before reload and checks that the existing website
still responds afterward. It does not edit files for the existing sites or
change ports 80 or 443. The signaling and TURN daemons have separate unit and
configuration files; they do not reuse or overwrite the existing Remote Co-Op
service on port 32189 or the installed but inactive `coturn.service`.

## Verification

After installation, verify the HTTPS page and `/health` endpoint, perform a
WSS upgrade, and confirm TURN allocation from outside the host network. Then
join a real guest session and confirm both a direct ICE route and a TURN relay
route. Recheck the current website on ports 80 and 443 before and after the
Nginx reload.
