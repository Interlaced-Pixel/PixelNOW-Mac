# NVST vendor parity repair plan

Date: October 8, 2026; finalized October 9, 2026. Implementation phases are complete. The user ended further runtime qualification and directed finalization: "Let's move on. Finalize this." The original acceptance scenarios below are retained as historical criteria, not publication blockers. No desktop automation or framework patching is permitted. See [final handoff](/Users/jayian/Projects/PixelNOW/NVST_VENDOR_PARITY_HANDOFF.md) and [implementation ledger](/Users/jayian/Projects/PixelNOW/NVST_VENDOR_PARITY_IMPLEMENTATION.md). Symptom resolution remains unproven.

Repair the client defects associated with poor image quality, stuttering, and high latency by reproducing the vendor's feedback semantics, frame lifecycle, adaptation ownership, and presentation scheduling. Preserve the user's configured quality ceiling. Prefer behavior demonstrated by the bundled vendor client over new thresholds or heuristics.

This plan builds on the [source and runtime diagnosis](/Users/jayian/Projects/PixelNOW/Docs/NVST_STREAM_QUALITY_DIAGNOSIS.md). The inspected checkout was PixelNOW `7ee8caed`, with GFN `3f51bf8`; vendor streamer version `2.0.88.129`. Existing edits to `App/RemoteCoOp/RemoteCoOpDirectSignalingSession.swift` are outside this repair.

## NVST scope and evidence rule

The commanding user's scope is native NVST quality, stuttering and latency. The video path under repair is `NVSTCoreTransport.startVideo` → `NVSTWireReceiver` → `NvstVideoReceiver` / FEC / reassembly → `NvstVideoPipeline` → `NvstVideoToolboxDecoder` → `NVSTCoreVideoRenderer` / `NVSTMetalVideoView`. The repair uses the NVST RTSP/ANNOUNCE configuration, Mjolnir video packet format, NVST server-control commands and Bifrost/Geronimo native-video algorithms.

Every remaining implementation item must identify its native NVST call path, bundled vendor NVST evidence and effect on the reported symptoms. RTP, RTCP, SRTP, NACK and QoS terminology alone does not establish a WebRTC video path. Generic WebRTC congestion control, video jitter buffers, decoder/render policies, browser signaling, peer-connection tuning and Remote Co-Op networking are outside this plan. A WebRTC-related change is permitted only when a traced NVST vendor dependency requires it; record that dependency and the smallest required change in the implementation ledger before editing.

| Boundary | Inclusion and evidence |
|---|---|
| Native NVST video, feedback and presentation | Core repair scope. `NVSTCoreVideo.swift:9` constructs the native wire receiver and VideoToolbox decoder; it does not use an RTC video track for this receive/decode path. Match native NVST version, profile and algorithms in vendor comparisons. |
| `NvstWebRtcBundle` and delegates | Limited NVST dependency: existing ICE/DTLS/SCTP transport carries native session control/input/feedback and audio. `NVSTCoreVideo.swift:66` sends native NACK commands through it; QoS/processing use the same partially reliable control writer. Vendor `ClientSession::SetupDataChannel` obtains `WebRtcTransport::GetSctpTransporter` at `libBifrost2.dylib.s:260146`; native control channel names appear at 196985/197029/197076. This permits required NVST channel routing/reliability and audio integration work, not a generic WebRTC video repair. |
| Shared recorder and decoded-frame relay | Preserve the existing native decoded-buffer boundary only when affected by lifecycle/ownership changes. `NVSTCoreVideo.swift:25` calls `appendNativePixelBuffer`; line 26 forwards the same decoded buffer to the relay. `WebRTCStreamRecording.swift:455` accepts native pixel buffers despite its name. These are focused integration regression checks, not vendor-parity algorithms or independent WebRTC/co-op transport qualification gates. Do not modify downstream recording, encoding or peer networking without an evidenced NVST dependency. |
| Audio latency attribution | Inspect the actual audio route used by the NVST session for synchronization and buffer-delay attribution. Change policy only for a demonstrated mismatch in the vendor's NVST audio path. Generic WebRTC microphone, audio-processing or codec tuning is excluded. |
| Framework and bundle validation | Validate existing dependencies needed to build/run NVST. A required WebRTC framework in the app bundle does not expand the protocol repair scope. |
| RTT measurement limits | Preserve the existing public transport observation and record its difference from the vendor's private SCTP metric. Correlate it with native retransmission timing during qualification. Framework patching/rebuilding has been rejected by the user and is excluded. |

