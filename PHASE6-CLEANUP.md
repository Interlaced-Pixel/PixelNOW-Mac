# Phase 6: Cleanup - Remove broker/TURN/HMAC dependencies

## Overview

This phase completes the migration from broker-based signaling (TURN/HMAC-relay) to direct peer-to-peer mode. The implementation maintains backward compatibility for configuration migration while deprecating broker-specific code.

## Files Created

1. **RemoteCoOpHostSessionFactory.swift** (NEW)
   - `RemoteCoOpConnectionMode` enum: `broker` and `direct` modes
   - `RemoteCoOpSessionFactory`: Creates appropriate session based on mode
   - `RemoteCoOpBrokerHostSession`: Broker mode session (deprecated)
   - `RemoteCoOpDirectHostSessionFactory`: Direct mode session factory
   - `RemoteCoOpDirectHostSessionInternal`: Internal direct session implementation
   - `RemoteCoOpHostSessionProtocol`: Protocol for all host sessions

2. **DEPRECATION-NOTICE.md** (NEW)
   - Complete deprecation guide for broker mode
   - Migration instructions for users and developers
   - Configuration examples for direct mode

3. **remote-coop-direct-config.json** (NEW)
   - JSON example configuration for direct mode
   - Network configuration, discovery settings, security settings

## Files Modified

1. **RemoteCoOpPreferences.swift** (MODIFIED)
   - `migratedTransportMode()`: Automatically migrates broker/relay configs to direct-only
   - `load()`: Uses migration function to convert transport mode on load

2. **RemoteCoOpHostSession.swift** (MODIFIED)
   - Added deprecation notice: `@available(*, deprecated) supportsBrokerMode()`
   - Simplified direct mode check in `startInvite()`: removed `&& preferences.transportMode != .automatic` condition

## Cleanup Summary

### Broker/TURN/HMAC Dependencies Removed
- ✅ Broker signaling no longer used by default
- ✅ TURN server configuration removed from default network settings
- ✅ HMAC validation still present for invite tokens (security maintained)
- ✅ WebSocket signaling session available but not default

### Migration Handling
- ✅ Automatic migration: `relayOnly` → `directOnly` on config load
- ✅ Broker mode still supported for backward compatibility
- ✅ Deprecation warnings guide users to migrate

### Direct Mode Features
- ✅ Peer-to-peer WebRTC communication
- ✅ Local signaling server on port 32189
- ✅ UPnP automatic port forwarding
- ✅ Bonjour/Zeroconf local discovery
- ✅ PIN authentication for guest connections

## Architecture Changes

```
Before:
Broker Mode → WebSocketSignalingSession → TURN Server → HMAC Validation

After:
Direct Mode → DirectSignalingSession → Peer-to-Peer WebRTC
          → Bonjour Discovery
          → UPnP Auto-Port-Forward
```

## Configuration Migration

### Old Config (Broker/Relay)
```json
{
  "transportMode": "relayOnly",
  "signalingServerURL": "wss://relay.server.com:8788/remote-coop",
  "guestJoinBaseURL": "https://relay.server.com:8788"
}
```

### New Config (Direct)
```json
{
  "transportMode": "directOnly",
  "signalingPort": 32189,
  "enableUPnP": true,
  "enableBonjour": true
}
```

## Backward Compatibility

- ✅ Existing broker configs automatically migrate to directOnly
- ✅ Broker session still available via `RemoteCoOpConnectionMode.broker`
- ✅ HMAC-SHA256 token validation still used for security
- ✅ Invite code generation unchanged

## Deprecated APIs

```swift
@available(*, deprecated, message: "Broker mode is deprecated.")
public static func supportsBrokerMode() -> Bool
```

## Testing Recommendations

1. Verify existing broker configs migrate to directOnly
2. Test direct mode connection with UPnP enabled
3. Test Bonjour discovery on local network
4. Test PIN authentication flow
5. Verify invite token signing still works

## Next Steps (Future)

- Remove `RemoteCoOpBrokerHostSession` completely
- Remove broker-specific preferences keys
- Remove deprecated `supportsBrokerMode()` method
- Update documentation to reflect direct-only recommendation
