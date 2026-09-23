# PixelNOW Remote Co-Op P2P Technical Documentation

**Document Version:** 1.0  
**Last Updated:** September 2026  
**Project:** PixelNOW (OpenNow-mac)

---

## Table of Contents

1. [Overview](#overview)
2. [Complete Connection Flow](#complete-connection-flow)
3. [P2P Architecture](#p2p-architecture)
4. [Relay Server Integration](#relay-server-integration)
5. [Network Configuration](#network-configuration)
6. [Security](#security)
7. [Component Reference](#component-reference)
8. [Appendix](#appendix)

---

## Overview

The PixelNOW Remote Co-Op system enables remote co-op gameplay by connecting guests (browser-based clients) to a macOS host application via WebRTC. This document provides comprehensive technical documentation of the peer-to-peer (P2P) architecture, signaling mechanisms, network configuration, and security Model.

### Key Components

- **Broker (Signaling Server):** Manages WebSocket connections and relays SDP offers/answers and ICE candidates
- **TURN Server (coturn):** Provides relay connectivity when direct P2P fails
- **Host Application (macOS):** WebRTC peer implementation, input routing, and session management
- **Browser Guests (app.js):** Browser-based guests connecting via Web API

### Architecture Overview

```
[Guest Browser] <---WebSocket---> [Broker] <---WebSocket---> [macOS Host]
     |                                   |                         |
     |                                   |                         |
     +------WebRTC (Direct/Relay)--------+                         |
                             |                                       |
                             +-----------WebRTC (Direct/Relay)-------+
```

---

## Complete Connection Flow

### Phase 1: Invite Generation

**Host Side (macOS):**

1. User creates an invite in PixelNOW application
2. `RemoteCoOpHostSession.startInvite()` generates:
   - **Invite ID:** UUID for room identification
   - **Invite Code:** Human-readable 6-character code (e.g., "XJ7P2Q")
   - **Invite Token:** Signed JWT containing payload with expiration, transport settings, and preferences
   - **Join URL:** Browser URL with invite code as query parameter

```swift
// Invite token payload includes:
- inviteID: UUID
- code: String (6-char code)
- createdAt: Date
- expiresAt: Date
- applicationID, title (if not hidden)
- transportMode: automatic/directOnly/relayOnly
- latencyMode: quality/lowLatency
- requireHostApproval: Bool
```

**Token Signing:**
- Uses `HMAC-SHA256` with a secret key
- Base64URL encoding for portability
- Format: `base64url(payload).base64url(signature)`

### Phase 2: Guest Discovery and Connection

**Browser Guest:**

1. Guest opens join URL: `http://host:32188/?invite=XJ7P2Q`
2. `app.js` decodes invite code and validates format
3. Guest displays "Enter invite code" UI or auto-connects if invite in URL

**Invite Code Validation:**
```javascript
// Validates 6-character alphanumeric codes
/^[A-Z0-9]{6}$/.test(code)
```

### Phase 3: WebSocket Signaling Connection

**Broker Establishment:**

1. Browser opens WebSocket to broker: `ws://host:32188/remote-coop`
2. Browser sends `guestJoinRequested` message:

```json
{
  "kind": "guestJoinRequested",
  "roomID": "invite-id-uuid",
  "participantID": "guest-uuid",
  "inviteToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xxxxx",
  "displayName": "Guest Player"
}
```

**Broker Processing:**

1. Validates invite code (if code-only) or payload (if full token)
2. Checks if host is already registered for this room
3. Stores guest in pending state if host not yet connected
4. Forwards to host when available

### Phase 4: Host Registration

**Host Side:**

1. `RemoteCoOpHostPeerController` listens for signaling events
2. Host receives `.guestJoinRequested` event
3. Host can approve/reject guest via `approveParticipant()` or `removeParticipant()`
4. Host sends `guestHello` with invite information:

```json
{
  "kind": "hostHello",
  "roomID": "invite-id-uuid",
  "invite": { ... invite object ... }
}
```

### Phase 5: Network Configuration Exchange

**Broker sends network config to guest:**

```json
{
  "kind": "networkConfiguration",
  "roomID": "...",
  "networkConfiguration": {
    "transportMode": "automatic",
    "iceTransportPolicy": "all",
    "latencyMode": "lowLatency",
    "iceServers": [
      { "urls": ["stun:stun.l.google.com:19302"] },
      { 
        "urls": ["turn:198.12.95.48:32189?transport=udp"],
        "username": "1695600000:room-uuid",
        "credential": "hmac-base64-here"
      }
    ],
    "dataChannelInputEnabled": true,
    "websocketInputFallbackEnabled": true,
    "directPeerCandidateWarning": "..."
  }
}
```

### Phase 6: WebRTC Negotiation

**Offer/Answer Exchange:**

1. Guest creates `RTCPeerConnection` with ICE servers
2. Guest sets up data channel: `createDataChannel("input", { ordered: false, maxRetransmits: 0 })`
3. Host receives guest's ICE candidates via broker relay
4. Host creates offer with WebRTC:

```swift
let offer = try await peerConnection.createOffer()
await callbacks.sendSignal(.offer(sdp: offer.sdp))
```

5. Host sends offer via broker to guest
6. Guest sets offer as remote description and creates answer:

```javascript
await peerConnection.setRemoteDescription(offer);
const answer = await peerConnection.createAnswer();
await peerConnection.setLocalDescription(answer);
// Send answer back via broker
```

7. Guest sends answer to host via broker
8. Host sets answer as remote description
9. ICE candidate exchange begins (if not using low-latency mode where candidates may be omitted)

### Phase 7: Data Channel Establishment

**Input Channel Setup:**

1. Both sides create and bind data channels
2. Data channel is unordered, unreliable (maxRetransmits: 0) for low latency
3. Input packets sent via data channel when available
4. Falls back to WebSocket if data channel unavailable

### Phase 8: Approval and Gameplay

**Host Approval Flow:**

```swift
// Guest joins -> WaitingForApproval state
// Host approves -> Connected, inputEnabled = true, playerIndex assigned
```

**Input Routing:**

1. Guest polls Gamepad API (120Hz or display frame rate based on latency mode)
2. Converts gamepad state to `RemoteCoOpInputPacket`
3. Sends via data channel (or WebSocket fallback)
4. Host receives and routes to native GFN input path

---

## P2P Architecture

### WebRTC Data Model

The system uses WebRTC for media and data transmission:

```
PeerConnection Configuration:
- iceServers: STUN + TURN servers
- iceTransportPolicy: "all" (automatic) or "relay" (relayOnly)
- sdpSemantics: "unifiedPlan"
- bundlePolicy: "maxBundle"
- rtcpMuxPolicy: "require"
- tcpCandidatePolicy: "enabled"
- continualGatheringPolicy: "gatherOnce"
```

### ICE Candidate Types

| Type | Description | Priority |
|------|-------------|----------|
| host | Direct IP (local or public) | Highest |
| srflx | Server reflexive (via STUN) | Medium |
| relay | TURN relay | Lowest |

### NAT Traversal Mechanisms

**STUN (Session Traversal Utilities for NAT):**
- Discovers public IP address
- Maps local UDP port  to public port
- Enables direct P2P when both peers have public or symmetric NAT

**TURN (Traversal Using Relays around NAT):**
- Provides relay server when direct connectivity fails
- TCP or UDP relay candidates
- Requires authentication (HMAC or static credentials)
- Bandwidth-intensive but guaranteed connectivity

### Direct P2P vs Relay Fallback

| Mode | ICE Policy | Behavior | Use Case |
|------|------------|----------|----------|
| **Automatic** | `all` | Tries host/srflx first, falls back to relay | Default, maximizes quality/latency |
| **Relay Only** | `relay` | Only uses TURN relay candidates | Strict firewalls, privacy concerns |
| **Direct Only** | `all` | Only direct candidates, no relay | Testing, guaranteed low latency if possible |

### Connection States

```
PeerConnection States:
- new: Initial state
- checking: ICE candidates being gathered
- connected: At least one path established
- completed: All candidates gathered and connected
- failed: Connection failed
- disconnected: Lost connection
- closed: Closed

ICE Connection States:
- new, checking, connected, completed, failed, disconnected, closed
```

---

## Relay Server Integration

### TURN Server Implementation

The PixelNOW Remote Co-Op system uses **coturn**, the standard open-source TURN server implementation:

```
coturn Features:
- RFC 5766 TURN compliance
- TCP and UDP support
- TLS/TURNS support
- REST API authentication
- Static credentials (for testing)
- Logging and monitoring
```

### TURN Configuration

**Environment Variables:**
```bash
PIXELNOW_REMOTE_COOP_TURN_PUBLIC_HOST=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=your-long-random-secret
PIXELNOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_PORT=32189
PIXELNOW_REMOTE_COOP_TURN_TLS_PORT=32443
PIXELNOW_REMOTE_COOP_TURN_MIN_PORT=42160
PIXELNOW_REMOTE_COOP_TURN_MAX_PORT=42200
PIXELNOW_REMOTE_COOP_TURN_REALM=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_EXTERNAL_IP=203.0.113.10  # When behind NAT
```

### TURN Authentication

**Short-lived REST Credentials:**
```javascript
// Broker generates credentials per room
username = `${expiry}:${roomID}`  // e.g., "1695600000:room-uuid"
credential = HMAC-SHA1(secret, username).base64()
```

**Credential Format:**
- Username: `{unix_timestamp}:{room_id}`
- Credential: Base64-encoded HMAC-SHA1 of username using shared secret
- TTL: Configurable (default 3600 seconds)

**Authentication Flow:**
1. Guest/Host receives TURN URL + credentials from broker
2. Browser includes credentials in ICE agent
3. TURN server validates HMAC before establishing relay

### When relay is Used

**Automatic Mode:**
- Direct P2P attempted first
- Falls back to TURN when:
  - One or both peers are behind symmetric NAT
  - UDP blocked by firewall
  - STUN mapping unavailable

**Relay Only Mode:**
- Only TURN candidates gathered
- No direct IP exposure
- Higher latency but guaranteed connectivity

### TURN Server Management

**Node Manager (`turn-server.mjs`):**
- Launches system `coturn` binary
- Validates configuration
- Handles graceful shutdown (SIGTERM/SIGKILL with 5s timeout)
- Provides CLI help and dry-run mode

```bash
# Launch TURN server
node RemoteCoOp/turn/turn-server.mjs

# Dry-run (validate config without starting coturn)
PIXELNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=1 \
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=test-secret \
node RemoteCoOp/turn/turn-server.mjs --dry-run
```

---

## Network Configuration

### Transport Modes

| Mode | Description | ICE Policy | TURN Usage | Latency | Privacy |
|------|-------------|------------|------------|---------|---------|
| **Automatic** | Default. Try direct, fallback to relay | `all` | Optional | Low (when direct) | Medium |
| **Relay Only** | Force TURN relay | `relay` | Required | Higher | High |
| **Direct Only** | Direct only, no relay | `all` | No | Lowest (if possible) | Low |

### Latency Modes

| Mode | Frame Rate | Buffering | Bitrate | Use Case |
|------|------------|-----------|---------|----------|
| **Quality** | Lower | Aggressive | Higher | watching, stable networks |
| **LowLatency** | Higher | Minimal | Variable | Gaming, responsive control |

### Input Transport Modes

| Mode | Transport | Reliability | Use Case |
|------|-----------|-------------|----------|
| **Data Channel** | WebRTC datagram | Unordered, unreliable | Low latency (preferred) |
| **WebSocket Fallback** | TCP | Ordered | When data channel unavailable |

### WebRTC Media Configuration

**Video (720p60 default):**
```
Preset: p720f60
Resolution: 1280x720
FPS: 60
Max Bitrate: 12 Mbps (quality) / 8 Mbps (lowLatency)
Min Bitrate: 5 Mbps (quality), none (lowLatency)
Degradation: maintainFramerate (lowLatency)
```

**Audio:**
```
Codec: Opus
Sample Rate: 48 kHz
Channels: Stereo
```


### STUN/TURN Server Configuration

**Broker Environment Variables:**
```bash
PIXELNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302
PIXELNOW_REMOTE_COOP_TURN_URLS=turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=your-shared-secret
PIXELNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
```

### Firewall Requirements

**TURN Server:**
```
32189/udp     TURN UDP
32189/tcp     TURN TCP  
32443/tcp     TURNS TCP (when TLS cert/key configured)
42160-42200/udp  Relay allocation range
```

**Broker:**
```
32188/tcp     HTTP/WebSocket (default)
32188/tcp     HTTPS/WSS (when TLS configured)
```

### Connection Testing

**Smoke Test Script:**
```bash
# Validates network configuration logic
node RemoteCoOp/server/smoke-network-config.mjs

# Test against running broker
node RemoteCoOp/server/smoke-network-config.mjs --broker-url http://127.0.0.1:32188
```

**Test Coverage:**
- Automatic mode includes STUN + TURN
- Relay Only forces relay policy
- Direct Only omits TURN
- Pending guest waits for host

---

## Security

### Invite Token Security

**Signature Algorithm:**
- HMAC-SHA256 with 256-bit random secret
- Short-lived tokens (default 1 hour expiration)
- Token format: `base64url(payload).base64url(signature)`

**Payload Fields:**
```json
{
  "version": 1,
  "inviteID": "uuid",
  "code": "XJ7P2Q",
  "applicationID": "",
  "title": "",
  "createdAtEpochSeconds": 1695600000,
  "expiresAtEpochSeconds": 1695603600,
  "reservedGuestSlots": 1,
  "transportMode": "automatic",
  "qualityPreset": "p720f60",
  "latencyMode": "lowLatency",
  "requireHostApproval": true
}
```

**Validation:**
1. Decode base64url payload
2. Verify HMAC signature
3. Check expiration timestamp
4. Validate inviteID matches room

### Signaling Encryption (TLS/WSS)

**Broker TLS Configuration:**
```bash
PIXELNOW_REMOTE_COOP_BROKER_CERT=/path/to/cert.pem
PIXELNOW_REMOTE_COOP_BROKER_KEY=/path/to/key.pem
```

**Fallback to TURN TLS:**
- If broker TLS unavailable, can use `turns:` (TLS TURN) URLs
- Requires TURN certificate/key configuration

### TURN Credential Security

**REST Authentication:**
- Short-lived credentials (1 hour TTL)
- Room-specific (embedded roomID in username)
- HMAC validation (prevents tampering)

**Recommendations:**
- Use long random secrets (32+ bytes)
- Rotate secrets periodically
- Never expose secrets in logs
- Use HTTPS/WSS for signaling

### Privacy Considerations

**Direct IP Exposure:**
- Automatic mode: Exposes peer IPs via host/srflx candidates
- Relay Only mode: Hides direct IPs, only uses relay candidates
- Recommendation: Use `relayOnly` for privacy-sensitive deployments

**Data Handling:**
- Broker does not inspect message payloads
- No logging of invite tokens, SDP, or TURN secrets
- Network logs only contain metadata (timestamps, socket IDs, states)

**Guest Approval:**
- Host controls guest approval (configurable)
- Prevents unsolicited connections
- Optional: `requireHostApproval=false` for open sessions

### Certificate Requirements

**Production SSL/TLS:**
- Broker: Valid certificate (Let's Encrypt or commercial)
- TURN: Optional (turns: for encrypted relay)
- Self-signed certificates warn browsers (expected for local dev)

---

## Component Reference

### Broker (`server/broker.mjs`)

**Role:** Signaling server (media not relayed)

**Endpoints:**
- `GET /` - Browser guest page
- `GET /remote-coop/network-config` - ICE configuration endpoint
- `ws /remote-coop` - WebSocket signaling

**API Messages:**

**Host → Broker:**
```json
{ "kind": "hostHello", "roomID": "uuid", "invite": {...} }
{ "kind": "guestRejected", "roomID": "uuid", "participantID": "uuid", "reason": "..." }
{ "kind": "participantRemoved", "roomID": "uuid", "participantID": "uuid" }
{ "kind": "inviteEnded", "roomID": "uuid", "reason": "..." }
```

**Guest → Broker:**
```json
{ "kind": "guestJoinRequested", "roomID": "uuid", "participantID": "uuid", "inviteToken": "..." }
{ "kind": "guestInput", "roomID": "uuid", "participantID": "uuid", "input": {...} }
{ "kind": "guestInput", "roomID": "uuid", "participantID": "uuid", "inputs": [{...}, {...}] }
{ "kind": "guestDisconnected", "roomID": "uuid", "participantID": "uuid" }
```

**Bidirectional:**
```json
{ "kind": "peerSignal", "roomID": "uuid", "participantID": "uuid", "peerSignal": {...} }
{ "kind": "networkConfiguration", "roomID": "uuid", "networkConfiguration": {...} }
{ "kind": "participantUpdated", "roomID": "uuid", "participant": {...} }
{ "kind": "heartbeat", "roomID": "uuid" }
```

**Features:**
- Room management (pending guests wait for host)
- Rate limiting (420 messages/5s)
- Socket timeout (45s heartbeat)
- Session statistics (active/pending guests)
- WebSocket keepalive (10s heartbeat interval)

### Browser Guest (`browser/app.js`)

**Core Functions:**

| Function | Description |
|----------|-------------|
| `joinRoom()` | Opens WebSocket, sends `guestJoinRequested` |
| `configurePeerConnection()` | Sets up RTCPeerConnection with ICE servers |
| `startPolling()` | Gamepad input loop (120Hz or display frame) |
| `inputPacket()` | Converts GamepadState to input packet |
| `sendInput()` | Sends via data channel or WebSocket |
| `samplePeerStats()` | Collects WebRTC stats (RTT, bitrate, loss) |

**Diagnostics Panel:**
- WebSocket state
- ICE transport policy
- STUN/TURN counts
- Candidate types (host/srflx/relay)
- Selected route with RTT
- Media stats (video/audio)
- Input transport (data channel vs WebSocket)
- Input packet count and sequence

### TURN Server (`turn/turn-server.mjs`)

**Configuration:**
```javascript
{
  turnserverBin: "turnserver",
  publicHost: "198.12.95.48",
  realm: "198.12.95.48",
  sharedSecret: "...",
  listeningIP: "198.12.95.48",
  externalIP: "203.0.113.10",
  port: 32189,
  tlsPort: 32443,
  minPort: 42160,
  maxPort: 42200,
  tlsEnabled: true/false
}
```

**Coturn Args:**
```
--use-auth-secret
--static-auth-secret=<secret>
--realm=<realm>
--fingerprint
--lt-cred-mech
--no-cli
--no-multicast-peers
--listening-ip=<ip>
--listening-port=<port>
--min-port=<min>
--max-port=<max>
--log-file=stdout
--simple-log
--external-ip=<ip> (if behind NAT)
```

### Host Swift Components

**`RemoteCoOpHostSession`:**
- Manages participants (host + guests)
- Creates/stops invites
- Approves/removes participants
- Routes input packets
- Maintains player slot assignments

**`RemoteCoOpHostPeerController`:**
- Manages peer connections per guest
- Tracks network configuration
- Updates latency modes
- Handles peer lifecycle (start, close)

**`RemoteCoOpWebRTCHostPeer`:**
- Implements WebRTC signaling (offer/answer/ICE)
- Video/audio track management
- Data channel handling
- Input packet decoding
- Media telemetry

**`RemoteCoOpInputRouter`:**
- Routes guest input to GFN path
- Filters by participant state
- Handles stale packets
- Generates neutral events on disconnect

**`RemoteCoOpHostInputScheduler`:**
- Low-latency input coalescing
- Buffered input with configurable drain delay
- Only sends on button state changes
- Maximum 4ms drain delay

---

## Appendix

### Environment Variables Reference

**Broker:**
```bash
PIXELNOW_REMOTE_COOP_PORT=32188
PIXELNOW_REMOTE_COOP_PORT_ALTERNATES=32190,32191
PIXELNOW_REMOTE_COOP_BIND_HOST=198.12.95.48
PIXELNOW_REMOTE_COOP_STUN_URLS=stun:stun.l.google.com:19302
PIXELNOW_REMOTE_COOP_TURN_URLS=turn:198.12.95.48:32189?transport=udp,turn:198.12.95.48:32189?transport=tcp
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=your-secret-here
PIXELNOW_REMOTE_COOP_TURN_TTL_SECONDS=3600
PIXELNOW_REMOTE_COOP_BROKER_CERT=/path/to/cert
PIXELNOW_REMOTE_COOP_BROKER_KEY=/path/to/key
PIXELNOW_REMOTE_COOP_LOG_NETWORK=1
PIXELNOW_REMOTE_COOP_LOG_MESSAGES=0
```

**TURN:**
```bash
PIXELNOW_REMOTE_COOP_TURN_PUBLIC_HOST=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_REALM=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_SHARED_SECRET=your-secret-here
PIXELNOW_REMOTE_COOP_TURN_LISTENING_IP=198.12.95.48
PIXELNOW_REMOTE_COOP_TURN_EXTERNAL_IP=203.0.113.10
PIXELNOW_REMOTE_COOP_TURN_PORT=32189
PIXELNOW_REMOTE_COOP_TURN_TLS_PORT=32443
PIXELNOW_REMOTE_COOP_TURN_MIN_PORT=42160
PIXELNOW_REMOTE_COOP_TURN_MAX_PORT=42200
PIXELNOW_REMOTE_COOP_TURN_CERT=/path/to/cert
PIXELNOW_REMOTE_COOP_TURN_KEY=/path/to/key
PIXELNOW_REMOTE_COOP_TURNSERVER_BIN=turnserver
PIXELNOW_REMOTE_COOP_TURN_DEV_ALLOW_LOOPBACK=0  # Set to 1 for local dev
```

### Network Configuration Flow

```
Guest Join
  │
  ├─ Get network-config from broker
  │   └─ Based on invite payload:
  │       - transportMode → iceTransportPolicy
  │       - Include STUN if not relayOnly
  │       - Include TURN if not directOnly
  │
  ├─ Create RTCPeerConnection with config
  │   └─ iceServers: [STUN, TURN]
  │
  ├─ Gather ICE candidates
  │   └─ host/srflx (automatic) or relay (relayOnly)
  │
  ├─ Send candidates to broker
  │   └─ Broker relays to host
  │
  └─ Host receives candidates
      └─ Adds to peer connection
```

### Input Packet Format

```json
{
  "participantID": "uuid",
  "sequenceNumber": 123,
  "buttons": 15,
  "leftTrigger": 0.5,
  "rightTrigger": 1.0,
  "leftStickX": 0.3,
  "leftStickY": -0.7,
  "rightStickX": 0.0,
  "rightStickY": 0.0,
  "sentAtNanoseconds": 1234567890123
}
```

### Common Issues and Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| Connection stuck at ICE | No STUN/TURN configured | Add STUN or TURN server |
| Relay only fails | TURN not reachable | Check firewall, TURN port, auth |
| High latency | Auto mode using relay | Switch to directOnly or check NAT |
| Input not working | Data channel not open | Check WebSocket fallback enabled |
| Invite expired | Token expired | Generate fresh invite |
| Guest approval missing | requireHostApproval=true | Host must approve in UI |

### Testing Checklist

**Local Development:**
- [ ] Start TURN with `--dry-run` to validate config
- [ ] Start broker and verify STUN/TURN URLs
- [ ] Open broker URL in browser (no warnings)
- [ ] Create invite in PixelNOW
- [ ] Join as guest and verify WebRTC stats
- [ ] Test input with gamepad
- [ ] Verify diagnostics show connected status

**Production Deployment:**
- [ ] TURN ports open (32189 UDP/TCP, 42160-42200)
- [ ] Broker accessible (32188 or TLS port)
- [ ] Certificate valid (no browser warnings)
- [ ] TURN auth working (test credentials)
- [ ] Symmetric NAT tested with TURN
- [ ] Input latency acceptable
- [ ] Video quality acceptable

---

**Document generated from PixelNOW Remote Co-Op implementation.**  
**For support, see `RemoteCoOp/README.md` and inline code comments.**
