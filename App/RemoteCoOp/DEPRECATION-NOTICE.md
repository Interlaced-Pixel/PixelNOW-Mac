# Remote Co-Op Broker Mode Deprecation Notice

**Status**: DEPRECATED - Will be removed in future version

## Overview

Broker-based Remote Co-Op functionality (TURN/HMAC-based relay signaling) is deprecated and will be removed in a future version. Users should migrate to direct mode (peer-to-peer WebRTC with local signaling).

## What Changed

### Phase 6: Cleanup - Removed Broker/TURN/HMAC Dependencies

- **Broker Signaling**: Deprecated `RemoteCoOpWebSocketSignalingSession` for broker-based signaling
- **TURN Servers**: No longer configured or used by default
- **HMAC Validation**: Removed from signaling flow
- **Direct Mode**: Now the recommended and default mode for Remote Co-Op

## Migration Guide

### For Users

1. **Update Preferences**: Existing configurations using broker/relay mode will automatically migrate to `directOnly` mode on next launch
2. **Network Configuration**: Ensure your network allows:
   - WebSocket connections (WS/WSS) for peer signaling
   - UPnP for automatic port forwarding
   - Bonjour/Zeroconf for local discovery

### For Developers

#### Before (Broker Mode)
```swift
let session = RemoteCoOpWebSocketSignalingSession(serverURL: URL(string: "wss://relay.server.com")!)
let coordinator = RemoteCoOpHostCoordinator(hostSession: hostSession, signaling: session)
```

#### After (Direct Mode)
```swift
let session = RemoteCoOpDirectSignalingSession(port: 32189, hostSession: hostSession)
let coordinator = RemoteCoOpHostCoordinator(hostSession: hostSession, signaling: session)
```

#### Using Session Factory
```swift
let factory = RemoteCoOpSessionFactory()
let session = factory.makeSession(connectionMode: .direct, preferences: preferences)
```

## Configuration Examples

### Direct Mode (Recommended)

```json
{
  "connectionMode": "direct",
  "transportMode": "directOnly",
  "enableUPnP": true,
  "enableBonjour": true,
  "signalingPort": 32189
}
```

### Automatic Mode (with Direct Fallback)

```json
{
  "connectionMode": "direct",
  "transportMode": "automatic",
  "enableUPnP": true,
  "enableBonjour": true,
  "signalingPort": 32189
}
```

## Deprecated APIs

### Broker-Specific Methods
```swift
@available(*, deprecated, message: "Broker mode is deprecated. Use direct mode instead.")
public static func supportsBrokerMode() -> Bool
```

### Signal Server URL
```swift
// Old: Signaling server URL no longer used
preferences.signalingServerURL = "wss://relay.server.com"

// New: Use turnServers for STUN/TURN configuration if needed
let config = RemoteCoOpNetworkConfiguration(
    transportMode: .directOnly,
    iceServers: [
        RemoteCoOpICEServer(urls: ["stun:stun.l.google.com:19302"])
    ]
)
```

## Compatibility Notes

- ✅ **Backward Compatible**: Existing config with `relayOnly` mode automatically migrate to `directOnly`
- ❌ **Broker URL Migration**: Custom broker URLs are no longer supported
- ✅ **HMAC Tokens**: Invite token signing still uses HMAC-SHA256 for security
- ✅ **WebRTC**: Full WebRTC stack remains unchanged

## Timeline

- **v1.75**: Broker mode deprecated, direct mode default
- **v1.76+**: Broker mode removal (planned)

## Reporting Issues

If you encounter issues during migration:
1. Check network settings (firewall, UPnP, port forwarding)
2. Verify Bonjour/Zeroconf is enabled on local network
3. Review `RemoteCoOpDirectSignalingSession` logs
4. Check WebRTC telemetry for connection diagnostics

## See Also

- `RemoteCoOpDirectHostSession`
- `RemoteCoOpDirectSignalingSession`
- `RemoteCoOpHostSessionFactory`
- `RemoteCoOpNetworkConfiguration`
