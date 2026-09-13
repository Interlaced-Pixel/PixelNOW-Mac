#!/usr/bin/env python3
"""
Extract NVST/NVSC struct layouts from vendor binary assembly dumps and symbol tables.

Strategy:
1. Parse `nm` output + demangled symbols from dylibs to find all methods per type.
2. Scan `.s` assembly files for:
   - `operator new(N)` calls to determine struct size.
   - Load/store offsets to infer field positions.
   - setClientConfigDefaults / getDefault* functions which are the richest source.
3. Output: JSON of {TypeName: {size, fields: [{name, type, offset}], methods: [...]}}

Usage:
    python3 scripts/extract_struct_layouts.py > Docs/struct_layouts.json
"""

import subprocess
import re
import json
import os
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).parent.parent
ASM_DIR = ROOT / "Docs" / "vendor"
DYLIB_DIR = ROOT / "Docs" / "vendor" / "MacOS"
OUT_PATH = ROOT / "Docs" / "struct_layouts.json"

NVST_TYPES = [
    # Audio
    "NvstAudioFormat", "NvstAudioFrame", "NvstAudioStreamConfig",
    "NvstClientAudioBufferConfig", "NvstClientAudioStats", "NvstDynamicStreamingMode",
    "NvstMicStreamConfig",
    # Video
    "NvstCscMode", "NvstSurfaceFormat", "NvstUpdateVideoStats", "NvstVideoContentType",
    "NvstVideoContextSettings", "NvstVideoDecodeUnit", "NvstVideoDecoderState",
    "NvstVideoDecoder", "NvstVideoFormatPreference", "NvstVideoFormat",
    "NvstVideoFrameState", "NvstVideoFrameType", "NvstVideoFrameWindowMetadata",
    "NvstVideoModifiers", "NvstVideoStreamConfig",
    # Input
    "NvstBulkPayloadInputEvent", "NvstClientRuntimeEncryptionKey", "NvstClientRuntimeParam",
    "NvstGamepadControls", "NvstGamepadStateEvent", "NvstHidChangeEvent",
    "NvstHidDeviceId", "NvstHidReportEvent", "NvstHidReportType", "NvstImeHotKey",
    "NvstInputEventType", "NvstInputEvent", "NvstKeyCode", "NvstKeyState",
    "NvstLockKeyState", "NvstMouseEventGroup", "NvstMouseEvent", "NvstMouseSettingsEvent",
    "NvstMultipleHidEvents", "NvstSystemCursor", "NvstTouchEvent", "NvstTouchLowLevelEvent",
    # Client/Connection
    "NvstClientCallbacks", "NvstClientDJBConfig", "NvstClientDJBMode",
    "NvstClientDiagnosticParam", "NvstClientEvent", "NvstClientGetStats",
    "NvstClientStreamId", "NvstClientUpdateStats", "NvstClient", "NvstConnectionConfig",
    "NvstConnectionEventType", "NvstConnectionInfo", "NvstConnectionSubType",
    "NvstConnectionType", "NvstEndpointConfig", "NvstEndpoint", "NvstMessageForClient",
    "NvstServerEndpoint", "NvstCaptureMethod", "NvstCertificateValidationMethod",
    "NvstDataChannelCallbacks", "NvstDataChannelEvent", "NvstEventDetail",
    "NvstIpVersion", "NvstL4sStateType", "NvstLogLevel", "NvstLoggerConfig",
    "NvstMediaType", "NvstMessageForServer", "NvstMessage", "NvstPiiMode",
    "NvstPrefilterParams", "NvstServerConfig", "NvstSignalingHeader", "NvstSleepMethod",
    "NvstStatusChange", "NvstTrueHdrParams", "NvstWaitMethod", "NvstWindowEvent",
    # Networking
    "NvstMultiStreamBitrateControl", "NvstNatServer", "NvstNetworkInfo",
    "NvstServerNetwork", "NvstStreamCallbacks", "NvstStreamConfig", "NvstStreamData",
    "NvstStreamEvent", "NvstStreamServerBackendMode", "NvstStreamingCommand",
    "NvstTransportPolicy",
]

