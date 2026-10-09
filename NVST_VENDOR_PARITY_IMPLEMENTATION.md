# NVST vendor parity implementation ledger

Finalized October 9, 2026. The native NVST implementation is complete; the user explicitly ended further runtime qualification and requested publication. No claim of resolved visible stutter, image-quality equivalence, or measured input-to-photon latency is made. Temporary image capture and its polling sampler were removed. This ledger retains historical vendor traces and evidence limits; [the final handoff](/Users/jayian/Projects/PixelNOW/NVST_VENDOR_PARITY_HANDOFF.md) records the final scope and status.

Bundled vendor reference: Bifrost/Geronimo 2.0.88.129, x86-64 assembly and ARM64 binaries. Installed official client: 2.0.89.141. The original official observation used 2560×1600/60; the PixelNOW failure session used 1920×1200/60/H.264. The later official session matched that video profile but provided no usable moving-scene comparison.

## Scope audit: native NVST

Finalization authorization: finish the implemented native NVST repair and end further runtime qualification. No desktop access or framework patching. Historical observations and equipment limits below do not reopen qualification as a publication gate.

The remaining plan repairs the native Mjolnir receive/FEC/reassembly → VideoToolbox decode → Metal presentation path and NVST RTSP negotiation, server-control feedback and adaptation. Generic WebRTC video congestion control, jitter buffers, signaling, rendering and peer-networking changes are excluded. Each future WebRTC-related edit requires a recorded native NVST call path and bundled vendor evidence showing why it is required for parity. See the scope table in `NVST_VENDOR_PARITY_REPAIR_PLAN.md`.

The existing `NvstWebRtcBundle` is a narrow transport dependency for NVST control/input/feedback and audio. Current native NACK, QoS and processing producers call its partially reliable control writer (`NVSTCoreVideo.swift:66`, `:407`, `:417`; writer at `NvstWebRtcBundleSetup.swift:621`). Bifrost `ClientSession::SetupDataChannel` obtains the SCTP transporter at `libBifrost2.dylib.s:260146`; its native channel labels are present at 196985/197029/197076. Those traces justify native command routing and delivery semantics, not importing generic WebRTC video policies into NVST recovery or pacing.

`NVSTCoreVideo.swift:25` sends decoded VideoToolbox buffers to `WebRTCStreamRecorder.appendNativePixelBuffer`; line 26 forwards them to the existing relay. Only affected native-buffer ownership, timestamp and delivery checks remain in scope. Independent recorder, co-op encoding, signaling and WebRTC transport improvements are excluded from the parity completion gates. The pre-existing user co-op signaling edits remain untouched. Audio-buffer investigation must follow the actual NVST session route and vendor NVST producer; generic audio tuning is excluded.

## Wire contract

All fields below use little endian. QoS, processing and frame-statistics commands use the existing partially reliable control channel. Verify decrypted live payloads and channel/cadence selection before publication.

### 0x0207, QoS v5/v6, 80 bytes

The implementation now supports v5/v6 as well as v7. Version/stream/sequence occupy 0/4/8; reserved words occupy 12 and 44. Frame index and minimum-offset server RTP time occupy 16/20. Excess OWD, jitter and interval loss occupy 24/28/30. Total receive bytes is u64 at 32; receiver drops u32 at 40. Fast bandwidth is at 48, utilization u8 at 52, decode/render capacities u16 at 54/56, smoothed decoder queue delay u16 milliseconds at 58, RTT u16 milliseconds at 60, client 90 kHz time at 64, lossy frames at 68, slow bandwidth at 72. V6 includes median-offset server RTP time at 76; v5 keeps this word zero. Padding is zero.

The version-specific writes are traced in `handleQosFeedbackV5Base`/`handleQosFeedbackV6Base`; live samples are still required.

### 0x0207, QoS v7, 52 bytes

Periodic feedback defaults to 50 ms and follows negotiated `x-nv-vqos[0].bw.statsTime` (unindexed fallback supported). Bifrost constructor vector at binary `0xd95890` stores 50 in the VQoS field at offset `0x30`; the configuration handler at 613519 and logger at 716215 establish the key. `NvscClientPipeline::periodicFeedbackCollection:321497–321635` schedules this interval. The installed official log reports `vqos[0].bw.statsTime: 50` at 1769. PixelNOW's former fixed 18 Hz sender was incorrect. A zero interval disables QoS emission while retaining 50 ms receive/recovery/processing maintenance; processing's own timeout remains distinct.

