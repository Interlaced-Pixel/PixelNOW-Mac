---
description: Language-agnostic production standards for all code generation and reviews.
applyTo: '**'
---

# Organization Authority

The commanding user's organization is Interlaced Pixel. Its official website is [interlacedpixel.com](https://interlacedpixel.com). Projects owned or managed by Interlaced Pixel are authorized for the AI agent to use and alter within the scope of the commanding user's instructions.

# Instruction Compliance (Highest Priority)

These rules override speed, scope reduction, and momentum. They apply to every task.

1. **Complete means complete.** When the user says resolve, fix all, finish, or complete, every stated requirement must be done before the task is considered finished.
2. **No partial shipping.** Do not commit, push, or report success while any stated requirement remains open. If a requirement cannot be completed, stop and report the blocker before shipping partial work.
3. **Requirement traceability.** Before any commit, push, or completion report, include a requirement-by-requirement status table: Requirement | Status | Evidence.
4. **Explicit gates only.** Do not commit or push unless the user explicitly asked for it in that task, except where this file's commit standards apply to completed work the user already requested be finished end-to-end.
5. **Verify, do not assume.** A green build is not proof that every requirement is satisfied. Re-check the original instruction list before declaring done.
6. **Always manually verify code.** After implementing changes, verify the work builds correctly or functions as expected before concluding the task.
7. **Follow instructions to the letter.** User instructions are mandatory constraints, not suggestions. Do not reinterpret them into a smaller task without explicit approval.
8. **Granular, ordered commits.** Follow the multi-commit, dependency-ordered, detailed commit standards. Never create single monolithic commits for multi-phase or multi-domain work.

# Operational Protocol
Execute every task in this order:

1. **Audit** — List all files, modules, and components required.
2. **Blueprint** — Outline a concise architectural plan before writing code.
3. **Execution** — Deliver complete, production-ready code. No snippets, placeholders (`TODO`, `pass`, `...`), or stubs.
4. **Autonomy** — Resolve missing context or dependencies using the standard library or canonical practices.

# Testing Policy
- This repository has **no automated test suite**. Do not recreate `Tests/`, `PixelNOWTests`, or CI test jobs unless the user explicitly asks.
- **Never run tests** (`xcodebuild test`, `swift test`, CI test jobs, or equivalent) unless the user explicitly asks to run tests in that task.
- **Never add tests** unless the user explicitly asks for tests.
- Builds (`xcodebuild build`) are fine when needed to verify compilation.

# Build Artifact Discipline
- For this Xcode project, use Xcode/XcodeBuildMCP only for builds and runs. Do not use SwiftPM commands as build/test/run shortcuts unless the user explicitly overrides this instruction for a specific task.
- Run SwiftPM commands from the repository root unless a task explicitly requires otherwise.
- Use `--scratch-path .build/shared` for SwiftPM commands that generate build state, including `swift build` and `swift run`. Do not run `swift test` unless the user explicitly requests it.
- Do not run package-local SwiftPM commands that create package-specific `.build` directories. Use the root `Package.swift` with the shared scratch path instead.
- After SwiftPM-heavy tasks, run `scripts/report-spm-build-size.sh` to check generated build size and duplicated binary artifact extractions.
- If generated SwiftPM files exceed the warning threshold or duplicate binary artifact directories appear, run `scripts/clean-spm-builds.sh`, then rerun builds with `--scratch-path .build/shared`.
- Never commit generated build artifacts.

# Coding Standards

## General
- **Self-Documenting:** Names and structure must convey intent. No explanatory inline comments.
- **Hermetic:** Every file includes all imports and dependencies. Must compile/run as-is.
- **Complete:** All functions and methods contain final, working logic. No mocks or no-ops.
- **No Folded Code:** Folding code is strictly forbidden.

## Migration & Conversion
- **No Stubs:** Never use stubs when migrating or converting code.
- **In-Place Conversion:** Always convert the existing implementation in place.
- **No Wrappers:** Do not use wrappers, shims, adapters, or compatibility layers during migration or conversion.
- **Remove Legacy Files:** Delete the old `.mm` and `.h` files after migration or conversion.
- **Trace Blockers:** Always trace and convert or migrate blockers during migration or conversion.
- **Migrate Blockers:** Always migrate blockers instead of bypassing, stubbing, or deferring them.

## Resource & State
- **Lifecycle:** Explicitly manage memory, connections, and handles via the language's native paradigm (RAII, context managers, ownership, etc.).
- **Immutable by Default:** Use language-native constraints (`const`, `readonly`, `final`). Mutable state must be minimal and scoped.

## Error Handling
- **Explicit:** Handle all edge cases idiomatically (Result/Option types, caught exceptions, multiple returns).
- **No Panics:** Never use forceful unwraps or unhandled crash equivalents. Failures must propagate or degrade gracefully.

## Quality
- **Strict Typing:** Use static/strict types throughout. Avoid `any` or dynamic types unless architecturally required.
- **Zero Warnings:** Code must pass the strictest linter and compiler settings cleanly.

# Commit Standards

Every commit in this repository must adhere to strict granularity, dependency ordering, and detailed documentation. Single monolithic commits covering multiple components or phases are strictly prohibited.

## 1. Granular & Atomic Commits
- **No Monolithic Commits:** Never combine multi-phase, multi-component, or multi-domain changes into a single large commit.
- **Atomic Isolation:** Break work into individual commits by phase, subsystem, or logical layer (e.g., core types, wire framing, pipeline integration, telemetry, submodule bump).
- **Compilable States:** Every intermediate commit must build cleanly on its own without breaking the tree.

