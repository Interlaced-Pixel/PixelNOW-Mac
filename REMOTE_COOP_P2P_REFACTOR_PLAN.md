# Relay-Free P2P Remote Co-Op System - Implementation Plan

**Version:** 1.0  
**Date:** 2026-09-24  
**Target:** PixelNOW macOS Host + Browser Guests

---

## Executive Summary

This document outlines the comprehensive plan to refactor the current broker-assisted Remote Co-Op system into a fully relay-free P2P (peer-to-peer) architecture using WebRTC with direct host-guest connections.

### Current Architecture
- Broker WebSocket signaling + coturn TURN server for relay fallback
- STUN for NAT traversal
- HMAC-SHA256 signed invite tokens
- WebSocket relay for WebRTC SDP/ICE candidates

### New Architecture
- **Direct P2P only** - No external broker or relay servers
- **Bonjour/mDNS** for local network auto-discovery  
- **UPnP** for automatic port mapping on NAT
- **PIN-based auth** with IP binding (simplified from HMAC tokens)
- **Embedded connection data** in invite links

---

## 1. Architecture Changes

### 1.1 Removed Components
| Component | Status | Reason |
|-----------|--------|--------|
| coturn TURN server | Remove | Not needed for direct P2P |
| External broker WebSocket | Remove | Host-guest signaling replaces |
| HMAC-SHA256 invite tokens | Replace | PIN-based auth |
| Relay fallback logic | Simplify | Direct-only P2P |

### 1.2 New Components
| Component | Purpose |
|-----------|---------|
| Bonjour/mDNS Registrar | Local network service discovery |
| UPnP Port Mapper | Automatic NAT port mapping |
| Direct Signaling Server | Host-guest WebSocket signaling |
| PIN Generator/Validator | Guest authentication |
| IP Binding Registry | Security feature |

### 1.3 Architecture Diagram

```
                        ┌─────────────────────────────────────────┐
                        │          Guest Browser                    │
                        │  (Direct P2P WebRTC)                     │
                        │                                         │
                        │  [ Bonjour / mDNS ]                     │
                        │    Service Discovery                     │
                        └──────────────┬──────────────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
              ┌─────▼─────┐     ┌─────▼─────┐     ┌─────▼─────┐
              │  Direct   │     │  Direct   │     │  Direct   │
              │ WebSocket │     │ WebSocket │     │ WebSocket │
              │  Signaling│     │ Signaling │     │ Signaling │
              │   Host    │     │  Guest A  │     │  Guest B  │
              └─────┬─────┘     └─────┬─────┘     └─────┬─────┘
                    │                │                  │
                    └────────────────┼──────────────────┘
                                     │
                        ┌────────────▼────────────┐
                        │       Host System       │
                        │  ┌───────────────────┐  │
                        │ │ UPnP Port Mapper  │  │
                        │ │ (Auto NAT config) │  │
                        │ └───────────────────┘  │
                        │  ┌───────────────────┐  │
                        │ │   Bonjour Server  │  │
                        │ │ (Service Advertise)│ │
                        │ └───────────────────┘  │
                        └─────────────────────────┘
```

---

## 2. Discovery Protocol Design

### 2.1 Bonjour/mDNS Service Format

**Service Type:** `_pixelnow-coop._tcp.local.`

**TXT Record Fields:**
```
host-id=<UUID>
pin=<4-digit PIN>
port=<host-signaling-port>
transport=<direct|stun|turn>
quality=<720p|1080p>
latency=<quality|lowlatency>
host-ip=<discovered-host-IP>
```

**Example TXT Record:**
```
host-id=550E8400-E29B-41D4-A716-446655440000
pin=1234
port=8787
transport=direct
quality=1080p
latency=lowlatency
host-ip=192.168.1.100
```

### 2.2 Manual IP Discovery

**Format:** `https://host-ip:8787/?join=PIN`