The final producer trace corrects the earlier description of RTT parity. `NvstQosManager::updateRttEma:253279` reads the u16 at observer offset `0x1c`. `StatsPacketObserver` writes that field from `SctpTransport::getRtd` at 1169633–1169635; `getRtd:1153362–1153392` obtains the SCTP socket's metrics, with zero when unavailable. PixelNOW instead reads ICE candidate-pair `currentRoundTripTime`/`roundTripTime` through its existing public interface. Equal units do not make these equivalent producers. NVST QoS/NACK retain this existing measured value; exact RTT-producer parity is not established. RTSP request RTT, UDP STUN RTT and server latency estimates must remain distinct observations. The user rejected framework patching/rebuilding, and the proposal has been removed. Continue the native NVST video repair within current public interfaces; qualify the measurement difference against real retransmission timing rather than making inaccessible private telemetry a framework-replacement prerequisite.

| Offset | Width | Producer and meaning |
|---|---|---|
| 0 | 4 | Selected QoS version, 7 |
| 4 | 1 + 3 reserved | Stream index; zero padding |
| 8 | 4 | Feedback sequence |
| 12 | 4 | Last estimator frame index |
| 16 | 4 | Estimated server RTP time, minimum arrival/transmit offset, 90 kHz, 31-bit wrap |
| 20 | 4 | Excess one-way delay, microseconds |
| 24 | 2 | Packet-arrival jitter sampled at frame boundary, microseconds |
| 26 | 2 | Interval source-packet loss scaled by 10,000 |
| 28 | 1 + 1 reserved | Filtered bandwidth utilization percent; zero padding |
| 30 | 2 | Decode processing capacity, frames/s |
| 32 | 2 + 2 reserved | Render processing capacity, frames/s; zero padding |
| 36 | 4 | Client monotonic session time, 90 kHz |
| 40 | 4 | Lossy-frame count, expected source plus parity versus original packets; skipped frames included |
| 44 | 4 | Slow bandwidth estimator, kbps |
| 48 | 4 | Estimated server RTP time from feedback-window upper median arrival/transmit offset |

Reference: `Docs/vendor/libBifrost2.dylib.s:250420` (`handleQosFeedbackV7Base`). Decode/render capacities use 1,000 divided by smoothed milliseconds; the vendor uses 1,000 when duration is unavailable. The processing measurement filter factor is 4 in the observed profile.

### 0x0203, processing v5, 28 bytes

| Offset | Width | Producer and meaning |
|---|---|---|
| 0 | 4 | Selected processing version, 5 |
| 4 | 4 | Stream index |
| 8 | 4 | Frame-index difference since last successful report |
| 12 | 4 | First frame index in report window |
| 16 | 4 | Target queue/render time in microseconds |
| 20 | 4 | Smoothed render admission to presentation duration, microseconds |
| 24 | 4 | Actual display vsync interval, microseconds, updated from active display link |

Reference: `populateClientProcessingTimesFeedback:250687`, `getFramePacingStats:250812`, `getFramePacingFeedbackTimings:243967`. No per-frame v1 sender remains. The v1 helper now uses the verified 16-byte header and 24-byte record (frame u32, padding u32, duration u64, zero u64), but it is not selected by the active vendor negotiation policy.

The vendor constructor defaults are a 100 ms feedback timeout; jitter history n=3,600, render history n=60, processing history n=120; exponential alpha=2/(n+1). Absolute quantile probability .997 and convergence .002; jitter clipped to ±75 ms, advance clamped to 8–40 ms; render minimum and maximum both 8 ms; processing observations capped at 75 ms. The defaults were resolved from the constructor constant vectors and field reads in `updateFramePacingStats:252891` and `getFramePacingStats:250812`. The previous 100 ms processing cap was incorrect and is now repaired. `NvstFramePacingConfiguration` carries negotiated profile history, estimation mode, standard-deviation multiplier, quantile, clipping, bounds and feedback timeout values into QoS. Pinned DJB minimum raises the reported advance up to the profile maximum. The decoded holder consumes the negotiated maximum queued frames, default seven. These Bifrost feedback histories are distinct from Geronimo's client scheduling histories.

Optional quantile windows are implemented from `ExpMovingAverage:241883–242030`: absolute-value circular history, initially zero-filled, recomputed at the configured pre-increment write step, selecting the rank `max(1, floor(size * (1 - probability)))` from largest to smallest. The window branch returns independently of the ordinary EMA/stddev branch. Window size/step default to zero (`ClientStatsTool` configuration at 248708 and binary vector following `0xd959c0`), so the usual profile retains the existing EMA quantile algorithm.