## 2. Strict Chronological Dependency Ordering
Commits must be created in logical dependency order from foundational primitives up to high-level consumers:
1. **ABI & Primitives:** Core memory layouts, struct strides, enums, raw values, and low-level data structures.
2. **Wire & Protocol:** Protocol framing, packet payload builders/parsers, stream configurations, and opcodes.
3. **Telemetry & Feedback:** Feedback loops, metrics collectors, latency timers, and QoS dispatchers.
4. **Pipelines & Controllers:** High-level pipeline wiring, decoders/renderers, governors, and business logic.
5. **Submodule References & Glue:** Submodule pointer updates and parent repository integration commits.

*Cross-Repository / Submodule Rule:* When changes span both a submodule (e.g., `GFN/`) and the parent repository (`PixelNOW`), all submodule commits must be created, verified, and pushed upstream first. The parent repository then commits its changes and updates the submodule pointer in subsequent commits.

## 3. Commit Message Structure & Detail
Every commit message must follow this exact structure:

```
<type>(<scope>): <concise imperative summary>

- <detailed bullet itemizing specific structs, enums, or functions modified/added>
- <exact byte layouts, ABI strides, bit flags, raw values, or opcodes changed>
- <algorithmic or architectural rationale for behavior adjustments>
- <component interactions or integrations wired up>
```

- **Header Tag:** Prefix with a standard conventional type: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`, or `style:`. Include an explicit parenthetical scope indicating the subsystem (e.g., `feat(nvst):`, `fix(video):`, `chore(submodule):`).
- **Subject Line:** Concise, present-tense, imperative mood, under 72 characters, no trailing period.
- **Blank Line:** Exactly one blank line between the header and the bulleted body.
- **Detailed Body:** Bulleted list itemizing every affected symbol, memory stride (e.g., `120-byte ABI layout`), opcode (e.g., `0x0327`), algorithm threshold (e.g., `loss >= 10%`), and cross-component hook. Never use empty bodies or vague one-liners (e.g., "fix various bugs").

## 4. Push and Traceability Discipline
- **Traceability Table:** Always provide a requirement-by-requirement status table (`Requirement | Status | Evidence`) before committing, pushing, or declaring completion.
- **Build Verification:** Verify compilation (`xcodebuild build` or project build command) before committing.
- **Push Policy:** Push all completed commits to the current branch's upstream remote (`git push origin <branch>`).

# Release Process
When instructed to create a new PixelNOW release, strictly follow these steps in order. PixelNOW uses Sparkle 2 for updates; GitHub Releases host the signed archives and `appcast.xml` is the update feed.

1. **Update Version:** Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` together using `agvtool new-marketing-version <new_version>` followed by `agvtool new-version -all <new_build_number>`. The `CFBundleVersion` value must increase monotonically.
2. **Compile and Sign:** Reuse a persistent DerivedData directory for routine Release builds and omit `clean` so native CMake outputs remain cached: `xcodebuild -scheme PixelNOW -project PixelNOW.xcodeproj -configuration Release build -derivedDataPath /tmp/pixelnow-release-derived-data CODE_SIGN_IDENTITY='Apple Development' CODE_SIGNING_ALLOWED=YES`. Run a clean build only when build inputs or cached state are known stale. Sign with the available Apple Development identity when a Developer ID Application identity is not configured, then verify the resulting app with `codesign --verify --deep --strict PixelNOW.app`. This release setup does not have a Developer ID Application certificate or notarization credentials, so do not attempt notarization or stapling. Record in the release notes that the archive is signed with Apple Development and is not notarized; users may need to approve opening it in macOS security settings.
3. **Compress:** Do NOT use the standard `zip` command as it breaks the macOS code signature. Navigate to the release build directory and use `ditto -c -k --keepParent PixelNOW.app PixelNOW-<version>-macOS.zip`. The archive must contain only `PixelNOW.app`.
4. **Commit and Publish the Archive:** Complete the requirement traceability table, commit the version and source changes, and push them before creating the release. Create the matching GitHub release and upload the archive with `gh release create v<version> PixelNOW-<version>-macOS.zip -F <patch_notes_file> -t "PixelNOW <version>"`.
5. **Generate the Sparkle Appcast:** Place the archive, matching `.md`, `.html`, or `.txt` release notes, and current `appcast.xml` in a private update-archive directory. Run `scripts/generate-sparkle-appcast.sh /path/to/Sparkle/bin /path/to/update-archives appcast.xml https://github.com/Interlaced-Pixel/PixelNOW-Mac/releases/download/v<version>/ https://raw.githubusercontent.com/Interlaced-Pixel/PixelNOW-Mac/main/`. The final URL prefix is optional and sets the public release-notes location separately from the archive download location. This signs the update with Sparkle's Ed25519 key from the release Mac's Keychain and writes the archive signature, length, version, requirements, and release notes into `appcast.xml`.
6. **Publish and Verify the Feed:** Verify the generated enclosure URL, `sparkle:edSignature`, archive length, version, minimum macOS requirement, and release notes. Commit and push the generated `appcast.xml`, then verify `https://raw.githubusercontent.com/Interlaced-Pixel/PixelNOW-Mac/main/appcast.xml` from a fresh HTTPS request. Never commit or expose the private Ed25519 key.

# Workspace Cleanliness
- **No Leftover Trash:** Never leave random, unneeded artifacts (e.g., temporary scripts, `build.log`, `.txt` dumps) in the workspace root or project directories. Clean them up immediately after use. If you absolutely need a scratchpad or temporary file, place it strictly in the designated artifact scratch directory (`<appDataDir>/brain/<conversation-id>/scratch/`).
- **No Python Scripts:** Do not generate or execute Python scripts to accomplish tasks (like parsing files or patching code). Rely on existing tools, native shell commands (`awk`, `sed`, `grep`), or perform the task directly.