## Audit: affected components

| Component | Files and responsibilities |
|---|---|
| Vendor reference | `Docs/vendor/libBifrost2.dylib.s`, `Docs/vendor/libGeronimo.dylib.s`, corresponding ARM64 libraries under `Docs/vendor/decomp/`: serializers, estimators, timing, decoder, render queue, and recovery policy |
| Receive and frame primitives | `GFN/NVST/Core/NvstVideoPacket.swift`, `NvstVideoReceiver.swift`, `NvstFrameReassembler.swift`, `NvstInboundCounters.swift`, `NVSTWireReceiver.swift`, `NvstStreamProcessor.swift`: packet identity, arrival time, loss, reordering, and assembled frame metadata |
| Recovery and transport feedback | `GFN/NVST/Core/NvstFecRecovery.swift`, `NvstFeedbackSender.swift`, `NvstRtcp.swift`, `NvstSrtcp.swift`: FEC, NACK, control timing, and recovery feedback |
| Wire formats and estimators | `GFN/NVST/Core/NvstQosReport.swift`, `NvstStreamingCommand.swift`, `NvstFramePacingReport.swift`, `NvstFrameAck.swift`, `NvstQosManager.swift`, `NVSCQoSTypes.swift`, `NVSCConfigTypes.swift`: negotiated versions, typed fields, serialization, estimation, smoothing, and DJB state |
| Session negotiation | `GFN/NVST/Rtsp/NvstRtspSdp.swift`, `NvstRtspSdp+Announce.swift`, `NvstCapturedAnnounce.swift`: offered capabilities, client configuration, ANNOUNCE attributes, and version selection |
| App transport and quality settings | `App/Stream/nvst/NVSTCoreTransport.swift`, `NVSTCoreVideo.swift`, `NVSTCoreInput.swift`, `NativeNVSTNetworkGovernor.swift`, `NativeNVSTDecodeBudget.swift`, `View/Stream/nvst/NativeNVSTMediaStreamSurface.swift`: native feedback dispatch, settings ownership and HUD snapshots; `NvstWebRtcBundleDelegates.swift` only for evidenced NVST control responses. The two governors are historical audit targets already removed in the current repair. |
| Decode lifecycle | `App/Stream/nvst/NvstVideoPipeline.swift`, `NvstVideoToolboxDecoder.swift`, `NvstVideoToolboxDecoder+Format.swift`: session clock, admission, frame-indexed completion, format changes, and decoder teardown |
| Presentation | `App/Stream/nvst/NVSTCoreVideoRenderer.swift`, `NVSTMetalVideoView.swift`: display scheduling, bounded render queue, GPU completion, presentation timestamps, and mode behavior |
| Conditional native-buffer consumer checks | `App/RemoteCoOp/RemoteCoOpHostVideoRelay.swift`, `App/Stream/webrtc/WebRTCStreamRecording.swift`: check NVST decoded-buffer delivery, lifetime and timestamps only where affected; exclude independent WebRTC/co-op transport repairs and recording feature work |
| Qualification | `logs/PixelNOW.log`, `PixelNOW.xcodeproj`, `scripts/validate-native-nvst-bundle.sh`, `scripts/validate-native-nvst-runtime-manifest.sh`: session evidence, Xcode builds, and applicable bundle checks |

Paths grouped in this inventory are relative to `/Users/jayian/Projects/PixelNOW`; implementation reviews must resolve each affected call site before editing.

## Blueprint and parity constraints

The intended flow is: authenticated packet arrival → wrap-aware receive/estimator state → identified assembled frame → registered decoder operation → identified decode outcome → vendor-compatible render queue → measured presentation outcome → one negotiated feedback producer. One transport owner applies user settings and vendor-supported adaptation; the UI reads coherent snapshots and submits user intent.

Use a monotonic session clock for local durations and carry server RTP time separately. Distinguish packet arrival, assembly completion, queue admission, decode submission/completion, render submission/completion, and presentation. A callback timestamp bounds observable decoder latency; it is not automatically hardware execution time. Control RTT, one-way-delay estimates, audio-buffer delay, and input-to-photon latency must remain separate measurements.