Geronimo adaptive scheduling subtracts `max(maximumGPU, min(lowerGPUQuantile, schedulingTime))` from minimum residence (`244013–244030`). `setGPUSchedulingTime:244377` stores the scheduling baseline, initialized to zero by the constructor. The current official Mac session logs `schedule time 0us` at `geronimo.log:3398`; with a nonnegative GPU quantile this reduces to maximum GPU duration, matching PixelNOW's current baseline. Other platforms with a nonzero scheduling baseline remain outside this runtime observation.

### 0x0204, frame statistics v9, 102 bytes

| Offset | Width | Meaning |
|---|---|---|
| 0, 2 | 2 each | Blob type 1, selected version |
| 4, 8, 10 | 4, 2, 2 | Frame index, stream index, lost packets |
| 12 | 8 | First packet receive time in monotonic session milliseconds |
| 20, 24 | 4 each | Decoder admission, decode start |
| 28, 32 | 4 each | Render admission, render start |
| 36, 40, 44 | 4 each | Render completion, presentation completion, confirmed presentation |
| 48 | 4 | GPU duration in milliseconds |
| 52, 56, 60 | 4 each | RTP queue duration, FEC duration, frame receive duration |
| 64, 68 | 4 each | One-way delay, transmit gaps |
| 72, 76, 80, 84 | 4 each | Frame bytes, RSSI, link speed, status flags |
| 88 | 2 | NACK-recovered packet count |
| 90, 94, 98 | 4 each | RTP inactivity, predecode completion, transport inactivity |

Stage fields are relative to first packet receive and use -1 for unavailable decode/render stages. Vendor `logCurrentFrameData:241275` and stage writers establish the layout; field 94 is predecode completion, not confirmed presentation. Version-aware serialization lengths are 72/84/90/94/98/102 for versions 4/5/6/7/8/9. V4 has the common prefix through presentation completion, followed by RTP queue at 44, FEC at 48, receive span at 52, bytes at 56, RSSI/link at 60/64 and flags at 68. V5 adds OWD at 72, transmit gaps at 76 and confirmed presentation at 80. Absence uses vendor defaults (QoS 5, processing disabled, blob 3); blob versions below 4 do not emit the newer frame-statistics command.

`NvstFrameReceiveStatistics` now carries original receive min/max, source-plus-parity loss, NACK count, maximum arrival-to-reorder-release duration, measured FEC duration, excess OWD, transmit gaps, and verified FEC/out-of-order flags. RTP payload type 106 identifies retransmissions; they and FEC reconstruction are excluded from bandwidth estimation. Reconstructed packets cannot fill the QoS original source-packet loss window. Vendor evidence: `RtpSourceQueue::readPacket:588902`, `NvstStreamProcessor::processBuffer:219784`, `ClientStatsTool::addPacketData:238610`, `logCurrentFrameData:241523`.

The vendor constructor explicitly initializes RSSI and network speed to zero (`ClientStatsTool` at 237536); setters at 243949/243953 replace those values with observations. `ClientLibraryWrapper` forwards Wi-Fi signal strength and speed, converting speed to kbps. PixelNOW now supplies RSSI and transmit-link kbps from the routed, powered Wi-Fi interface; other routes retain zero.

RTP inactivity is the maximum interval between completed source-worker polls, including dequeue timeouts, consumed by the next successfully parsed packet (`pollForDataAndUpdate:588611`, packet transfer/clear at 588727). Transport inactivity measures completed socket receive attempts, including unsuccessful reads (`WebRtcTransport::receiveFrom:443688`); `handleMjolnirRtp:445464` transfers and clears its maximum into the native Mjolnir packet. `ClientStatsTool::addPacketData:238795` takes per-frame maxima. General defaults at 708356/708363 enable both measurements and set an 8 ms dequeue timeout. The installed official log confirms all three at `geronimo.log:1448–1452`. PixelNOW now measures its own native UDP attempts and authenticated RTP processing polls, including a negotiated idle timeout. Both stages share a serialized Dispatch receive queue on this platform; the vendor uses separate transport and source workers. These are scheduling measurements, not gaps between successful media arrivals. Disabled measurements retain zero. Runtime payload verification remains open.

