# Remote Co-Op production networking plan

## Decision

Remote Co-Op will use a direct-first WebRTC topology with a native C/C++
signaling and relay service. Direct peer connectivity remains the preferred
path for latency, privacy, and operating cost. A standards-compliant TURN
relay is used only when direct ICE connectivity cannot be established.

The production relay executable will contain no Node.js, JavaScript, browser
runtime, downloaded library, linked third-party library, or custom media
protocol. It will target Linux and macOS from one CMake project and produce a
small, independently deployable native service. macOS terminates TLS through
Apple system APIs; Linux exposes its native service only behind a separately
managed TLS ingress that publishes HTTPS/WSS.

```text
                         direct ICE succeeds
guest browser  ───────────────────────────────── host app
      │                                               │
      └──── native C/C++ rendezvous service ──────────┘
                         │
                         └── TURN relay only when direct ICE fails
```

The rendezvous service never becomes a media path. The native relay component
relays encrypted WebRTC packets at the transport layer and does not decode
game video, audio, or controller payloads.

The no-third-party-library rule includes linked runtime libraries, vendored
source, package-manager downloads, and prebuilt server binaries. Interlaced
Pixel source is reusable only after source and license review; platform
operating-system APIs are allowed. Do not implement TLS or cryptographic
primitives from scratch. Linux's TLS ingress is a deployment process, not a
library linked into or shipped with the native relay executable. Any new
STUN, TURN, HTTP, or WebSocket implementation remains disabled for public
traffic until it passes independent security and interoperability review.

## Production objectives

The completed system must provide:

- reliable room creation, admission, negotiation, reconnect, and shutdown;
- direct WebRTC media and input whenever the network permits it;
- standards-compliant TURN fallback for restrictive NAT and firewall paths;
- authenticated, encrypted signaling and short-lived relay credentials;
- Linux and macOS server builds from the same source tree;
- one-command developer builds and deterministic CI builds;
- bounded memory, bounded queues, bounded message sizes, and graceful overload;
- structured privacy-safe telemetry, health checks, metrics, and audit logs;
- protocol versioning and capability negotiation;
- explicit user-visible state for direct, relayed, degraded, and failed paths;
- no silent legacy transport, browser-side compatibility shim, or alternate
  server runtime.

## Scope boundaries

The native service owns rendezvous, authentication, room state, relay
credential issuance, health, metrics, and operational controls. It does not
own game state, controller mapping, stream composition, or application-level
media transcoding.

The macOS app remains authoritative for:

- the cloud game session;
- host and guest admission;
- player-slot allocation;
- input validation and routing;
- native video and audio capture;
- peer lifecycle and local cleanup.

The browser remains responsible for:

- invite entry and validation;
- signaling connection;
- WebRTC negotiation;
- rendering media;
- controller input over the WebRTC data channel;
- direct-versus-relayed path reporting;
- actionable failure and reconnect UX.

## Interlaced Pixel reuse boundary

The new server will reuse the repository's protocol knowledge, naming, and
behavioral contracts from:

- `GFN/NVST/Signaling/NVSTWebSocketSignalingClient.swift` for signaling
  lifecycle and message-flow semantics;
- `GFN/NVST/Core/NvstStunHolePunch.swift` for existing candidate-discovery
  behavior and network diagnostics;
- `GFN/NVST/Core/NvstByteCodec.swift` for bounded byte-order and framing
  conventions;
- `GFN/NVST/Core/SrtpCryptography.swift` for internal cryptographic review
  references and test-vector organization;
- `App/RemoteCoOp/RemoteCoOpWireProtocol.swift` for host, guest, peer-signal,
  and input state semantics.

These Swift components are source references and compatibility authorities;
they are not linked into the C++ server. The existing client WebRTC framework
remains a client concern. The server has no dependency on a framework bundle,
Swift runtime, package registry, or external media library.

The Interlaced Pixel project portfolio and public repositories were reviewed
for reusable native networking components on 2026-09-25:

