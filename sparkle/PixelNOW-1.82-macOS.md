# PixelNOW 1.82

## Reliability

- Recover Metal video presentation after macOS Space, display, backing-property, or app-activation changes by refreshing the display link and drawable.
- Retire decoded frames that remain unpresented after one second so stale presentation tickets cannot keep render slots occupied.
- Keep the NVST renderer attached while its window moves between desktops, and shut it down when the stream surface is dismantled.

## Release qualification

This archive is signed with the available Apple Development identity. It is not notarized or stapled because this release setup does not have a Developer ID Application certificate or notarization credentials. macOS may require approval in Security settings before opening the app.