For a completely missing frame, the negotiated statistics version must still be at least four. `logCurrentFrameData:241275` detects zero original and retransmitted receive counts and changes that individual blob to version three. `getVersionAwareSerializedBlob:242957`, case at address `0xed71b`, copies exactly 12 bytes: type u16 at 0, version 3 u16 at 2, stream u16 at 4, zero reserved u16 at 6, frame u32 at 8. Observed partial frames use the negotiated full layout and packet-loss status bit 4; they must not be mislabeled as completely missing. Serialization and the bounded 256-slot, 32-frame-delayed history producer are implemented. Live samples remain a qualification gate.

Failed frame-statistics writes now retain the head report for retry rather than discarding its mature lifecycle snapshot. `obtainFrameDecodedDataStats:242681–242810` removes one vendor blob, serializes it into command `0x0204`, and restores it at the front of a 256-entry queue when `CommandPacketWrite` fails; its log distinguishes retry from a full-queue drop. PixelNOW retains up to 256 reports in order, flushes on submission and periodic NVST feedback maintenance, counts rejected writes/full-queue drops, and clears the queue on stop. The local acceptance boundary is the existing control-channel writer, not a server acknowledgement. Each report remains an individual versioned command payload; no unsupported batching header was added. Runtime failed-write recovery remains unverified.

Correction: the vendor bandwidth estimator reserves initial one-way-delay capacity during setup around 218964, but the full-vector branch at `0xd71ef` jumps to `0xd7306`, which reallocates and grows the vector. It does not skip new samples when full. A finite failed-write policy must be identified separately and cannot be claimed as this vendor behavior.

### Recovery commands 0x0317 and 0x020b

The active receiver now emits version-2 `0x0317` control requests instead of generic RTCP NACK. A three-byte header contains version 2, stream u8 and record count u8. Each ten-byte record contains base RTP sequence u16 and u64 mask for the next 64 sequence numbers. A batch includes at most 64 missing sequence numbers. Counters advance only after the control writer accepts the request. `0x020b` is a 12-byte NACK toggle (version u16, stream u16, frame u32, enabled u8, three zero padding bytes). It was incorrectly called input enable; the unrelated input setup toggles have been removed.

Vendor evidence: `ServerControl::sendRtpNackRequest:312730`, `NvscClientPipeline::createAndSendNackRequest:321316`, `RtpSourceQueueExtV2::createNackRequest:593904`, NACK toggle writes at 321701. Missing sequences now remain pending until arrival, processing, or retry exhaustion. The selected ANNOUNCE configuration supplies initial wait, backoff, request limit, and packet-count bound; defaults trace to Bifrost's video configuration constructor at 708850 (1 ms initial wait, 4 ms backoff, three requests). Eligible retries wait control RTT plus backoff. The request limit is bounded by floor(wait budget / RTT), at least one request, as traced at 601918. Failed writes do not advance timestamps, attempts, or counters. The receiver polls pending requests at 1 ms; this is an implementation polling cadence, not a claim about vendor scheduling precision.

NACK activation now uses the traced static/DJB budget, hysteresis and recent RTT maximum policy (`isRtpNackFeasible:253305`), updates state only after an accepted toggle, and refreshes every 3,600 frames. Default static budget is 52 ms, hysteresis 250 us, recent RTT history five observations. Conditional NACK-to-DJB requests now route through the local presentation queue and acknowledge the applied configuration to QoS. The vendor interaction modes 1/2 and DJB modes 1/2 gate requests; minimum changes by 5 ms toward ceil(RTT EMA), bounded by current maximum. Disable unpins and restores the user's base presentation configuration. The debounce constant is 1,000 ms, resolved from Bifrost x86-64 binary constant address 0xd7e07c. Mode zero means unchanged in this local SDK request; no network opcode has been fabricated. Live failure/recovery qualification remains open.

FEC now attempts repair immediately when source plus parity shards suffice; the former four-clean-group arming and re-encode verification gate is removed. Vendor evidence: `FecDecode::addAndProcessPacket:211450`, ready test at 211625 and decode at 211840. Completed groups release shard payloads. The arbitrary 16-group retention has been replaced by receive-cursor retirement in the offline continuation; Swift's pre-reorder placement still differs from vendor FEC after its native source queue and remains under review.