Change existing implementations in place. Do not introduce migration shims, placeholder estimates, fake successful completions, or a second adaptation layer. Keep network receive independent of decoder/GPU waits. Carry stable frame identity and session generation through every asynchronous operation, with one terminal outcome per submitted operation and explicit resource cleanup.

Vendor assembly establishes concrete field writes, but some names, units, and defaults still require tracing. Match the active codec, architecture, negotiated version, and user profile; do not copy every attribute from one captured session. Record any unavoidable macOS API difference with its measurable effect and the vendor behavior it preserves.

## Phase 0 — Establish the parity contract and comparison baseline

Before selecting algorithms or changing uncertain fields:

1. Create a field ledger for commands `0x0207`, `0x0203`, and `0x0204`: version selection, payload offsets, widths, endianness, units, clock origin, flags, sentinels, cadence, and transport reliability. Trace every emitted field to its producer and consumer.
2. Resolve bandwidth-estimator state feeding vendor QoS offsets `0x0c`, `0x18`, and `0x2c`; trace both estimated-server-RTP methods and the one-way-delay baseline. Packet throughput and outgoing feedback size are not substitutes for this estimator.
3. Trace feedback-version negotiation and the vendor's dynamic maximum-bitrate feature. Determine which adaptation occurs on the server and which client cap updates are profile-dependent. Trace DJB request/response routing and how queue parameters affect the renderer.
4. Check ARM64 decoder behavior and the active codec against the inspected x86-64 path. Verify asynchronous flags, callback/image ownership, hardware decoder policy, and reorder behavior before choosing the completion model.
5. Capture a repeatable moving scene using PixelNOW and the official client's native NVST video profile on the same Mac, display, server region, codec, resolution, frame rate, bitrate setting, and network. Verify the native transport/profile and include session negotiation and outgoing feedback traces. If settings or server conditions differ, record the difference rather than presenting the runs as matched. The user's original match ended naturally; the later qualification session stalled at shader preload. Neither that session nor earlier runs satisfy this gate. Desktop automation must not be used to complete it under current instructions.

Vendor starting points: [QoS version selection](/Users/jayian/Projects/PixelNOW/Docs/vendor/libBifrost2.dylib.s:249959), [QoS v7 fill](/Users/jayian/Projects/PixelNOW/Docs/vendor/libBifrost2.dylib.s:250420), [bandwidth state](/Users/jayian/Projects/PixelNOW/Docs/vendor/libBifrost2.dylib.s:252247), [processing feedback](/Users/jayian/Projects/PixelNOW/Docs/vendor/libBifrost2.dylib.s:250955), [decoder](/Users/jayian/Projects/PixelNOW/Docs/vendor/libGeronimo.dylib.s:342564), [render queue](/Users/jayian/Projects/PixelNOW/Docs/vendor/libGeronimo.dylib.s:246800).

**Exit evidence:** completed field/configuration ledger and comparable baseline measurements. An unresolved field blocks the serializer or estimator that depends on it; it must not be populated with an unrelated statistic. Proven independent lifecycle repairs can proceed while other vendor traces are completed.

## Phase 1 — Establish frame identity, clock domains, and lifecycle data

Dependencies: Phase 0 identity and timebase findings.

- Add final, typed metadata to the existing receive/reassembly path: stream/frame identity, session generation, server RTP timestamp, first relevant packet arrival, assembly completion, and recovery/loss classification. Determine the vendor's arrival definition for recovered and reordered packets.
- Extend wrapped sequence numbers and RTP timestamps consistently. Preserve duplicate/reorder semantics and estimator sampling rules; validate around wrap boundaries and stream restarts with manual trace inspection.
- Replace wall-clock duration calculations in `NvstSessionClock` with a monotonic origin. Use explicit units and conversions matching the field ledger; never serialize local monotonic time directly as server RTP time.
- Define terminal decode/render outcomes and ownership of outstanding state. Add complete primitives before wiring consumers; do not create unused placeholder methods.

**Exit evidence:** traced frame identities survive loss, reordering, wrap, recovery, and session changes; clock adjustment does not change measured durations. Xcode builds compile the complete receive-to-app interfaces.

## Phase 2 — Correct negotiation and wire serialization

Dependencies: Phase 0 completed wire ledger; Phase 1 metadata primitives.