**Guest Joins:**
1. Enter host IP address
2. Enter PIN code
3. Browser initiates WebRTC connection directly

### 2.3 DNS-SD Implementation

```swift
// NSNetService / NSNetServiceBrowser based discovery
// macOS native Bonjour support
// Cross-platform fallback for guests (JavaScript mDNS)
```

**Host Side:**
```swift
import Network

class BonjourServiceAdvertiser {
    private var service: NWBrowser?
    
    func advertise(hostID: UUID, pin: String, port: Int) {
        // Advertise _pixelnow-coop._tcp with TXT record
    }
    
    func stop() {
        service?.cancel()
    }
}
```

**Guest Side (Browser):**
```javascript
// Use dns-sd.js or native browser mDNS APIs
// Fallback to manual IP entry
```

---

## 3. PIN Authentication Flow

### 3.1 PIN Generation

**Requirements:**
- 4-6 digit numeric PIN
- Single-use or time-limited
- IP-bound for security
- Valid for session only

**Implementation:**
```swift
struct PINAuthenticator {
    private var pendingPINs: [String: PINState] = [:]
    
    func generatePIN(for hostID: UUID, ip: String) -> (pin: String, expiresAt: Date) {
        let pin = generateRandomPIN()
        let expiresAt = Date().addingTimeInterval(300) // 5 minutes
        
        pendingPINs[pin] = PINState(
            hostID: hostID,
            clientIP: ip,
            createdAt: Date(),
            expiresAt: expiresAt,
            attempts: 0
        )
        
        return (pin, expiresAt)
    }
    
    func validatePIN(_ pin: String, fromIP ip: String) -> Bool {
        guard let state = pendingPINs[pin] else { return false }
        guard state.expiresAt > Date() else { return false }
        guard state.attempts < 3 else { return false }
        
        state.attempts += 1
        
        // IP binding check
        guard state.clientIP == ip || state.clientIP == "0.0.0.0" else { 
            return false 
        }
        
        pendingPINs.removeValue(forKey: pin)
        return true
    }
}

struct PINState {
    var hostID: UUID
    var clientIP: String
    var createdAt: Date
    var expiresAt: Date
    var attempts: Int
}
```

### 3.2 Authentication Request Flow

```
Guest                           Host
│                               │
│  [1] Join with PIN            │
│  ─────────►                    │
│                               │
│  [2] Validate PIN             │
│  ◄─────────                    │
│                               │
│  [3] Send Host Info (IP:Port) │
│  ─────────►                    │
│                               │
│  [4] Direct WebRTC Connect    │
│  ◄─────────                    │
│                               │
│  [5] SDP Offer/Answer Exchange│
│  ◄──────►                      │
│                               │
│  [6] ICE Candidates Exchange  │
│  ◄──────►                      │
│                               │
│  [7] P2P Connection Established│
│                               │
```

---

## 4. UPnP Port Mapping Integration

### 4.1 UPnP Discovery and Port Mapping

**Requirements:**
- Auto-detect UPnP-capable routers
- Map host signaling port (8787)
- Map WebRTC media ports
- Automatic cleanup on exit

**Implementation:**
```swift
import Network

class UPnPManager {
    private var mappedPorts: [UInt16] = []
    private var router: Router?
    
    func discoverRouter() async -> Bool {
        // SSDP discovery for UPnP routers
        // http://[router-ip]:80/upnp/scpd.xml
        return true // found router
    }
    
    func mapPort(_ port: UInt16, protocol: UPnPProtocol) async -> Bool {
        guard let router else { return false }
        
        // AddPortMapping()
        let result = try? await router.addPortMapping(
            externalPort: port,
            internalPort: port,
            protocol: protocol,
            description: "PixelNOW Remote Co-Op",
            leaseDuration: 3600
        )
        
        if result {
            mappedPorts.append(port)
        }
        return result
    }
    
    func clearAllMappings() {
        mappedPorts.forEach { port in
            router?.deletePortMapping(externalPort: port, protocol: .tcp)
        }
        mappedPorts.removeAll()
    }
}

enum UPnPProtocol {
    case tcp
    case udp
}
```

