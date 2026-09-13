# NVST/NVSC Parity Completion Report

## Handoff state

The interrupted parity audit had already generated the missing NVST/NVSC model families and migrated callers away from the deleted `NvstControlCommand` and `NvstGamepadPacket` definitions. The remaining work was runtime behavior: command transport, QoS state, stream processing, network adaptation, and renderer hooks.

## Completed model coverage

The generated model families now provide typed Swift representations with usable defaults and fields in:

- `GFN/NVST/Core/NVSCConfigTypes.swift`
- `GFN/NVST/Core/NVSTAudioTypes.swift`
- `GFN/NVST/Core/NVSTClientTypes.swift`
- `GFN/NVST/Core/NVSTInputTypes.swift`
- `GFN/NVST/Core/NVSTNetworkingTypes.swift`
- `GFN/NVST/Core/NVSTVideoTypes.swift`
- `GFN/NVST/Core/NVSCQoSTypes.swift`

These are safe Swift domain models. They are not claimed to be direct in-memory vendor ABI layouts where the vendor assembly does not expose a complete field map.

## Completed runtime wiring

- `NvstStreamingCommand` is the single control-command representation, and all NVST callers use it.
- `NvstQosManager` now tracks feedback, packet timing, ECN/L4S state, DJB configuration, and cursor-control commands behind a lock.
- `NvstStreamProcessor` now processes received packets, tracks frame state, estimates bandwidth, handles concealment and release callbacks, and emits end-of-stream notifications.
- `NVSTCoreVideo` creates and wires the QoS manager and stream processor into `NVSTWireReceiver` and the negotiated control channel.
- `NativeNVSTNetworkGovernor` now evaluates loss, jitter, frame-rate collapse, and bandwidth headroom to produce bounded bitrate, streaming-mode, and L4S adjustments.
- `NVSTCoreVideoRenderer` now writes frame snapshots, services snapshot requests, and applies presentation-mode behavior.
- `NvstRemoteInput.mouseSettings` now serializes the event instead of returning an empty payload.
- Raw-pointer media models use explicit unchecked sendability where ownership is managed by the surrounding pipeline.

## Residual empty returns

Remaining empty collections and zero values are guarded parse/error fallbacks or protocol-default behavior. No `Stubbed properties for parity with ASM` placeholders remain in the NVST/NVSC implementation, and no runtime method in the completed parity path is an unconditional no-op.

## Verification

The Debug macOS target was rebuilt with signing disabled using the repository's temporary derived-data location. The build completed successfully. The project still reports pre-existing warnings in unrelated capture, UI, and compatibility code; no tests were run because this repository's instructions prohibit test execution unless explicitly requested.
