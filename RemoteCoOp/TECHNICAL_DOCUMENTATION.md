# PixelNOW Remote Co-Op technical design

## Architecture

Remote Co-Op has two roles and one server-side responsibility:

1. The macOS host owns the game session, participant slots, input routing, and WebRTC host peer connections.
2. The browser guest renders the host stream and sends controller input through a WebRTC data channel.
3. The direct-signaling service is a short-lived rendezvous point for room membership and offer/answer/candidate exchange.

After negotiation, media and input use the host-to-guest peer connection. The rendezvous service does not receive media frames, audio samples, or input packets.

## Connection lifecycle

```text
host starts local listener
  -> host creates six-character room code
  -> guest discovers host or enters address and code
  -> guest joins the room through /remote-coop-direct
  -> host validates code and assigns a player slot
  -> host and guest exchange WebRTC negotiation messages
  -> direct media and input channels open
  -> room closes when host stops or times out
```

The host is authoritative for admission, participant identity, slot assignment, input enablement, and disconnect cleanup. Room codes are scoped to one active host room and expire with the invite.

## Relayless network policy

The native model intentionally has no transport-mode selector. There is one policy: direct WebRTC with ICE policy `all`. ICE servers may provide address discovery, but they are not media endpoints. No alternate media route is constructed when direct connectivity fails.

The direct policy has three consequences:

- peer candidate addresses can be visible to the other endpoint;
- restrictive NAT and firewall configurations can prevent connection;
- failure is surfaced as a direct-connection error instead of changing the topology behind the user’s back.

This is appropriate for low-latency game input and for deployments that want the host to retain media ownership without paying for server bandwidth.

## Signaling protocol

The service exposes:

- `GET /health` for process health;
- `GET /api/discover/:roomCode` for host-address discovery;
- `GET /remote-coop-direct` as a WebSocket upgrade endpoint.

The WebSocket messages are JSON objects. The host registers a room, the guest requests admission with the room code, and both sides exchange peer signals. The service forwards only these control messages to the other endpoint. It does not parse or persist SDP beyond forwarding the active message.

Every socket has a bounded message-rate window, heartbeat timeout, byte and room ownership state, and deterministic cleanup when the host disconnects.

## Native layers

- `RemoteCoOpHostSession` owns invite and participant state.
- `RemoteCoOpHostCoordinator` maps signaling events to host-session actions.
- `RemoteCoOpDirectSignalingSession` owns the host WebSocket connection.
- `RemoteCoOpHostPeerController` owns one peer controller per participant.
- `RemoteCoOpWebRTCHostPeer` provides the native WebRTC implementation.
- `BonjourServiceAdvertiser` and `BonjourServiceDiscovery` provide LAN discovery without changing the media path.
- `UPnPManager` can publish the direct listener when the router permits it.

The preferences store contains only direct-session settings: enablement, guest slots, quality, latency, and invite-detail visibility. It contains no server URL, alternate transport, admission migration, or compatibility settings.

## Security boundaries

- Use encrypted signaling in deployments that expose the rendezvous endpoint beyond a trusted LAN.
- Keep room lifetime short and invalidate the room when the host stops.
- Never log room codes, raw SDP, controller payloads, or candidate payloads.
- Validate message role, room ownership, participant identity, and slot availability before forwarding a message.
- Treat the rendezvous service as untrusted transport for negotiation, not as an authority over media or input.

## Operational limits

The service must be reachable for the short negotiation window. Once the peer connection is established, media and input no longer depend on service bandwidth. A guest behind a restrictive NAT may be unable to establish a direct path; the UI must explain that the network path is unavailable and offer local discovery or address correction, never an invisible alternate transport.

## Verification

Use the native Xcode build for Swift verification. For the server surface, validate JavaScript syntax with:

```sh
node --check RemoteCoOp/run-servers.mjs
node --check RemoteCoOp/server/direct-signaling.mjs
node --check RemoteCoOp/browser/app.js
```

Repository cleanup verification must also confirm that deleted compatibility files are absent and that no alternate transport configuration remains in source, scripts, or documentation.