- Parse and retain the applicable server/client/configured feedback capabilities. Select the vendor-supported processing and QoS version for the session; unsupported mandatory combinations fail explicitly instead of silently sending a hardcoded version.
- Correct QoS v7's 52-byte layout. In particular, separate the two 16-bit fields at `0x18`/`0x1a`, report vendor-scaled interval loss at `0x1a`, and use estimator-backed values and real processing capacities. Restore verified flags, reserved bytes, and clock conversions.
- Correct v1 `0x0203`: 16-byte header, 24-byte records, frame number at record offset 0, padding at 4, 64-bit timing at 8, and a zero 64-bit value at 16 in the inspected vendor path. Trace the timing's units and meaning before serialization. Verify the v5 28-byte report's values, not just its size.
- Verify the 102-byte `0x0204` blob against the vendor's version-aware serializer, including identifiers, stage meanings, flags, unavailable-value representation, and failure handling. Remove repeated decode values from unrelated stages once real producers are available in Phase 4.
- Consolidate dispatch so one selected `0x0203` version is emitted at the vendor cadence and reliability. Keep independent acknowledgment/blob messages only where the vendor lifecycle requires them.

**Exit evidence:** manually inspect complete decrypted payloads against the ledger for clean, lossy, slow-decode, and no-presentation cases. Sizes, offsets, values, version negotiation, cadence, and delivery channel all match; no simultaneous unnegotiated v1/v5 stream remains.

## Phase 3 — Implement real estimator input and coherent feedback state

Dependencies: Phases 1–2. Implement in the GFN core before app-level adaptation changes.

- Reconstruct the vendor bandwidth/clock estimator from packet arrival, RTP progression, packet sizes, and the vendor's loss/reordering rules. Port its demonstrated filter behavior, update intervals, clamps, initialization, and convergence states into the existing core. Do not invent smoothing constants.
- Remove `NvstQosManager.obtainFeedback`'s estimate derived from outgoing payload size, its reset-to-zero RTT, and fixed processing scores. Feed measured network and processing observations into the manager; propagate unknown state using verified protocol semantics.
- Maintain each feedback window independently of HUD polling. Consume deltas once per feedback interval; a UI snapshot must not advance adaptation baselines. Use coherent snapshots and vendor-supported aggregation windows rather than whole-session means for live control.
- Compute decode/render capacities from the actual lifecycle observations introduced in Phase 4. Connect packet loss, lossy-frame count, one-way-delay estimates, and both server RTP estimates to their exact serializer fields.
- Wire actual control/transport RTT measurements into correctly labeled diagnostics. Do not substitute half of RTT for vendor one-way delay without evidence of that algorithm.

The vendor trace identifies SCTP association RTT through Bifrost `StatsPacketObserver` → `SctpTransport::getRtd` → `NvstQosManager::updateRttEma`. PixelNOW retains its existing public ICE candidate-pair RTT, a different observation. The user rejected framework patching/rebuilding, and the inaccessible private metric is documented as a parity difference rather than a dependency replacement requirement. Generic WebRTC video policy remains excluded.

**Exit evidence:** each value has an observable source; a 52-byte outgoing packet cannot produce a constant 416 kbps estimate. Repeated HUD reads do not affect feedback. Matched traces demonstrate estimator startup, stable operation, loss bursts, recovery, and legitimate unavailable states.

## Phase 4 — Repair decoder completion and stage measurements

Dependencies: Phase 1; integrate measurements with Phases 2–3.

- Register an identified pending operation before invoking VideoToolbox. Return frame identity, generation, status, and timing with completion; replace FIFO matching and ignored success flags.
- Account exactly once for empty/prepared-invalid samples, synchronous submission errors, asynchronous failures, callbacks without usable output, reconfiguration, and teardown. Retire outstanding operations deterministically; late callbacks must not mutate a newer session.
- Match vendor decode flags and ownership after Phase 0's architecture/codec trace. Preserve hardware decoding and supported pixel formats. Do not force synchronous decompression merely because the inspected x86 path uses it.
- Serialize lifecycle mutation and feedback snapshots without blocking packet receive. Track actual outstanding decoder operations as well as submission-queue depth.
- Capture distinct receive, assembly, queue, decode, render, and presentation observations. Acknowledgment-send duration must never be labeled render time. Use the vendor's frame-number mapping and timestamp arithmetic rather than an unrelated local ACK counter.
- Preserve native decoded-buffer delivery to the renderer and existing relay/recorder callbacks, with explicit pixel-buffer lifetime management. Check affected boundaries without introducing downstream WebRTC encoding/network tuning.