NVSC_TYPES = [
    "NvscAudioSettings", "NvscVideoSettings", "NvscAudioSsrcConfig",
    "NvscMicSsrcConfig", "NvscVideoSsrcConfig", "NvscMicAudioSettings",
    "NvscAudioBitrateSettings", "NvscAudioQosSettings", "NvscVideoQosSettings",
    "NvscRuntimeSettings", "NvscClientConfig", "NvscClientPerfBrControl",
    "NvscClientPorts", "NvscServerEndpoint", "NvscPortUsage", "NvscTransferProtocol",
    "NvscBWEstimator", "NvscCodecLevel", "NvscCpmRtcFeature",
    "NvscEncoderLtrFeatureSetting", "NvscEncoderMultiPass",
    "NvscEncoderMultiRefFeatureSetting", "NvscEncoderPreset", "NvscEncoderSettings",
    "NvscEncoderUtilizationBoosterFeatureSetting", "NvscEncoderUtilizationBoosterMode",
    "NvscFeatureFlags", "NvscFramePacingFeedbackMode",
    "NvscFramePacingJitterEstimationMode", "NvscFramePacingMode",
    "NvscFramePacingRenderEstimationMode", "NvscGeneralSettings", "NvscH264Level",
    "NvscOverrideAvgBitrateThresholdPercent", "NvscOverrideAvgQpThresholdPercent",
    "NvscPacketLossConcealmentSetting", "NvscPacketPacingMode", "NvscPacketPacing",
    "NvscPerfHistoryFeature", "NvscPrefilterModel", "NvscQecConcealGapsAtRefreshPoint",
    "NvscQecFeatureSetting", "NvscQecSettings", "NvscQpgFeatureSetting",
    "NvscRateControlMode", "NvscRelaxMaxBitrateFeatureSetting", "NvscRiSettings",
    "NvscSliceMethod", "NvscTurboModeOverride",
    "NvscFecSettings", "NvscQosScore", "NvscRtcQosFeedback", "NvscSelectiveFecMethod",
    "NvscSpatialAQSetting", "NvscTemporalAQSetting", "NvscVqosDrcTableType",
    "NvscVqosFecType", "NvscVqosGrcEnableMask", "NvscVqosResControlType",
    "NvscVqosRlBitrateProfile", "NvscVqosRlFeatures", "NvscVqosRlFecProfile",
    "NvscVqosRlLibrary", "NvscVqosTacticsManagerMode", "NvscVqosTransControlType",
]

ALL_TYPES = NVST_TYPES + NVSC_TYPES


def get_demangled_symbols(dylib_path: Path) -> list[str]:
    """Get all demangled symbols from a dylib using nm + c++filt."""
    try:
        nm_out = subprocess.check_output(
            ["nm", "-gU", str(dylib_path)], stderr=subprocess.DEVNULL, text=True
        )
    except subprocess.CalledProcessError:
        return []

    mangled = []
    for line in nm_out.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            sym = parts[2]
            if sym.startswith("__Z") or sym.startswith("_Z"):
                mangled.append(sym.lstrip("_"))

    if not mangled:
        return []

    try:
        demangled = subprocess.check_output(
            ["c++filt"] + mangled, stderr=subprocess.DEVNULL, text=True
        )
        return demangled.splitlines()
    except subprocess.CalledProcessError:
        return []


def parse_methods_from_demangled(symbols: list[str], type_name: str) -> list[str]:
    """Extract method signatures mentioning a given type."""
    results = []
    for sym in symbols:
        if type_name in sym:
            results.append(sym.strip())
    return results


def extract_asm_comments(asm_file: Path, type_name: str) -> list[str]:
    """Extract ## comment lines from assembly that mention a type."""
    results = []
    if not asm_file.exists():
        return results
    with open(asm_file, "r", errors="replace") as f:
        for line in f:
            if "##" in line and type_name in line:
                comment = line[line.index("##") + 2:].strip()
                if comment and comment not in results:
                    results.append(comment)
    return results


