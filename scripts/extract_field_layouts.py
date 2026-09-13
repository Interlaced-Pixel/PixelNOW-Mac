#!/usr/bin/env python3
"""
Deep struct field extractor: parses specific high-value functions from vendor assembly
to extract store offsets, immediate values, and call targets.

Handles x86_64 AT&T syntax from the vendor .s files:
  lines start with hex address + tab: "00000000002f1fec\tmovl\t$0x0, 0x18(%rbx)"
"""

import re
import json
from pathlib import Path

ROOT = Path(__file__).parent.parent
ASM_FILES = [
    ROOT / "Docs" / "vendor" / "libBifrost2.dylib.s",
    ROOT / "Docs" / "vendor" / "libGeronimo.dylib.s",
    ROOT / "Docs" / "vendor" / "GeForceNOW.s",
]

OUT_PATH = ROOT / "Docs" / "field_layouts.json"

TARGET_FUNCTIONS = {
    "__Z23setClientConfigDefaultsR18NvscClientConfig_tb": (
        "setClientConfigDefaults", "NvscClientConfig_t"),
    "__Z38NvscClientConfigGeneral_auto_setConfigR18NvscClientConfig_t": (
        "NvscClientConfigGeneral_auto_setConfig", "NvscClientConfig_t"),
    "__Z21getDefaultAudioConfigR23NvstAudioStreamConfig_t": (
        "getDefaultAudioConfig", "NvstAudioStreamConfig_t"),
    "__Z19getDefaultMicConfigR21NvstMicStreamConfig_t": (
        "getDefaultMicConfig", "NvstMicStreamConfig_t"),
    "__Z26setNvscBWEstimatorDefaultsR17NvscBWEstimator_t": (
        "setNvscBWEstimatorDefaults", "NvscBWEstimator_t"),
    "__Z20validateStreamConfigR18NvstStreamConfig_t": (
        "validateStreamConfig", "NvstStreamConfig_t"),
    "__Z30setNvscGeneralDefaultsSettingsR21NvscGeneralSettings_t": (
        "setNvscGeneralDefaultsSettings", "NvscGeneralSettings_t"),
    "__Z21validateStreamConfigsjP18NvstStreamConfig_t": (
        "validateStreamConfigs", "NvstStreamConfig_t"),
    "__Z28validatePushStreamDataParamsPvPK16NvstStreamData_t": (
        "validatePushStreamDataParams", "NvstStreamData_t"),
}

# Strip leading hex address + tab from x86_64 lines like:
#   "00000000002f1fec\tmovl\t$0x0, 0x18(%rbx)"
_ADDR_PREFIX = re.compile(r"^[0-9a-fA-F]{8,}\s+")


def normalize_line(line: str) -> str:
    """Remove leading hex address, normalize tabs to spaces."""
    s = _ADDR_PREFIX.sub("", line.strip())
    return s.replace("\t", " ")


def to_int(s: str) -> int:
    """Parse hex or decimal integer string."""
    s = s.strip()
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    return int(s)


def extract_function_body(asm_text: str, func_symbol: str) -> str | None:
    """Extract assembly body from function label to the next top-level label."""
    idx = asm_text.find(func_symbol + ":\n")
    if idx == -1:
        idx = asm_text.find(func_symbol + ":")
    if idx == -1:
        return None

    body_start = asm_text.index("\n", idx) + 1
    search_from = body_start

    while True:
        next_nl = asm_text.find("\n", search_from)
        if next_nl == -1:
            return asm_text[idx:]
        line = asm_text[search_from:next_nl]
        # Top-level label: non-whitespace first char, contains ':', no leading hex address
        if (line and not line[0].isspace() and ":" in line
                and not re.match(r"^[0-9a-fA-F]{8,}", line)):
            return asm_text[idx:search_from]
        search_from = next_nl + 1


