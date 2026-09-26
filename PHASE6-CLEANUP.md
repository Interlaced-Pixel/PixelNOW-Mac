# Remote Co-Op direct-only completion record

The Remote Co-Op implementation now has one supported topology: direct
WebRTC between the macOS host and browser guest.

Completed cleanup:

- Removed alternate transport modes and their preference migrations.
- Removed server URL and guest URL preferences.
- Removed host-approval compatibility state; a valid room code admits a guest
  and the host assigns the input slot.
- Removed signed invite payloads; the active room code is the admission
  credential and is never persisted after the room ends.
- Removed the retired signaling client and server-side media infrastructure.
- Removed administrative panel and service installer artifacts.
- Removed browser mode switching and signaling input fallback.
- Updated Bonjour metadata and the runtime manifest to describe one direct
  path.
- Added direct-only operational and failure behavior documentation.

The remaining signaling service is rendezvous-only. It forwards negotiation
messages while a room is active and never carries media or controller input.
