# Sparkle release process

PixelNOW uses Sparkle 2.10.0 through the Xcode Swift Package Manager dependency. The application feed is the repository's `appcast.xml` file, served over HTTPS from GitHub's raw content endpoint.

## One-time signing setup

Run Sparkle's `generate_keys` tool on the release Mac. Keep the private Ed25519 key in the macOS Keychain or a protected release secret. The public key belongs in `PixelNOW-Info.plist` as `SUPublicEDKey`; never commit the private key.

## Build and publish an update

1. Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` together.
2. Create a signed and notarized `PixelNOW-<version>-macOS.zip` containing only `PixelNOW.app`.
3. Place the archive and matching release notes in a private local update-archive directory.
4. Run Sparkle's appcast generator, writing the output to `appcast.xml`:

```sh
scripts/generate-sparkle-appcast.sh \
  /path/to/Sparkle/bin \
  /path/to/update-archives \
  appcast.xml \
  https://github.com/Interlaced-Pixel/PixelNOW-Mac/releases/download/v1.78/
```

5. Verify the generated enclosure URL, `sparkle:edSignature`, archive length, version, minimum macOS requirement, and release notes.
6. Upload the archive to the matching GitHub release, commit and push the generated `appcast.xml`, then verify the raw HTTPS feed from a fresh request.

The archive must be signed by Apple for distribution and by Sparkle's Ed25519 key for update verification. `SUVerifyUpdateBeforeExtraction` makes Sparkle verify the archive before extraction. A future release may enable `SURequireSignedFeed` after the published appcast is being generated and served with feed signatures consistently.

## Verification checklist

- `codesign --verify --deep --strict PixelNOW.app`
- Confirm `Contents/Frameworks/Sparkle.framework` and its helper components are embedded and signed.
- Notarize and staple the release application before archiving it.
- Test the manual menu check from an older installed build.
- Test automatic checks, disabled checks, cancellation, offline access, invalid signatures, and relaunch.
- Confirm the appcast URL is HTTPS and has the expected update item before publishing.