def parse_function_body(body: str) -> dict:
    """Parse x86_64 AT&T assembly body for struct field stores/loads."""
    result: dict = {
        "stores": [],
        "loads": [],
        "calls": [],
        "struct_size_hint": None,
    }

    reg_values: dict[str, str] = {}
    prev_esi_val: str | None = None

    for raw_line in body.splitlines():
        line = normalize_line(raw_line)
        if not line:
            continue

        original = raw_line  # keep for ## comment extraction

        # ---- movabsq $imm64, %reg ----
        m = re.match(r"movabsq\s+\\\$(0x[0-9a-fA-F]+|-?\d+),\s+%(\w+)", line)
        if m:
            reg_values[m.group(2)] = m.group(1)
            continue

        # ---- movl $size, %esi (potential bzero size) ----
        m = re.match(r"mov[lq]\s+\\\$(0x[0-9a-fA-F]+|\d+),\s+%(?:esi|rsi)\b", line)
        if m:
            prev_esi_val = m.group(1)
            reg_values["esi"] = m.group(1)
            continue

        # ---- bzero call -> struct total size ----
        if re.search(r"\bbzero\b", line):
            if prev_esi_val:
                result["struct_size_hint"] = prev_esi_val
            prev_esi_val = None
            continue

        prev_esi_val = None

        # ---- movb/movw/movl/movq $imm, offset(%reg) — struct field store ----
        m = re.match(
            r"mov([bwlq])\s+\\\$(0x[0-9a-fA-F]+|-?\d+),\s+(0x[0-9a-fA-F]+|-?\d+)\(%\w+\)",
            line
        )
        if m:
            suffix, imm, off_str = m.group(1), m.group(2), m.group(3)
            try:
                offset = to_int(off_str)
            except ValueError:
                continue
            if offset >= 0:
                size = {"b": 1, "w": 2, "l": 4, "q": 8}[suffix]
                result["stores"].append({"offset": offset, "size": size, "value": imm})
            continue

        # ---- movabsq + movq %reg, offset(%reg) — 64-bit field store ----
        m = re.match(r"mov[qlbwh]?\s+%(\w+),\s+(0x[0-9a-fA-F]+|-?\d+)\(%\w+\)", line)
        if m:
            src, off_str = m.group(1), m.group(2)
            try:
                offset = to_int(off_str)
            except ValueError:
                continue
            if offset >= 0:
                if src in reg_values:
                    result["stores"].append({"offset": offset, "size": 8, "value": reg_values[src]})
                else:
                    result["loads"].append({"offset": offset, "reg": src})
            continue

        # ---- movups/movaps %xmm, offset(%reg) — 16-byte block ----
        m = re.match(r"mov(?:ups|aps)\s+%xmm\d+,\s+(0x[0-9a-fA-F]+|-?\d+)\(%\w+\)", line)
        if m:
            try:
                offset = to_int(m.group(1))
            except ValueError:
                continue
            if offset >= 0:
                result["stores"].append({"offset": offset, "size": 16, "value": "xmm_block"})
            continue

        # ---- movsd %xmm, offset(%reg) — 8-byte double ----
        m = re.match(r"movsd\s+%xmm\d+,\s+(0x[0-9a-fA-F]+|-?\d+)\(%\w+\)", line)
        if m:
            try:
                offset = to_int(m.group(1))
            except ValueError:
                continue
            if offset >= 0:
                result["stores"].append({"offset": offset, "size": 8, "value": "double_init"})
            continue

        # ---- load: movl/movq offset(%reg), %dest ----
        m = re.match(r"mov[bwlq]?\s+(0x[0-9a-fA-F]+|-?\d+)\(%\w+\),\s+%(\w+)", line)
        if m:
            try:
                offset = to_int(m.group(1))
            except ValueError:
                continue
            if offset >= 0:
                result["loads"].append({"offset": offset, "reg": m.group(2)})
            continue

        # ---- call targets ----
        m = re.match(r"(?:bl|callq)\s+((?:__Z|_Z|_)[^\s]+)", line)
        if m:
            sym = m.group(1).lstrip("_")
            comment_m = re.search(r"##\s*(.+)", original)
            target = comment_m.group(1).strip() if comment_m else sym
            if target not in result["calls"]:
                result["calls"].append(target)

    return result


def run() -> dict:
    asm_texts: dict[str, str] = {}
    for asm_file in ASM_FILES:
        if asm_file.exists():
            sz_mb = asm_file.stat().st_size // 1024 // 1024
            print(f"Loading {asm_file.name} ({sz_mb}MB)...", flush=True)
            asm_texts[asm_file.name] = asm_file.read_text(errors="replace")
        else:
            print(f"  Skipping {asm_file.name} (not found)", flush=True)

    results: dict = {}

    for symbol, (display_name, type_name) in TARGET_FUNCTIONS.items():
        print(f"\nSearching: {display_name} ({type_name})", flush=True)
        for asm_name, asm_text in asm_texts.items():
            body = extract_function_body(asm_text, symbol)
            if not body:
                continue
            print(f"  Found in {asm_name} ({len(body)} chars)", flush=True)
            parsed = parse_function_body(body)
            key = f"{display_name}@{asm_name}"
            results[key] = {
                "function": display_name,
                "type": type_name,
                "source_file": asm_name,
                "struct_size": parsed["struct_size_hint"],
                "stores": sorted(parsed["stores"], key=lambda s: s["offset"]),
                "loads": sorted(parsed["loads"], key=lambda l: l["offset"]),
                "calls": list(set(parsed["calls"])),
            }
            print(f"  Size hint: {parsed['struct_size_hint']}", flush=True)
            print(f"  Stores: {len(parsed['stores'])}, Loads: {len(parsed['loads'])}, Calls: {len(parsed['calls'])}", flush=True)
            for s in sorted(parsed["stores"], key=lambda x: x["offset"])[:15]:
                print(f"    +{s['offset']:6d}  [{s['size']}B]  = {s['value']}", flush=True)

    return results


if __name__ == "__main__":
    print("=== NVST/NVSC Deep Field Layout Extractor ===", flush=True)
    data = run()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(data, indent=2))
    print(f"\nWrote {len(data)} function analyses to {OUT_PATH}", flush=True)
