# PixelNOW 1.78

## Native NVST streaming

- Align stale-session recovery and resume allocation with the vendor request flow.
- Surface live launch diagnostics for faster diagnosis of stream startup failures.
- Preserve negotiated video precision and bound presentation pacing.
- Own the native NVST bundle and CoreAudio lifecycle directly, with native stream settings and recording media paths.
- Remove retired WebRTC runtime artifacts and legacy build paths.

## Updates and packaging

- Replace the custom updater with Sparkle 2 and publish a signed appcast feed.
- Package the privileged AWDL helper and gate AWDL control by stream activity.
- Remove the disabled remote co-op stack and its unused deployment assets.

## Qualification note

This archive passed Release compilation, code-sign verification, Sparkle framework validation, native NVST bundle validation, and archive extraction checks. It was signed with the available Apple Development identity and was not notarized because Developer ID and notarization credentials were unavailable on the release machine.
