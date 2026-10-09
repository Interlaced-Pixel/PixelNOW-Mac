# NVST vendor parity final handoff

Finalized October 9, 2026. The original objective was to repair poor video quality, stuttering and high latency in PixelNOW's native NVST path using the bundled vendor files. The implementation phases are complete. The user's final instruction ended further runtime qualification and directed finalization. Runtime acceptance was discontinued, not passed; symptom resolution remains unproven.

## Delivered scope

- Carry monotonic arrival, assembly, decode, render and presentation times through frame identity and generation checks, with exactly-once terminal outcomes and explicit ownership/teardown.
- Correct negotiated QoS versions 5–7, processing version 5, frame-statistics versions 4–9 and missing-frame version 3. Remove the duplicate per-frame processing producer; use negotiated feedback cadence and retain failed-write state for retries.
- Estimate bandwidth, server RTP time, loss and processing capacity from native packet/frame histories independently of HUD reads. Bound receive/lifecycle history to 256 slots and delay mature frame statistics by 32 frames.
- Restore one settings owner; distinguish the user's maximum bitrate from initial bitrate and condition high-refresh ANNOUNCE attributes on the negotiated profile. Remove the bespoke network and decode governors.
- Repair FEC readiness, reorder/cursor retirement, frame-header/capture-wrap parsing and persistent reference recovery. Implement native NACK version 2 with the negotiated wait/backoff/retry budget, accepted activation and DJB interaction.
- Bound decoded presentation queues and GPU submissions; route display timing into native pacing and support balanced, smooth and lowest-latency presentation policies. Use actual drawable callbacks for presentation outcomes.
- Keep the existing NVST control/audio dependency's statistics requests associated with the active peer and clear stale state at replacement/close.

Generic WebRTC video/congestion policies and Remote Co-Op networking remain outside scope. The existing recorder/relay decoded-buffer delivery is preserved. The pre-existing edit in `App/RemoteCoOp/RemoteCoOpDirectSignalingSession.swift` is excluded from publication.

Temporary PNG capture, the one-shot capture request handling, retained capture-source buffers and the per-poll evidence sampler were removed. Ordinary native diagnostics and presentation metrics remain. No tests were added or run. No desktop operations or framework patches were used during finalization.

## Requirement traceability

| Requirement | Status | Evidence |
|---|---|---|
| 0: Vendor contract and baseline | Contract complete; matched baseline discontinued | Bifrost/Geronimo traces in the implementation ledger; original comparison criteria retained in the plan |
| 1: Frame identity and clocks | Implemented | Monotonic packet/access-unit metadata, decode-operation registration/generation and terminal frame lifecycle |
| 2: Negotiation and wire | Implemented | Typed negotiated versions, corrected QoS/processing/frame-statistics layouts, native NACK encoding and accepted-write retry state |
| 3: Estimation and feedback | Implemented with documented RTT difference | Packet/RTP estimators, independent feedback history, negotiated windows/cadence and actual capacity observations |
| 4: Decoder lifecycle | Implemented | Registered frame operations, explicit failure/missing-output handling, generation checks and teardown ownership |
| 5: Settings ownership | Implemented | Removed duplicate governors; initial/maximum bitrate separation and conditional ANNOUNCE |
| 6: Presentation and DJB | Implemented | Bounded queues, two GPU tickets, drawable presentation callbacks and vendor-based scheduling/modes |
| 7: Recovery and latency attribution | Implemented with documented platform differences | FEC/reorder retirement, bounded NACK, persistent invalidation retries and traced native audio route |
| 8: Qualification | Discontinued by user | Final instruction: "Let's move on. Finalize this." No physical-latency or symptom-resolution claim |
| Finalization/publication | Implementation finalized | GFN primitives → feedback → receive/recovery → negotiation; parent clock → dependency → native media integration → settings → documentation |

## Parity limits and unresolved observations

The vendor reads its private SCTP socket round-trip metric; PixelNOW retains the existing public ICE candidate-pair RTT. These are different measurements. Framework patching/rebuilding was rejected and is excluded. No private ABI substitute is installed.

Swift performs FEC before its waiting queue; the vendor feeds FEC after its source queue. PixelNOW uses one serialized receive queue for inactivity observations where the vendor uses separate source/transport workers. These differences remain documented, rather than described as identical vendor behavior.

The final live evidence snapshot showed continuing presentation gaps, a roughly 30 FPS median presentation sample rate in capture-free windows, and a 444.4 ms predecode queue peak despite near-60 FPS assembly/decode in selected windows. It did not establish a root cause or prove final image quality during moving gameplay. Physical input-to-photon latency and high-refresh/VRR operation were not measured. Further qualification is closed for this task at the user's direction.

Historical evidence is archived under `/Users/jayian/Library/Application Support/Codex/brain/01a11cb7-117b-78f2-93e6-74fe11c36053/scratch/live-nvst-20261009-125747/`. Do not use the removed capture controls as instructions for the finalized app.

## Compilation and publication discipline

The cleanup tree compiled with Xcode Debug successfully, without compiler warnings/errors: `scratch/nvst-finalization-debug.log`. The ordered GFN source snapshots compiled in Xcode with the existing production media timestamp dependency; parent clock, dependency, media and settings snapshots compiled using the production Xcode project. Their logs are in `scratch/nvst-finalization/`. Earlier Debug/Release builds and vendor traces are recorded in the implementation ledger. Compilation establishes source integration, not runtime symptom resolution.

GFN commits `79bd152`, `fc35597`, `08e38d5` and `41fe081` are published to its existing `main` upstream. Parent commits isolate the clock, dependency statistics, native media integration, settings ownership and final documentation on the existing `main` upstream. Interdependent lifecycle/decode/renderer callback changes form one atomic native media integration unit. Independent feedback, recovery, negotiation, settings and dependency-statistics changes are isolated. No build artifacts or user co-op edits are included.

Full historical phase plan: [NVST_VENDOR_PARITY_REPAIR_PLAN.md](/Users/jayian/Projects/PixelNOW/NVST_VENDOR_PARITY_REPAIR_PLAN.md). Vendor trace ledger: [NVST_VENDOR_PARITY_IMPLEMENTATION.md](/Users/jayian/Projects/PixelNOW/NVST_VENDOR_PARITY_IMPLEMENTATION.md).