**Exit evidence:** frame-indexed traces match submission, completion, feedback, and presentation under normal playback, decode rejection, format change, and teardown. Outstanding state returns to zero; no success is synthesized. Re-measured decode latency is attributable to the same frame and no longer depends on FIFO displacement.

## Phase 5 — Give vendor adaptation and user settings one owner

Dependencies: accurate feedback from Phases 2–4; Phase 0 adaptation/configuration trace.

- Make the transport the sole owner of bitrate, streaming preference, L4S, and negotiated adaptation state. Remove the UI governor and duplicate mutation paths; the UI submits settings and reads state.
- Remove unverified compounded rules in `NativeNVSTNetworkGovernor`: fixed percentage cuts, resolution-derived floor, evaluation-count recovery, and decode-pressure decisions based on cumulative timing. Retain client-side cap adaptation only if the vendor trace establishes it, with the same state transitions and units in one implementation.
- Honor the user ceiling and synchronize user changes with adaptation state. Track requested, pending, and confirmed settings separately; apply command-success behavior demonstrated by the protocol instead of updating private state before a failed send.
- Audit ANNOUNCE defaults and override precedence, including OWD congestion control, DFC, bitrate initialization, `grc.enable`, encoder/QP settings, and `framePacing.pid.minTargetFrameTimeUs=7936`. Use profile-derived or negotiated values where the vendor does; do not enable the extended allowlist wholesale.
- Update session summaries to report observed cap changes and their reasons. Remove verdicts that conflict with recorded runtime commands.

**Exit evidence:** one ordered command stream reflects the effective session settings; polling frequency cannot compound cuts. A transient disturbance does not leave a hidden client cap permanently reduced unless the verified vendor policy calls for it. Image quality and actual bitrate recover comparably to the vendor under the matched scene, subject to server conditions.

## Phase 6 — Implement vendor-compatible display and DJB behavior

Dependencies: Phases 1 and 4; Phase 0 queue/configuration findings. Feed results into Phase 3.

- Replace latest-buffer-only presentation with the vendor's demonstrated bounded queue and timestamp scheduling behavior. Keep dependency-sensitive dropping out of encoded-frame admission; apply stale decoded-frame decisions at the appropriate vendor stage.
- Trace and wire DJB configuration requests/responses through the active control dispatcher. Apply queue targets, server feedback, vsync, adaptive queueing, and supported VRR behavior to the actual scheduler.
- Give smooth, balanced, and lowest-latency modes verified scheduling differences. Where PixelNOW labels do not correspond to vendor presets, document their mapping to supported vendor settings; do not invent new tuning rules behind the labels.
- Schedule against actual display refresh, react to display/refresh changes, and account for GPU/drawable backpressure. Use the macOS presentation facilities that preserve the traced behavior; inspect their semantics before selecting them.
- Measure render submission, GPU completion, and drawable presentation independently. Populate actual unique displayed-frame rate, repeats, dropped/stale decoded frames, queue residence, and receive-to-present distributions. Preserve supported HDR/color paths and MetalFX behavior through manual visual checks.

**Exit evidence:** timestamped presentation traces show real mode differences with bounded queue residence. Verify 60 Hz and available higher-refresh/variable-refresh displays, including display moves and burst arrivals. Compare frame-interval tails and visible judder with the vendor; buffer acceptance counts must not stand in for displayed frames.

## Phase 7 — Align recovery and investigate remaining latency

Dependencies: identified frame outcomes and actual queue state from Phases 1, 4, and 6.

- Trace the vendor's FEC → NACK → reference repair/keyframe recovery chain and relevant retry/recovery negotiation. Correct proven differences in place; keep receive loss, recovered packets, unrecoverable frames, decoder rejection, and presentation drops distinct.
- Replace resynchronization decisions based only on submission-queue depth with the vendor's demonstrated state machine and complete decoder/render backlog. Verify recovery cadence and cooldown from vendor evidence before replacing the current thresholds.
- Exercise damaged/missing predictive frames, keyframe arrival, reorder bursts, decoder errors, and reconnects manually. Preserve decodable references and prevent repeated recovery requests caused by stale counters.
- Correlate residual freezes with server-reported game FPS, native NVST receive/decode/present timing, control RTT, and the active NVST audio-buffer delay. The existing 39 fps server sample and audio delay reaching 207 ms require separate attribution. Change audio policy only if the vendor NVST path demonstrates a concrete mismatch; do not apply unrelated WebRTC audio tuning or arbitrary buffer reductions.

