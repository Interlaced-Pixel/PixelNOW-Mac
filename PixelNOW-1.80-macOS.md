# PixelNOW 1.80

## Reliability

- Prevent a crash when the AWDL helper replies to a restore request from its XPC queue.
- Keep restore reply handling outside the main actor and report rejected restore requests safely.

## Release qualification

This archive is signed with the available Apple Development identity. It is not notarized or stapled because this release setup does not have a Developer ID Application certificate or notarization credentials. macOS may require approval in Security settings before opening the app.