The stopping-point receiver replaces RTT-derived packet-distance abandonment with typed, negotiated queue bounds. Vendor `RtpSourceQueue::enforceWaitingQueueLimits:590086`, `flipConfig:590613` and receiver initialization at 213080 establish packet-count and elapsed-time limits. Defaults are 1,024 packets, 8 ms waiting duration and 68 ms frame wait; active NACK substitutes its queue count and 52 ms default duration. Accepted NACK toggles switch the active receiver policy. Waiting packets are polled even when NACK is off, so expiry does not require another datagram. Known parity-only sequence holes can release without resetting the predictive reference chain. This code compiles but has not been live-qualified; FEC group optimization, expiry/recovery outcomes and timer teardown still require manual review and runtime evidence.

## Historical pre-finalization checkpoint

The table below records the earlier qualification checkpoint. Its open runtime scenarios are historical; the user subsequently ended qualification and directed finalization. Current status is in the final handoff.

| Phase | Status | Evidence and remaining work |
|---|---|---|
| 0 Contract and baseline | Contract traced; implementation/comparison open | Version/layout, cadence, inactivity, quantile, GPU and ARM traces; SCTP RTT producer mismatch identified; no matched moving-scene baseline |
| 1 Identity and clocks | Implemented; source reviewed | Monotonic frame/operation timestamps, registered identity/generation, capture wrap and receive/recovery classification; runtime wrap/restart remains open |
| 2 Negotiation and serialization | Implemented; source reviewed | QoS 5–7, blobs 4–9/missing 3, sole processing producer, negotiated cadence/inactivity, delayed history, link fields and failed-ACK retry; live payload/failure samples open |
| 3 Estimation and state | Implemented with recorded RTT difference; qualification open | Estimators/windows/histories and public-interface sampling implemented; convergence and retransmission timing evidence remain open; framework changes excluded |
| 4 Decode lifecycle | Implemented; source reviewed | Registered operation completion, status/generation, vendor synchronous flags and actual stages; source ownership at native recorder/relay checked; format/failure/reconnect/teardown runtime evidence open |
| 5 Settings ownership | Implemented; source reviewed | Sole owner, ceiling/initial distinction, removed unsupported overrides and conditional high-refresh profile; failed/accepted settings and image-quality recovery unverified |
| 6 Presentation and DJB | Implemented; source reviewed | Bounded queues/GPU, postdecode timing, adaptive/VRR/server-paced policies and local DJB; GPU baseline resolved for observed Mac scheduling time zero; playback unqualified |
| 7 Recovery and residual latency | Implemented with recorded platform differences | FEC group/release review, timed NACK/reference repair and actual NVST audio route; pre-reorder FEC and shared inactivity queue require runtime qualification |
| 8 Qualification | Blocked | Debug/Release and native bundles pass. Desktop access cannot be used; no matched headless capture exists. High-refresh/VRR and physical measurement equipment unavailable. Nothing shipped |

## Remaining qualification gates

1. Qualify negotiation, initial wait, retries, elapsed expiry, failed-send retention and dynamic NACK-to-DJB behavior using existing public interfaces. Correlate measured transport RTT with accepted NACK-to-recovery timing and preserve the documented difference from the vendor's private SCTP measurement. Do not patch/rebuild frameworks or claim exact producer parity.
2. Qualify adaptive presentation and separate capture/arrival/jitter/GPU producers. The observed Mac GPU scheduling baseline is resolved; nonzero scheduling time on other platforms is unqualified. High-refresh/VRR cannot be measured on the available fixed 60 Hz display.
3. Qualify command 0x0200 dynamic-FRL decoded admission and its vendor capture-span/frame-count bounds. Geronimo decodes before pushRenderer; do not apply this decoded predicate to encoded predictive frames. Trace any encoded backlog policy independently.
4. Qualify FEC retirement, late retransmissions, partial/multiblock frames, malformed short parity and incomplete feedback. Source review confirms bounded cursor-based group release and recovered-packet insertion before expiry. Pre-reorder FEC remains a recorded platform difference requiring loss/reorder evidence.
5. Qualify the conditional ANNOUNCE/DFC/GRC profile, mature full/missing reports, optional inactivity/quantile modes and 256-entry failed-ACK retention. Inspect narrowly scoped decrypted control payloads under actual terminal outcomes and confirm zero outstanding state after failure/reconnect/stop.
6. Qualify the original symptoms with repeated matched moving-scene runs and physical input-to-photon measurements. Use an authorized evidence path that does not rely on desktop automation. Existing runs, including the stalled official shader session, cannot prove repaired quality or latency.

The existing user changes to `App/RemoteCoOp/RemoteCoOpDirectSignalingSession.swift` are preserved and outside this repair. No automated tests are added or run. Derived data and diagnostic captures are held in the conversation scratch directory.

## Manual runtime observations