**Exit evidence:** every visible stall has attributable frame/network/server evidence; recoverable disturbances recover with vendor-comparable behavior. Genuine network loss, server slowdown, or audio buffering remains clearly distinguished from repaired client defects.

## Phase 8 — Historical manual qualification criteria

Build relevant intermediate states with Xcode. Before delivery, build Debug and Release with `xcodebuild build -project PixelNOW.xcodeproj -scheme PixelNOW -configuration <configuration> -destination 'platform=macOS'`; put derived data and diagnostic scratch files in the designated conversation scratch directory. Run applicable existing bundle/manifest validation commands. Do not add or run automated tests, recreate a test suite, or use SwiftPM as a build shortcut.

Record baseline, repaired PixelNOW, and vendor measurements with the same comparison conditions. Use repeated runs and retain settings, server conditions, sample counts, and distributions so improvements are not inferred from one favorable sample.

| Manual scenario | Required evidence |
|---|---|
| Static detail and rapid motion at the diagnosed 1920×1200/60/H.264 profile | Effective cap, actual received bitrate, visible compression/detail, and recovery after a disturbance |
| Stable network, transient loss/reorder, burst arrival, and available constrained bandwidth | Correct estimator/loss fields, single adaptation owner, bounded queues, and vendor-comparable recovery |
| Codec/profile variations actually supported by this client | Correct negotiated formats, hardware decoder use, pixel-buffer ownership, color output, and feedback; include HEVC/AV1/HDR only where supported and available |
| Normal and available high/variable refresh displays | Presented frame intervals, median/p95/p99 queue and receive-to-present delay, repeats/drops, and mode behavior |
| Failed decode, format change, reconnect, stop/start, and failed setting send | Correct terminal outcomes, no identity reuse across generations, no outstanding-resource leak, and coherent settings |
| NVST decoded-buffer consumer boundary, if affected | Native buffer delivery, ownership and timestamps survive lifecycle changes; focused integration regression evidence, not independent co-op/WebRTC transport qualification |
| End-to-end responsiveness | External input-to-photon measurement using the same method for vendor and PixelNOW; report separately from local pipeline delay and RTT |

These were the original runtime acceptance criteria: eliminate proven wire/lifecycle defects, compare quality/pacing/latency against matched vendor runs and measure the original symptoms. The user ended further qualification on October 9 and directed finalization. These criteria were not established as passed; unresolved symptoms remain documented in the final handoff.

## Implementation and publication sequence

Finalization follows the implemented dependency order. Runtime qualification was discontinued by the user; compilation and source integration support publication without a claim that the original symptoms are resolved.

Publication order: GFN frame/time contracts → wire/estimator feedback → receive/recovery → negotiation; then PixelNOW monotonic clock → active-peer transport statistics → coupled lifecycle/decode/presentation integration → settings ownership → documentation. Mutually dependent callback signatures and submodule API consumers stay in one atomic native media integration commit; independent domains remain separate.

Prepare the matching parent integration changes while developing GFN interfaces and build each intermediate combination. Keep the published parent pinned until the required GFN commits are complete, verified, and pushed upstream. Then commit parent changes and the submodule reference in coherent, buildable dependency order. Do not publish a standalone pointer update that breaks its consumers, or preserve obsolete APIs through compatibility shims to manufacture a green build.

Before commits, pushes and completion reports, provide the requirement/status/evidence table and compilation evidence. Publish GFN before updating the parent consumer/pointer. The user's final instruction closes further runtime qualification; it does not establish successful runtime outcomes.

## Historical requirement traceability at the original planning checkpoint

| Requirement | Status | Evidence |
|---|---|---|
| Create a concrete repair plan | Complete | Phases 0–8 specify files, dependency order, changes, and exit evidence |
| Stay close to vendor parity | Complete in plan; implementation pending | Field/configuration ledger, architecture/codec checks, vendor-derived policies, and matched runtime qualification |
| Cover bad quality, stuttering, and high latency | Complete in plan; outcomes pending | Phases 2–5 repair quality feedback/control; Phase 6 repairs pacing; Phases 4, 6–8 measure and qualify latency/recovery |
| Respect repository verification and publication rules | Complete for planning | No streaming code changes, automated tests, commits, or pushes; future Xcode/manual gates and cross-repository commit ordering specified |