def find_operator_new_size(asm_file: Path, func_name_fragment: str) -> list[int]:
    """Scan assembly for operator new() calls within a function to infer struct sizes."""
    sizes = []
    if not asm_file.exists():
        return sizes
    in_func = False
    with open(asm_file, "r", errors="replace") as f:
        for line in f:
            if func_name_fragment in line and ":" in line:
                in_func = True
            elif in_func:
                if line.strip().startswith(";") and line.strip() != ";":
                    in_func = False
                # Look for: bl _Znwm or bl _Znam (new / new[])
                if ("_Znwm" in line or "_Znam" in line):
                    # The argument will be in x0 set just before; look for mov x0, #N
                    pass
                # Look for movz/mov with immediate that feeds into new
                m = re.search(r"movz?\s+x0,\s+#(\d+)", line)
                if m and in_func:
                    sizes.append(int(m.group(1)))
    return sizes


def infer_fields_from_defaults_function(asm_file: Path, type_name: str) -> list[dict]:
    """
    Parse setClientConfigDefaults / getDefault* functions which directly
    store constants into struct fields — revealing offset and value.
    Returns list of {offset: int, raw_value: str}.
    """
    fields = []
    if not asm_file.exists():
        return fields

    func_fragments = [
        f"setClientConfigDefaults",
        f"getDefault{type_name.replace('Nvst', '').replace('Nvsc', '')}",
        f"setConfig{type_name.replace('Nvst', '').replace('Nvsc', '')}",
    ]

    content = asm_file.read_text(errors="replace")
    # Find the function block by scanning for function labels
    for frag in func_fragments:
        if frag not in content:
            continue
        # Find function label
        pattern = re.compile(
            rf"({re.escape(frag)}[^\n]*:\n)((?:.|\n)*?)(?=\n[A-Za-z_][^\n]*:|\Z)"
        )
        for m in pattern.finditer(content):
            block = m.group(2)
            # Extract str/stur immediate stores: str wzr, [x0, #N] or mov w8, #V; str w8, [x0, #N]
            for store_m in re.finditer(r"str[bh]?\s+\w+,\s+\[x\d+,\s+#(\d+)\]", block):
                offset = int(store_m.group(1))
                if {"offset": offset} not in fields:
                    fields.append({"offset": offset, "raw_value": "0"})
    return fields


def build_struct_info() -> dict:
    """Main extraction: combine nm symbols + asm comments + asm analysis."""
    dylibs = [
        DYLIB_DIR / "libBifrost2.dylib",
        DYLIB_DIR / "libGeronimo.dylib",
    ]
    asm_files = [
        ASM_DIR / "libBifrost2.dylib.s",
        ASM_DIR / "libGeronimo.dylib.s",
    ]

    print("Loading demangled symbols from dylibs...", flush=True)
    all_symbols: list[str] = []
    for dylib in dylibs:
        if dylib.exists():
            syms = get_demangled_symbols(dylib)
            all_symbols.extend(syms)
            print(f"  {dylib.name}: {len(syms)} symbols", flush=True)

    results = {}
    for type_name in ALL_TYPES:
        entry = {
            "type_name": type_name,
            "c_name": type_name + "_t",
            "methods": [],
            "asm_comments": [],
            "store_offsets": [],
            "inferred_fields": [],
            "notes": [],
        }

        # 1. Methods from demangled symbols
        entry["methods"] = list(set(parse_methods_from_demangled(all_symbols, type_name)))

        # 2. Assembly comments
        for asm_file in asm_files:
            comments = extract_asm_comments(asm_file, type_name)
            entry["asm_comments"].extend(comments)

        # Deduplicate
        entry["asm_comments"] = list(set(entry["asm_comments"]))

        # 3. Infer field offsets from default-setting functions
        for asm_file in asm_files:
            offsets = infer_fields_from_defaults_function(asm_file, type_name)
            entry["store_offsets"].extend(o["offset"] for o in offsets)

        entry["store_offsets"] = sorted(set(entry["store_offsets"]))

        results[type_name] = entry
        has_info = bool(entry["methods"] or entry["asm_comments"] or entry["store_offsets"])
        print(f"  {type_name}: {len(entry['methods'])} methods, {len(entry['asm_comments'])} asm refs, {len(entry['store_offsets'])} offsets", flush=True)

    return results


if __name__ == "__main__":
    print("=== NVST/NVSC Struct Layout Extractor ===")
    data = build_struct_info()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(data, indent=2))
    print(f"\nWrote {OUT_PATH}")
    print(f"Total types processed: {len(data)}")