### 4.2 UPnP Port Requirements

| Port | Protocol | Purpose |
|------|----------|---------|
| 8787 | TCP | Host signaling WebSocket |
| 10000-11000 | UDP | WebRTC media (RTP/RTCP) |
| 11001-12000 | UDP | WebRTC data channels |

### 4.3 UPnP Fallback Strategy

```swift
// Priority order for connection
1. Direct (host's public IP:port if known)
2. UPnP-mapped port
3. Local network IP (192.168.x.x, 10.x.x.x, 172.16.x.x-172.31.x.x)
4. Link-local (169.254.x.x)
```

---

## 5. Signaling Protocol Changes

### 5.1 Removed Broker Wire Protocol

**Old (Broker-based):**
```json
{
  "protocolVersion": 1,
  "kind": "guestJoinRequested",
  "roomID": "uuid",
  "participantID": "uuid",
  "inviteToken": "hmac-sha256-signed-token",
  "displayName": "Guest"
}
```

### 5.2 New Direct Signaling Protocol

**New (Host-Guest WebSocket):**
```json
{
  "protocolVersion": 1,
  "kind": string,  // See message types below
  "participantID": "uuid",
  "pin": "optional-pin-for-auth",
  "hostIP": "optional-host-public-ip",
  "signal": object,  // WebRTC SDP/ICE
  "networkConfig": object,  // ICE servers
  "timestamp": 1234567890
}
```

### 5.3 Message Types

```swift
enum DirectSignalingMessageKind: String {
    case hostWelcome           // Host announces availability
    case guestJoinRequest      // Guest requests connection
    case guestJoinAccepted     // Host accepts guest
    case guestJoinRejected     // Host rejects guest
    case sdpOffer              // WebRTC offer
    case sdpAnswer             // WebRTC answer
    case iceCandidate          // ICE candidate
    case网络Configuration      // ICE servers configuration
    case ping                  // Keepalive
    case pong                  // Keepalive response
    case disconnect            // Disconnect notification
}
```

---

## 6. Invite Generation and Sharing

### 6.1 PIN-Based Invite Link

**Format:** `https://play.geforcenow.com/pixelnow?pin=1234&host=192.168.1.100`

**Properties:**
- Single-use PIN
- IP binding
- 5-minute expiration
- 3-attempt limit

### 6.2 QR Code Generation

```swift
extension UIImage {
    static func qrCode(forInvite invite: PINInvite) -> UIImage? {
        let urlString = invite.generateShareURL().absoluteString
        guard let data = urlString.data(using: .ascii) else { return nil }
        
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let output = filter?.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = output.transformed(by: transform)
        
        return UIImage(ciImage: scaledImage)
    }
}
```

### 6.3 Share Options

**Host can share via:**
1. QR Code (displayed on host screen)
2. Copy invite link to clipboard
3. Enter PIN manually on guest browser
4. Local network mDNS auto-discovery

---

## 7. Security Model Updates

### 7.1 Removed Security

| Feature | Removed | Replacement |
|---------|---------|-------------|
| HMAC-SHA256 signatures | ✗ | PIN + IP binding |
| External token validation | ✗ | Host-side validation |
| Broker authentication | ✗ | PIN-only authentication |

### 7.2 PIN + IP Binding Security

```swift
struct PINSecurityPolicy {
    static let maxAttempts = 3
    static let pinExpiration: TimeInterval = 300  // 5 min
    static let connectionTimeout: TimeInterval = 30
    
    static func validate(_ pin: String, from ip: String) throws -> Bool {
        // 1. Check PIN format
        guard pin.count == 4 || pin.count == 6, 
              pin.allSatisfy({ $0.isNumber }) else {
            throw PINError.invalidFormat
        }
        
        // 2. Check against pending PINs
        // 3. IP binding verification
        // 4. Attempt limit enforcement
        // 5. Expiration check
        
        return true
    }
}

enum PINError: LocalizedError {
    case invalidFormat
    case expired
    case tooManyAttempts
    case ipMismatch
}
```