| Project | Verified fit | Reuse decision |
| --- | --- | --- |
| [socks-proxy](https://github.com/Interlaced-Pixel/socks-proxy) | C11, Linux `epoll`, macOS `kqueue`, nonblocking sockets, incremental state machines, bounded relay I/O, and UDP relay patterns. It implements SOCKS5, not WebSocket signaling or TURN. | First-party implementation candidate. Audit and reuse its portable socket/event-loop and bounded relay components where the abstractions fit; omit SOCKS5-specific behavior from the PixelNOW service. |
| [http-c](https://github.com/Interlaced-Pixel/HTTP-C) | The official portfolio describes a C++17 HTTP/1.1 networking library and marks it Alpha. | First-party candidate to audit and reuse for HTTP parsing/serialization if its server APIs, limits, and error handling meet the service requirements. GitHub source could not be fetched during this review, so verify the source locally before selecting it. It does not replace WebSocket, TLS, or TURN. |
| [Ledger](https://github.com/Interlaced-Pixel/Ledger) | Header-only C++17 logging with structured fields, rotating files, and async sinks. | First-party logging candidate. Audit its portability, concurrency, output redaction, and failure behavior; reuse only if it is simpler and safer than a small service-specific logger. |

Interlaced Pixel is the organization behind these projects, so they are
first-party reuse candidates rather than third-party dependencies. The owner
authorizes evaluation and reuse for PixelNOW, subject to confirming that the
organization controls the relevant source and recording the exact revision,
retained notices, and maintenance owner. The service may compile selected
first-party source directly; it must not add external libraries or package
downloads. Prefer the smallest reusable subset and avoid importing unrelated
features or a second server runtime.

Where no reviewed and licensed C or C++ implementation is available, create
the implementation under `RemoteCoOp/server-native/` and document the
corresponding protocol requirements, security review, and interoperability
evidence.

## Server deliverables

The replacement server tree will be:

```text
RemoteCoOp/server-native/
  CMakeLists.txt
  cmake/
  include/pixelnow/
    protocol.hpp
    server_config.hpp
    room_registry.hpp
    auth.hpp
    metrics.hpp
  src/
    main.cpp
    http_server.cpp
    websocket_session.cpp
    signaling_service.cpp
    room_registry.cpp
    credential_service.cpp
    health_service.cpp
    metrics_service.cpp
    logging.cpp
  relay/
    stun.cpp
    turn.cpp
    relay_credentials.cpp
  tests/
  tools/
    pixelnow-relayctl.cpp
  README.md
  SECURITY.md
  OPERATIONS.md
```

The production executable will be:

- `pixelnow-relay`: room registry, protocol validation,
  authentication, STUN discovery, TURN allocation, metrics, health, and
  relay-credential issuance; it serves HTTPS/WSS through the selected
  platform TLS boundary;
- `pixelnow-relayctl`: local administrative health and drain control.

The service uses separate internal components for signaling and packet relay,
but ships as one native executable for simple Linux and macOS deployment. A
future deployment may split those components into processes without changing
the wire protocol or ownership model.

## Dependency policy

The server has no third-party library dependency.

The common implementation uses:

- C++17 standard-library containers, strings, threading, atomics, and file
  handling;
- POSIX sockets, `poll` or `epoll` on Linux, and `kqueue` on macOS;
- `eventfd` on Linux and Grand Central Dispatch or native event sources on
  macOS;
- `getrandom` on Linux and `SecRandomCopyBytes` on macOS for entropy;
- platform process, filesystem, clock, and signal APIs;
- CMake supplied by the build environment.

The macOS adapter may use Network.framework and Security.framework because
they are operating-system APIs. The Linux adapter may use kernel and POSIX
interfaces only. No Homebrew, apt-installed development library, package
manager cache, vendored source bundle, or prebuilt external server binary is
part of the application or server build.

The Linux relay will bind its cleartext HTTP/WebSocket listener to loopback or
a private socket and require a separately managed TLS ingress for all public
HTTPS/WSS traffic. The ingress must validate upstream identity, strip
client-supplied forwarding headers, set trusted forwarding metadata, enforce
request and connection limits, and preserve WebSocket upgrades. Deployment
documentation must include a concrete supported ingress configuration and
certificate renewal/rotation procedure. The relay must reject unsafe public
binds unless an explicit development-only mode is enabled. No project-owned
TLS stack is planned. On macOS, Network.framework and Security.framework may
provide the integrated TLS listener and certificate handling.

The repository will not claim production security merely because the code
compiles. Security approval is a release requirement.

## Standards and platform basis

The implementation will conform to the primary protocol specifications rather
than inventing browser-specific behavior:

- RFC 6455 defines the WebSocket opening handshake, origin model, masking,
  frame rules, and close behavior required by browser clients;
- RFC 8489 defines STUN message structure, transaction handling, attributes,
  authentication, and error behavior;
- RFC 8656 defines the current TURN relay protocol and obsoletes the earlier
  TURN specifications;
- RFC 8446 defines TLS 1.3 handshake, key schedule, record protection, and
  downgrade behavior.

The macOS implementation will use the C API of Network.framework for native
TCP, TLS, and listener behavior, with Security.framework for certificate and
random-byte operations. Apple documents Network.framework as the preferred
path for modern TLS and warns that BSD sockets alone require an additional TLS
implementation.

The Linux implementation will use POSIX sockets, nonblocking I/O, `epoll`,
and `getrandom`. Linux's native interfaces provide event notification and
cryptographically suitable entropy, but not a portable application TLS
stack. Public TLS therefore terminates at the operator-managed ingress; the
relay listener is private and the ingress-to-relay trust boundary is explicit.

The standards references are:

- https://www.rfc-editor.org/rfc/rfc6455.html
- https://www.rfc-editor.org/rfc/rfc8489.html
- https://www.rfc-editor.org/rfc/rfc8656.html
- https://www.rfc-editor.org/rfc/rfc8446.html
- https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- https://developer.apple.com/documentation/network/tls
- https://developer.apple.com/documentation/security/secrandomcopybytes
- https://man7.org/linux/man-pages/man2/getrandom.2.html
- https://man7.org/linux/man-pages/man7/epoll.7.html

## Build contract

The server must be easy to compile on both target platforms.

### Linux

Supported baseline:

- Ubuntu 22.04 or newer;
- clang or GCC with C++17 support;
- CMake and Ninja;
- standard C++17 compiler and POSIX development headers supplied by the OS.

```sh
cmake -S RemoteCoOp/server-native -B build/remote-coop-linux \
  -G Ninja -DPIXELNOW_BUILD_TESTS=ON
cmake --build build/remote-coop-linux --parallel
ctest --test-dir build/remote-coop-linux --output-on-failure
```

### macOS

Supported baseline:

- macOS 13 or newer;
- Apple Clang supplied by the supported Xcode version;
- CMake and Ninja;
- no package-manager libraries or server runtimes.

```sh
cmake -S RemoteCoOp/server-native -B build/remote-coop-macos \
  -G Ninja -DPIXELNOW_BUILD_TESTS=ON
cmake --build build/remote-coop-macos --parallel
ctest --test-dir build/remote-coop-macos --output-on-failure
```

The repository will also provide `make remote-coop-server`, `make
remote-coop-test`, and `make remote-coop-package` as thin wrappers around the
CMake commands. Make is an entry point, not the build system.

### Build profiles

- `Debug`: sanitizers, assertions, verbose diagnostics, and local certificates;
- `RelWithDebInfo`: production-like optimization with symbols;
- `Release`: hardened compiler flags, stripped binaries, and reproducible
  package metadata.

Linux CI will run AddressSanitizer and UndefinedBehaviorSanitizer. macOS CI
will run the equivalent supported sanitizer configuration. ThreadSanitizer
will cover room-state and credential-service concurrency tests.

## Native service architecture

### Process layers

1. `main.cpp` loads and validates configuration, initializes logging, starts
   the service, and owns graceful shutdown.
2. `http_server` serves health, metrics, readiness, and administrative drain
   endpoints over HTTPS.
3. `websocket_session` uses the project-owned HTTP/WebSocket framing layer and
   bounded asynchronous I/O.
4. `signaling_service` validates protocol messages and routes only authorized
   signaling commands.
5. `room_registry` owns expiring room state with explicit host and guest
   membership.
6. `credential_service` issues short-lived TURN credentials and validates
   host session claims.
7. `metrics_service` exports counters, gauges, and latency histograms without
   retaining user payloads.
8. `relayctl` drains, inspects, and health-checks the service locally.

### Concurrency model

- One bounded executor pool handles network I/O.
- Room state is protected by actor-style serialized operations or a clearly
  owned mutex boundary; it is never mutated from arbitrary callbacks.
- Every connection has bounded read, write, and message queues.
- Every room has bounded guest count, lifetime, signaling bytes, and idle time.
- Shutdown stops accepting connections, drains active writes, revokes room
  credentials, closes sockets, and exits within a documented deadline.

## Protocol design

### Envelope

Every message uses a versioned envelope:

```json
{
  "protocolVersion": 2,
  "messageID": "uuid",
  "sessionID": "opaque-id",
  "kind": "guestJoinRequested",
  "sentAtEpochMilliseconds": 0,
  "payload": {}
}
```

The server validates:

- protocol version;
- message ID format and replay window;
- authenticated role;
- session ownership;
- message direction;
- payload schema and size;
- participant identity;
- allowed state transition.

Unknown message kinds are rejected with a typed error. Required fields are
never silently ignored.

### Room lifecycle

```text
host authenticates
  -> host creates session and receives opaque invite secret
  -> guest presents invite secret over WSS
  -> server validates secret, expiry, origin, and capacity
  -> server issues participant identity and optional TURN credentials
  -> host and guest exchange offer, answer, and ICE candidates
  -> peers report direct or relayed connectivity
  -> room expires, is revoked, or is drained
```

Room codes are display-only. They are not the complete authorization secret.
The server stores only a hash of the invite secret and applies brute-force
limits per address, room, and account/session.

### Signaling messages

The initial production message set is:

- `hostSessionCreate`;
- `hostSessionClose`;
- `guestJoinRequest`;
- `guestJoinAccepted`;
- `guestJoinRejected`;
- `peerOffer`;
- `peerAnswer`;
- `iceCandidate`;
- `peerStateChanged`;
- `turnCredentialIssued`;
- `guestRemoved`;
- `heartbeat`;
- `sessionDraining`;
- `sessionClosed`;
- `protocolError`.

The server forwards negotiation payloads only after role, room, participant,
and destination checks. It never forwards guest controller data over the
signaling channel.

## Direct and relayed media policy

The native clients will configure ICE with:

1. host and guest candidates;
2. configured STUN discovery;
3. TURN candidates using short-lived credentials.

The peer connection prefers direct candidates. The client reports the selected
candidate type as `host`, `srflx`, `prflx`, or `relay`. The user-visible path
state is:

- `Discovering`;
- `Negotiating`;
- `Direct`;
- `Relayed`;
- `Degraded`;
- `Failed`;
- `Closed`.

Direct media remains end-to-end encrypted by WebRTC DTLS-SRTP. TURN relays
encrypted packets and cannot decode application media or input. The server
does not transcode, inspect, or store media.

## Native relay service requirements

The project-owned relay implementation must provide:

- STUN Binding discovery;
- TURN Allocate, Refresh, CreatePermission, ChannelBind, Send, and Data
  behavior required by browser WebRTC clients;
- UDP, TCP, and TLS-over-TCP transport support;
- IPv4 and IPv6 where available;
- short-lived credentials issued by the signaling component;
- nonce rotation and long-term credential authentication;
- permission and channel-binding expiry;
- per-account and per-session allocation quotas;
- bandwidth and allocation limits;
- abuse, amplification, reflection, and open-relay protection;
- region-aware endpoint selection;
- health and capacity metrics;
- graceful drain and allocation expiry;
- certificate rotation without service interruption;
- no unauthenticated long-lived relay credentials.

The implementation must follow the applicable STUN and TURN RFC behavior as
an interoperability contract. It must not invent a PixelNOW-only media relay
protocol. Every packet parser is bounded, rejects malformed lengths, validates
transaction state, and avoids copying attacker-controlled buffers without a
limit.

The first implementation milestone is a standards-testable STUN server. TURN
allocation support follows only after the STUN parser, credential layer,
nonce handling, permission tables, timers, and packet-forwarding tests pass.
No public relay traffic is enabled until browser interoperability, abuse
testing, fuzzing, and independent security review pass.

## Security requirements

Before production release:

- require HTTPS and WSS outside explicitly marked local development;
- use TLS 1.2 minimum and TLS 1.3 where supported;
- validate certificate chains and host names;
- use operating-system secure random generation for session secrets;
- hash invite secrets at rest;
- expire invites, sessions, credentials, and nonces;
- enforce origin, role, room, and participant authorization;
- reject malformed, oversized, replayed, and out-of-order messages;
- redact invite secrets, room identifiers, SDP, ICE candidates, and addresses
  from ordinary logs;
- protect health and metrics endpoints from public administrative access;
- rotate signing and credential keys without restarting all sessions;
- run the service as an unprivileged account;
- use sandboxing, least-privilege filesystem access, and a read-only runtime
  configuration where practical;
- run static-analysis, fuzzing, and sanitizer checks in CI;
- keep the project-owned secure-channel and STUN/TURN code behind a release
  gate until independent cryptographic and protocol review passes;
- complete an independent security review and penetration test.

## Reliability and recovery

The app and service must handle:

- signaling reconnect with bounded exponential backoff;
- host sleep and wake;
- interface changes and VPN transitions;
- temporary loss of the signaling server after peer establishment;
- TURN allocation expiry and credential renewal;
- duplicate join requests;
- host termination during negotiation;
- guest termination during active input;
- server restart and rolling deployment;
- full rooms and expired invites;
- clock skew within a documented tolerance.

Every failure must have a typed reason, telemetry event, safe cleanup path,
and user-facing recovery action. A failure must never leave input enabled,
leak a port mapping, or retain a room indefinitely.

## App integration changes

The Swift app will replace the current JavaScript signaling endpoint with a
native-service configuration containing:

- production WSS endpoint;
- regional signaling endpoints;
- TURN credential endpoint or credentials received during negotiation;
- protocol version and capability set;
- certificate and environment policy;
- direct-preferred ICE policy;
- maximum guests and media limits.

The app must explicitly stop `RemoteCoOpDirectHostSessionManager` whenever the
stream ends, the invite is revoked, the app terminates, or the user disables
Remote Co-Op. Startup must roll back signaling, Bonjour, UPnP, and room state
when any required stage fails.

The UI must expose invite copy/share, expiry, guest identity, player slot,
direct-versus-relayed path, revoke, remove guest, input enablement, and
recovery actions. Errors must not be reported only to logs.

## Testing plan

### Native unit tests

- configuration parsing and validation;
- protocol encoding and decoding;
- schema and size rejection;
- room lifecycle and expiration;
- invite hashing and constant-time comparison;
- credential issuance and expiry;
- role and destination authorization;
- rate limiting;
- bounded queue behavior;
- graceful shutdown;
- metrics and log redaction.

### Protocol integration tests

- Linux host to Linux guest;
- Linux host to macOS guest;
- macOS host to Linux guest;
- macOS host to macOS guest;
- WSS through a reverse proxy;
- direct ICE success;
- TURN UDP success;
- TURN TCP/TLS fallback;
- host and guest reconnect;
- rolling server restart;
- invalid and adversarial WebSocket frames;
- concurrent rooms and capacity limits.

### Browser and app acceptance tests

- invite creation and copy/share;
- code expiry and revocation;
- host and guest consent;
- video, audio, and controller input;
- slot assignment and removal;
- direct and relayed status display;
- network failure explanation and retry;
- app termination cleanup;
- accessibility and keyboard-only operation.

### Network matrix

Validate at minimum:

- same LAN;
- public IPv4 with permissive NAT;
- full-cone NAT;
- restricted-cone NAT;
- symmetric NAT;
- IPv6-only and dual-stack networks;
- VPN enabled;
- captive portal;
- blocked UDP;
- blocked inbound TCP;
- high latency, packet loss, and bandwidth throttling.

## Operations and deployment

Provide native service packaging for:

- systemd on Linux;
- launchd on macOS;
- container images for Linux operations;
- launch instructions for a single-node development deployment;
- regional production deployment with reverse proxy and TURN separation.

Each deployment must include:

- environment validation before startup;
- certificate and key permission checks;
- startup readiness and liveness checks;
- structured JSON logs;
- metrics endpoint;
- connection and allocation dashboards;
- alerts for error rate, capacity, credential failures, and certificate age;
- backup and rotation procedure for signing keys;
- documented drain, rollback, and incident response procedures.

The service must not bind to a hard-coded public address. Development defaults
must bind to loopback; production requires an explicit bind and advertised
endpoint configuration.

## Privacy and data handling

The service retains only the minimum active-session state required to route
negotiation and issue credentials. It must not persist:

- video or audio;
- controller input;
- raw SDP;
- ICE candidates;
- room codes or invite secrets;
- unnecessary IP history.

Operational logs use pseudonymous connection IDs and bounded retention. The
privacy documentation must explain direct peer address exposure, TURN relay
use, diagnostic telemetry, retention, and deletion behavior.

## Migration sequence

1. Audit the owned `socks-proxy`, `http-c`, and `Ledger` source for relevant
   APIs, correctness, security posture, build reproducibility, and platform
   coverage. Select and pin only the first-party files/components that reduce
   implementation risk; record the revision, notices, and ownership before
   integrating them.
2. Freeze the JSON protocol contract and define protocol version 2.
3. Implement the C++ room registry, schema validation, and protocol harness.
4. Implement HTTP/WebSocket framing using POSIX sockets plus the approved
   macOS system TLS APIs; define the Linux private-listener and TLS-ingress
   boundary. No dependency may be downloaded or fetched by the build.
5. Implement authentication, hashed invite secrets, expiry, and quotas.
6. Add native metrics, structured logging, health, readiness, and drain APIs.
7. Implement STUN, then TURN allocation and relay behavior with short-lived
   credential issuance and direct-preferred ICE.
8. Add Linux and macOS CMake builds, packaging, sanitizers, and CI.
9. Update the Swift app and browser guest to the versioned native protocol.
10. Add explicit lifecycle cleanup and WebRTC connection-state reporting.
11. Add direct-versus-relayed UX, invite sharing, guest controls, and recovery.
12. Run the complete network matrix and security review.
13. Release to an instrumented beta with hard capacity and rollback limits.
14. Promote to production only after exit metrics remain within target for the
    full beta observation window.

## Production exit criteria

Remote Co-Op leaves alpha only when all of these are true:

- native Linux and macOS release builds are reproducible from a clean clone;
- no Node.js runtime is required by production signaling or relay services;
- WSS, TURN credentials, invite expiry, and authorization are enforced;
- direct and relayed WebRTC paths are both tested and user-visible;
- server parser, protocol, room, security, and lifecycle tests are green;
- sanitizer, fuzzing, static-analysis, dependency, and security checks pass;
- app termination and network transition cleanup is verified;
- signed and notarized PixelNOW releases are installable on clean Macs;
- service dashboards, alerts, runbooks, and rollback procedures are live;
- privacy documentation and support escalation are published;
- the supported-network matrix meets the published success target;
- no known critical or high-severity security issue remains open.

## Definition of complete

The implementation is complete when the C/C++ service can be built with the
documented Linux and macOS commands, started with a validated configuration,
serve authenticated WSS signaling, issue expiring TURN credentials, route
versioned negotiation messages, expose health and metrics, survive malformed
traffic and controlled restarts, and support direct or relayed WebRTC sessions
with deterministic cleanup and diagnosable user-visible state.
