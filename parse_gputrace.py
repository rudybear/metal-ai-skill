#!/usr/bin/env python3
"""
parse_gputrace.py — Extract and inspect data from .gputrace captures.

Reads MTLBuffer/MTLTexture files from .gputrace bundles using labels
injected by Claude Code (or set manually) to identify resources.

Usage:
    python3 parse_gputrace.py capture.gputrace
    python3 parse_gputrace.py capture.gputrace --buffer "Color Output Buffer"
    python3 parse_gputrace.py capture.gputrace --buffer "Color Output Buffer" --layout float4 --index 100
    python3 parse_gputrace.py capture.gputrace --buffer "Particle Buffer" --layout "float4,float4,float4" --index 0-10
    python3 parse_gputrace.py capture.gputrace --dump-all
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import json
from pathlib import Path


def parse_metadata(gputrace_path: str) -> dict:
    """Parse the binary plist metadata file."""
    meta_path = os.path.join(gputrace_path, "metadata")
    if not os.path.exists(meta_path):
        return {}
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", meta_path],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        return json.loads(result.stdout)
    return {}


def extract_buffer_labels(gputrace_path: str) -> dict[str, str]:
    """Extract MTLBuffer filename → label mapping from device-resources files.

    The device-resources binary uses a consistent record structure where
    each MTLBuffer/MTLTexture filename is followed by its user-set .label
    at a fixed offset. Labels are identified by containing a space character
    (e.g., "Particle Buffer") since Metal object labels are human-readable
    strings set via `buffer.label = "..."` in code.
    """
    label_map = {}

    for fname in os.listdir(gputrace_path):
        if not fname.startswith("device-resources"):
            continue
        data = open(os.path.join(gputrace_path, fname), "rb").read()

        # Extract all printable strings with their byte offsets
        strings = []
        current = []
        start = None
        for i, b in enumerate(data):
            if 32 <= b <= 126:
                if start is None:
                    start = i
                current.append(chr(b))
            else:
                if len(current) >= 3:
                    strings.append((start, "".join(current)))
                current = []
                start = None

        # Find MTLBuffer/MTLTexture references
        resource_refs = [(off, s) for off, s in strings
                         if re.match(r"MTL(Buffer|Texture)-\d+-\d+", s)]

        # Labels contain spaces (e.g., "Particle Buffer", "Color Output Buffer")
        # and appear after the resource filename in the record
        label_strings = [(off, s) for off, s in strings
                         if " " in s and len(s) >= 5
                         and not s.startswith("MTL")
                         and not s.startswith("/")]

        # Match each resource to its nearest following label
        for roff, rname in resource_refs:
            best_label = None
            best_dist = float("inf")
            for loff, lval in label_strings:
                dist = loff - roff
                if 0 < dist < best_dist:
                    best_dist = dist
                    best_label = lval
            if best_label:
                label_map[rname] = best_label

    return label_map


def extract_shader_info(gputrace_path: str) -> dict:
    """Extract shader function names and pipeline info from device-resources."""
    info = {"functions": [], "libraries": [], "pipelines": []}

    for fname in os.listdir(gputrace_path):
        if not fname.startswith("device-resources"):
            continue
        data = open(os.path.join(gputrace_path, fname), "rb").read()

        strings = []
        current = []
        start = None
        for i, b in enumerate(data):
            if 32 <= b <= 126:
                if start is None:
                    start = i
                current.append(chr(b))
            else:
                if len(current) >= 3:
                    strings.append((start, "".join(current)))
                current = []
                start = None

        for _, s in strings:
            if s.endswith(".metallib"):
                info["libraries"].append(s)

        # Shader function names: only lowercase/underscore identifiers
        # that appear between the .metallib path and "pipeline-libraries"
        in_functions = False
        for _, s in strings:
            if s.endswith(".metallib"):
                in_functions = True
                continue
            if s == "pipeline-libraries":
                in_functions = False
                continue
            if (in_functions
                    and re.match(r"^[a-z_][a-z0-9_]*$", s)
                    and len(s) > 3
                    and s not in ("function", "functions", "buffer", "buffers")):
                if s not in info["functions"]:
                    info["functions"].append(s)

    return info


def read_buffer(gputrace_path: str, filename: str, layout: str, start: int = 0, count: int = 10) -> list[dict]:
    """Read a buffer file with the given layout.

    Layout formats:
        "float"         - single float per element
        "float4"        - 4 floats per element (RGBA, position, etc.)
        "float4,float4,float4"  - 12 floats per element (e.g., Particle struct)
        "uint32"        - single uint32 per element
    """
    filepath = os.path.join(gputrace_path, filename)
    if not os.path.exists(filepath):
        return []

    # Parse layout into component groups
    components = layout.split(",")
    fmt_parts = []
    field_names = []
    for i, comp in enumerate(components):
        comp = comp.strip()
        if comp == "float":
            fmt_parts.append("f")
            field_names.append(f"f{i}")
        elif comp == "float2":
            fmt_parts.append("ff")
            field_names.append(f"xy{i}")
        elif comp == "float3":
            fmt_parts.append("fff")
            field_names.append(f"xyz{i}")
        elif comp == "float4":
            fmt_parts.append("ffff")
            field_names.append(f"xyzw{i}")
        elif comp == "uint32":
            fmt_parts.append("I")
            field_names.append(f"u{i}")
        elif comp == "int32":
            fmt_parts.append("i")
            field_names.append(f"i{i}")
        else:
            print(f"Unknown layout component: {comp}", file=sys.stderr)
            return []

    fmt = "<" + "".join(fmt_parts)
    stride = struct.calcsize(fmt)

    data = open(filepath, "rb").read()
    total_elements = len(data) // stride

    results = []
    for idx in range(start, min(start + count, total_elements)):
        offset = idx * stride
        values = struct.unpack_from(fmt, data, offset)

        entry = {"index": idx}
        vi = 0
        for ci, comp in enumerate(components):
            comp = comp.strip()
            if comp == "float":
                entry[f"field{ci}"] = values[vi]
                vi += 1
            elif comp == "float2":
                entry[f"field{ci}"] = list(values[vi:vi + 2])
                vi += 2
            elif comp == "float3":
                entry[f"field{ci}"] = list(values[vi:vi + 3])
                vi += 3
            elif comp == "float4":
                entry[f"field{ci}"] = list(values[vi:vi + 4])
                vi += 4
            elif comp in ("uint32", "int32"):
                entry[f"field{ci}"] = values[vi]
                vi += 1
        results.append(entry)

    return results


def list_resources(gputrace_path: str):
    """List all files in the .gputrace bundle with sizes and labels."""
    labels = extract_buffer_labels(gputrace_path)
    meta = parse_metadata(gputrace_path)
    shaders = extract_shader_info(gputrace_path)

    print(f"GPU Trace: {gputrace_path}")
    if meta:
        print(f"  UUID: {meta.get('(uuid)', 'unknown')}")
        print(f"  Frames: {meta.get('DYCaptureEngine.captured_frames_count', '?')}")
        api = {1: "Metal"}.get(meta.get("DYCaptureSession.graphics_api"), "Unknown")
        print(f"  API: {api}")
    print()

    # List buffers and textures
    files = sorted(os.listdir(gputrace_path))
    buffers = [f for f in files if re.match(r"MTL(Buffer|Texture)-\d+-\d+", f)]

    if buffers:
        print("Resources:")
        for f in buffers:
            size = os.path.getsize(os.path.join(gputrace_path, f))
            label = labels.get(f, "(no label)")
            print(f"  {f:25s}  {size:>10,} bytes  → {label}")
        print()

    # List shaders
    if shaders["libraries"]:
        print("Shader Libraries:")
        for lib in shaders["libraries"]:
            print(f"  {lib}")
        print()

    if shaders["functions"]:
        print("Shader Functions:")
        for func in shaders["functions"]:
            print(f"  {func}")
        print()

    # Other files
    others = [f for f in files if f not in buffers and f != "metadata"]
    if others:
        print("Internal Files:")
        for f in others:
            size = os.path.getsize(os.path.join(gputrace_path, f))
            print(f"  {f:45s}  {size:>10,} bytes")


def main():
    parser = argparse.ArgumentParser(description="Parse .gputrace captures")
    parser.add_argument("gputrace", help="Path to .gputrace bundle")
    parser.add_argument("--buffer", "-b", help="Buffer label or filename to inspect")
    parser.add_argument("--layout", "-l", default="float4",
                        help="Buffer element layout (e.g., 'float4', 'float', 'float4,float4,float4')")
    parser.add_argument("--index", "-i", default="0-10",
                        help="Element index or range (e.g., '100', '0-10', '5000-5005')")
    parser.add_argument("--dump-all", action="store_true", help="Dump all buffer summaries")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    if not os.path.isdir(args.gputrace):
        print(f"ERROR: Not a directory: {args.gputrace}", file=sys.stderr)
        sys.exit(1)

    if args.buffer:
        labels = extract_buffer_labels(args.gputrace)

        # Resolve label → filename
        filename = None
        if os.path.exists(os.path.join(args.gputrace, args.buffer)):
            filename = args.buffer
        else:
            for fname, label in labels.items():
                if label.lower() == args.buffer.lower():
                    filename = fname
                    break
            if not filename:
                # Partial match
                for fname, label in labels.items():
                    if args.buffer.lower() in label.lower():
                        filename = fname
                        break

        if not filename:
            print(f"ERROR: Buffer '{args.buffer}' not found.", file=sys.stderr)
            print(f"Available buffers:", file=sys.stderr)
            for fname, label in labels.items():
                print(f"  {fname} → {label}", file=sys.stderr)
            sys.exit(1)

        # Parse index range
        if "-" in args.index:
            parts = args.index.split("-")
            start, end = int(parts[0]), int(parts[1])
            count = end - start + 1
        else:
            start = int(args.index)
            count = 1

        rows = read_buffer(args.gputrace, filename, args.layout, start, count)

        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            label = labels.get(filename, filename)
            print(f"{label} ({filename}):")
            for row in rows:
                idx = row["index"]
                fields = {k: v for k, v in row.items() if k != "index"}
                parts = []
                for k, v in fields.items():
                    if isinstance(v, list):
                        parts.append(f"({', '.join(f'{x:.4f}' for x in v)})")
                    elif isinstance(v, float):
                        parts.append(f"{v:.4f}")
                    else:
                        parts.append(str(v))
                print(f"  [{idx:>6}] {' | '.join(parts)}")

    elif args.dump_all:
        import numpy as np
        labels = extract_buffer_labels(args.gputrace)
        for fname in sorted(os.listdir(args.gputrace)):
            if not re.match(r"MTL(Buffer|Texture)-\d+-\d+", fname):
                continue
            filepath = os.path.join(args.gputrace, fname)
            size = os.path.getsize(filepath)
            label = labels.get(fname, "(no label)")
            data = np.fromfile(filepath, dtype=np.float32)
            print(f"{fname} → \"{label}\" ({size:,} bytes, {len(data)} floats)")
            if len(data) > 0:
                print(f"  Range: [{data.min():.4f}, {data.max():.4f}]")
                print(f"  Mean:  {data.mean():.4f}")
                print(f"  First 4: {data[:4]}")
            print()
    else:
        list_resources(args.gputrace)


if __name__ == "__main__":
    main()