### 7.3 Transport Security

| Scenario | Encryption |
|----------|------------|
| WebSocket signaling | TLS (wss://) |
| Local network | mDNS (plaintext) |
| STUN/TURN | DTLS for media |
| WebRTC data channels | DTLS |

---

## 8. Implementation Tasks

### Phase 1: Core Protocol (Week 1)

**Task 1.1: Direct Signaling Messages**
- [ ] Define new wire protocol structure
- [ ] Implement message encoding/decoding
- [ ] Add unit tests

**Task 1.2: PIN Authentication**
- [ ] PIN generation algorithm
- [ ] PIN validation logic
- [ ] IP binding storage
- [ ] Security limits (attempts, expiration)

### Phase 2: Discovery (Week 2)

**Task 2.1: Bonjour/Service Discovery**
- [ ] Host service advertisement
- [ ] Guest service discovery
- [ ] TXT record parsing
- [ ] Fallback to manual entry

**Task 2.2: UPnP Integration**
- [ ] Router discovery (SSDP)
- [ ] Port mapping API
- [ ] Automatic cleanup
- [ ] Error handling

**Task 2.3: Network Configuration**
- [ ] STUN server configuration
- [ ] Local IP detection
- [ ] Public IP detection
- [ ] NAT type detection

### Phase 3: Host Implementation (Week 3)

**Task 3.1: Direct Signaling Server**
- [ ] WebSocket server (代替 broker)
- [ ] Guest connection management
- [ ] Signal routing
- [ ] Session cleanup

**Task 3.2: WebRTC Integration**
- [ ] Accept WebRTC offers
- [ ] Send WebRTC answers
- [ ] Handle ICE candidates
- [ ] Data channel support

**Task 3.3: Input Router Updates**
- [ ] Remove broker dependency
- [ ] Direct input routing
- [ ] Performance testing

### Phase 4: Guest Implementation (Week 4)

**Task 4.1: Browser UI**
- [ ] PIN entry interface
- [ ] Host discovery panel
- [ ] Manual IP entry
- [ ] QR code scanner

**Task 4.2: Direct Connection**
- [ ] Connect to host signaling
- [ ] Send WebRTC offer
- [ ] Handle ICE candidates
- [ ] Data channel setup

**Task 4.3: Fallback Mechanisms**
- [ ] Manual IP fallback
- [ ] Local network discovery
- [ ] Error handling

### Phase 5: Integration (Week 5)

**Task 5.1: Host UI**
- [ ] Share PIN UI
- [ ] QR code display
- [ ] Guest management
- [ ] Session status

**Task 5.2: Configuration**
- [ ] Disable broker/TURN
- [ ] Enable direct-only modes
- [ ] Remove coturn references

**Task 5.3: Testing**
- [ ] Local network testing
- [ ] NAT traversal testing
- [ ] Firewall testing
- [ ] Security testing

### Phase 6: Cleanup (Week 6)

**Task 6.1: Code Removal**
- [ ] Remove broker signaling
- [ ] Remove coturn dependencies
- [ ] Remove HMAC token code
- [ ] Update dependencies

**Task 6.2: Documentation**
- [ ] User guide for new system
- [ ] Developer documentation
- [ ] Troubleshooting guide

---

## 9. Testing Strategy

### 9.1 Unit Tests

**PIN Authentication:**
```swift
func testPINGeneration() {
    let authenticator = PINAuthenticator()
    let (pin, _) = authenticator.generatePIN(for: UUID(), ip: "127.0.0.1")
    XCTAssert(pin.count == 4)
    XCTAssert(pin.allSatisfy { $0.isNumber })
}

func testPINValidation() {
    let authenticator = PINAuthenticator()
    let (pin, _) = authenticator.generatePIN(for: UUID(), ip: "127.0.0.1")
    
    XCTAssertTrue(authenticator.validatePIN(pin, fromIP: "127.0.0.1"))
    XCTAssertFalse(authenticator.validatePIN("0000", fromIP: "127.0.0.1"))
}
```

**Bonjour Discovery:**
```swift
func testBonjourAdvertisement() {
    let advertiser = BonjourServiceAdvertiser()
    advertiser.advertise(
        hostID: UUID(),
        pin: "1234",
        port: 8787
    )
    
    let discovery = BonjourServiceDiscovery()
    var services: [BonjourService] = []
    discovery.discover { services.append(contentsOf: $0) }
    
    // Wait for discovery
    XCTAssertEqual(services.count, 1)
    XCTAssertEqual(services[0].pin, "1234")
}
```

### 9.2 Integration Tests

**Local Network P2P:**
```
Host (macOS) ── LAN ── Guest (Browser)
```

** NAT Traversal Tests:**
1. Symmetric NAT
2. Full锥 NAT
3. 限制锥 NAT
4. 端口限制锥 NAT
5. No NAT (direct)

**Firewall Tests:**
- Windows Firewall
- macOS Firewall
- Security software

### 9.3 Performance Tests

**Metrics:**
- Connection establishment time (< 3s)
- First frame latency (< 100ms)
- Input latency (< 50ms)
- Packet loss (< 1%)

---

## 10. Migration Path

### Phase 1: Dual-Mode (Both Systems)
```
Host: [ Broker + Direct P2P ]
Guest: [ Can use either ]
```

### Phase 2: Direct-First
```
Host: [ Direct P2P + Broker fallback ]
Guest: [ Prefer direct ]
```

### Phase 3: Direct Only
```
Host: [ Direct P2P only ]
Guest: [ Direct P2P only ]
Broker/TURN: Decommission
```

---

## 11. Configuration Changes

### 11.1 Host Preferences

```swift
extension RemoteCoOpPreferences {
    enum ConnectionMode: String, Codable {
        case autoDiscover  // Bonjour + manual
        case directOnly    // Direct only
        case stunOnly      // STUN only
    }
    
    var connectionMode: ConnectionMode {
        get
        set
    }
    
    var enableUPnP: Bool {
        get
        set
    }
    
    var enableBonjour: Bool {
        get
        set
    }
}
```

### 11.2 Build Configuration

```ruby
# Remove from Podfile or Package.swift
# - coturn
# - broker dependencies

# Update
# - NVSTSignaling → RemoteCoOpDirectSignaling
# - NVSTSignalingConfiguration → DirectSignalingConfiguration
```

---

## 12. References

### 12.1 WebRTC Specifications
- [WebRTC Connectivity](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Connectivity)
- [Perfect Negotiation](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Perfect_negotiation)
- [RTCPeerConnection](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection)

### 12.2 UPnP Documentation
- [UPnP Device Architecture](http://UPnP.org/specs/arch/UPnP-arch-DeviceArchitecture-v1.1.pdf)
- [SSDP Discovery](https://tools.ietf.org/html/draft-caiUPnP-ssdp-1905)

### 12.3 Bonjour/mDNS
- [RFC 6763 - mDNS](https://tools.ietf.org/html/rfc6763)
- [RFC 6762 - DNS-SD](https://tools.ietf.org/html/rfc6762)

---

## 13. Success Criteria

| Requirement | Target | Method |
|-------------|--------|--------|
| Connection time | < 3s | Manual testing |
| First frame | < 100ms | Automated testing |
| Input latency | < 50ms | Automated testing |
| Local discovery | < 2s | Bonjour test |
| NAT traversal | > 90% success | Field testing |
| No broker/TURN | 100% removed | Code review |

---

**Document Status:** Draft  
**Next Steps:** Kickoff meeting, assign tasks, begin Phase 1