The pre-recovery-update run used the Xcode-launched Debug app built at 20:51 UTC, H.264 hardware decoding, 8-bit 4:2:0, HDR/MetalFX off, Balanced presentation, 50 Mbps ceiling and the captured baseline initial bitrate. It ran from 20:53 to 21:06 UTC. Startup shader compilation, initial background windows and concurrent builds make the early samples unsuitable for comparison. Later animated-lobby windows reached 55–58 unique presented frames/s and also fell into the 40s; server game FPS varied as well. At 15:57:56 local time, rolling samples reported receive-to-presentation p50/p95/p99 = 63.81/82.42/99.66 ms and render-queue p50/p95/p99 = 22.91/39.97/48.80 ms. These are pipeline observations, not input-to-photon measurements or proof of a fix.

The existing run's HUD reported cumulative loss and poor network health. It did not qualify the newer timed NACK changes. The later user match ended naturally. A subsequent official qualification session negotiated the intended 1920×1200/60/H.264 profile but stalled at 13% shader preload, with concurrent build load, connection disturbances and audio underruns. These readings are excluded from motion comparison. Current constraints and the actual latest pre-change official settings to restore are recorded in the handoff; earlier Balanced/2560×1600 notes are superseded. No desktop automation may be used to resume or restore the session under current instructions.

## Final source/build checkpoint

The current tree, including negotiated cadence/inactivity, optional quantile modes and failed frame-statistics retry, passes Debug (`final-nvst-debug.log:166`) and Release (`final-nvst-release.log:107`) without warning/error matches. Existing native bundle validation passes for both configurations. Parent/GFN whitespace checks pass. No automated tests were added or run; no repair commits or pushes were made.

Native decoded-buffer boundary source review confirms recorder retention before asynchronous append (`WebRTCStreamRecording.swift:503`) and relay ownership via `RTCCVPixelBuffer`, with decoder-provided `CMTime` (`RemoteCoOpHostVideoRelay.swift:37`). Runtime consumer behavior is unqualified. Actual NVST audio travels through the bundle's audio tracks and `PixelNOWCoreAudioRTCDevice` (`NvstWebRtcBundleSetup.swift:455–465`); Bifrost explicitly instantiates `WebRtcAudioRtpReceiver` around 448935/462281. Existing audio jitter/device delay metrics remain separate from video and physical responsiveness. No generic WebRTC audio/video policy was changed.

The unrelated co-op manifest-validator modification was removed from the repair. Its existing requirement for a `discovery` key differs from the current co-op configuration and is outside the NVST parity task. At that checkpoint, the original symptoms and runtime parity were unresolved. The user subsequently ended further qualification and directed finalization; successful builds alone still do not prove symptom resolution.

## Offline recovery continuation

At the offline checkpoint, Debug and Release builds passed without warning/error matches (`offline-verified-debug.log:135`, `offline-verified-release.log:100` in scratch). Both bundles, manifest and whitespace checks passed. The network restriction prevented stream qualification at that time. These historical builds do not verify the subsequent live-resume changes. No commits or pushes.

`NvstFecRecovery` now retains each group through its exclusive extended RTP end index, checks that all shards identify the same interval and retires it once the receive cursor passes that interval. A stale arrival is cleaned up even when no new reorder release occurs. Session reset clears remaining groups. This removes the unsupported 16-group threshold without claiming that Swift's pre-reorder FEC placement is identical to the vendor's post-queue path. Vendor `FecDecode::addAndProcessPacket:211450` clears shard state when the ordered frame/group changes.

Packet releases and loss decisions now form one ordered sequence. All reconstructed packets from the same arrival enter reorder before expiry can advance the cursor. Reassembly processes already released packets before applying a subsequent loss reset. `discardIncompleteFrame` abandons only assembly state and preserves the capture timestamp wrap history; session reset clears both. Polling expiry updates abandoned-frame counters. These changes avoid resetting an earlier partial access unit before its final queued packets are consumed.

`NVSTWireReceiver.stop` serializes timer/source cancellation and recovery cleanup on the receive queue, with a queue identity check for reentrant callers. Queued NACK toggles, timer scheduling, draining and callback dispatch require an active read source. Stop invalidates the send descriptor under its lock. The source cancellation handler captures its own descriptor and closes it without depending on a live receiver object, fixing the weak-owner closure's potential descriptor leak and preventing an old source from closing a newer socket. These lifecycle changes require stop/reconnect runtime qualification when the network restriction is lifted.
