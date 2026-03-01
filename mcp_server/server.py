#!/usr/bin/env python3
"""
metal-tools MCP server.

Exposes Apple's Metal GPU debugging toolchain as MCP tools:
  - xctrace (profiling, tracing)
  - xcrun metal (shader compilation)
  - Metal validation layers (env vars + log)
  - parse_gputrace.py (buffer/texture inspection)
  - parse_trace.py (trace XML parsing)
  - screencapture / app screenshots

Usage:
    python mcp_server/server.py
    claude mcp add metal-tools -- python mcp_server/server.py
"""

import base64
import glob
import os
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# Add repo root to path so we can find parse_gputrace.py / parse_trace.py
REPO_ROOT = str(Path(__file__).resolve().parent.parent)
sys.path.insert(0, REPO_ROOT)

from mcp_server.metal_runner import format_result, run_cmd
from mcp_server.recipes import (
    RECIPE_API_MISUSE,
    RECIPE_CAPTURE_FRAME,
    RECIPE_COMPARE_PERF,
    RECIPE_MONITOR_REALTIME,
    RECIPE_PROFILE_PERFORMANCE,
    RECIPE_RENDERING_BUG,
    RECIPE_SHADER_ERRORS,
)

mcp = FastMCP("metal-tools")

# Default directories
TRACES_DIR = os.path.join(os.getcwd(), "traces")
ANALYSIS_DIR = os.path.join(TRACES_DIR, "analysis")


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
async def metal_doctor() -> str:
    """Verify the Metal development environment.

    Checks: Xcode installation, xctrace availability, Metal compiler,
    GPU info via system_profiler. Run this before any debugging session.
    """
    checks = []

    # Xcode
    r = await run_cmd(["xcode-select", "-p"])
    xcode_path = r["output"] if r["ok"] else "NOT FOUND"
    is_full_xcode = "Xcode.app" in xcode_path
    checks.append(f"Xcode: {xcode_path}")
    if not is_full_xcode:
        checks.append(
            "  WARNING: Full Xcode required (not just Command Line Tools)"
        )

    # xctrace
    r = await run_cmd(["xcrun", "xctrace", "version"])
    checks.append(f"xctrace: {r['output'] if r['ok'] else 'NOT AVAILABLE'}")

    # Metal compiler
    r = await run_cmd(["xcrun", "-sdk", "macosx", "metal", "--version"])
    version = r["output"].split("\n")[0] if r["ok"] else "NOT AVAILABLE"
    checks.append(f"Metal compiler: {version}")

    # GPU info
    r = await run_cmd(
        ["system_profiler", "SPDisplaysDataType"], timeout=10
    )
    if r["ok"]:
        gpu_lines = [
            line.strip()
            for line in r["output"].split("\n")
            if any(
                kw in line.lower()
                for kw in ("chipset", "metal", "gpu", "vram", "chip model")
            )
        ]
        if gpu_lines:
            checks.append("GPU:")
            for line in gpu_lines:
                checks.append(f"  {line}")
        else:
            checks.append("GPU: (could not parse system_profiler output)")
    else:
        checks.append("GPU: system_profiler failed")

    # Connected devices (non-fatal)
    r = await run_cmd(["xcrun", "xctrace", "list", "devices"], timeout=10)
    if r["ok"]:
        device_lines = [
            l.strip() for l in r["output"].split("\n") if l.strip()
        ]
        checks.append(f"Devices: {len(device_lines)} available targets")

    return "\n".join(checks)


@mcp.tool()
async def metal_trace(
    app: str,
    time_limit: str = "10s",
    output: str = "",
    template: str = "Metal System Trace",
    attach: bool = False,
    env_vars: list[str] | None = None,
    export_schema: str = "metal-driver-event-intervals",
) -> str:
    """Record a Metal System Trace and export GPU data.

    Args:
        app: Path to executable (launch mode) or process name/PID (attach mode).
        time_limit: Recording duration (e.g., "5s", "10s", "1m").
        output: Output .trace path. Defaults to traces/<name>.trace.
        template: Instruments template name.
        attach: If True, attach to running process instead of launching.
        env_vars: Extra env vars as ["KEY=VAL", ...] for xctrace --env.
        export_schema: Schema to export after recording.
    """
    os.makedirs(ANALYSIS_DIR, exist_ok=True)

    if not output:
        app_name = Path(app).stem or "capture"
        output = os.path.join(TRACES_DIR, f"{app_name}.trace")

    # Build record command
    cmd = [
        "xcrun", "xctrace", "record",
        "--template", template,
        "--time-limit", time_limit,
        "--no-prompt",
        "--output", output,
    ]

    if env_vars:
        for ev in env_vars:
            cmd.extend(["--env", ev])

    if attach:
        cmd.extend(["--attach", app])
    else:
        cmd.extend(["--launch", "--", app])

    # Record
    r = await run_cmd(cmd, timeout=300)
    parts = [f"Recording: {format_result(r)}"]

    if not r["ok"]:
        return "\n".join(parts)

    # Export TOC
    toc_path = os.path.join(ANALYSIS_DIR, "toc.xml")
    r_toc = await run_cmd([
        "xcrun", "xctrace", "export",
        "--input", output, "--toc",
    ])
    if r_toc["ok"]:
        with open(toc_path, "w") as f:
            f.write(r_toc["output"])
        parts.append(f"TOC exported to {toc_path}")

    # Export requested schema
    if export_schema:
        export_path = os.path.join(ANALYSIS_DIR, f"{export_schema}.xml")
        xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{export_schema}"]'
        r_exp = await run_cmd([
            "xcrun", "xctrace", "export",
            "--input", output,
            "--output", export_path,
            "--xpath", xpath,
        ])
        if r_exp["ok"]:
            parts.append(f"Exported {export_schema} to {export_path}")
        else:
            parts.append(
                f"Schema {export_schema} not available: {r_exp['error']}"
            )

    return "\n".join(parts)


@mcp.tool()
async def metal_parse_trace(
    xml_file: str,
    format: str = "tsv",
    limit: int = 50,
    summary: bool = False,
) -> str:
    """Parse an exported xctrace XML file into structured data.

    Args:
        xml_file: Path to exported XML file.
        format: Output format — "tsv", "json", or "csv".
        limit: Max rows to output.
        summary: If True, show summary statistics instead of data.
    """
    cmd = ["python3", os.path.join(REPO_ROOT, "parse_trace.py"), xml_file]

    if summary:
        cmd.append("--summary")
    else:
        cmd.extend(["--format", format, "--limit", str(limit)])

    r = await run_cmd(cmd, timeout=30)
    return format_result(r)


@mcp.tool()
async def metal_capture(
    gputrace: str,
    buffer: str = "",
    layout: str = "float4",
    index: str = "0-10",
    dump_all: bool = False,
    json_output: bool = False,
) -> str:
    """Inspect a .gputrace capture — list resources or read buffer data.

    Args:
        gputrace: Path to .gputrace bundle.
        buffer: Buffer label or filename to inspect (empty = list all resources).
        layout: Buffer element layout (e.g., "float4", "float4,float4,float4").
        index: Element index or range (e.g., "100", "0-10").
        dump_all: If True, dump summary statistics for all buffers.
        json_output: If True, output as JSON.
    """
    cmd = ["python3", os.path.join(REPO_ROOT, "parse_gputrace.py"), gputrace]

    if buffer:
        cmd.extend(["--buffer", buffer, "--layout", layout, "--index", index])
        if json_output:
            cmd.append("--json")
    elif dump_all:
        cmd.append("--dump-all")

    r = await run_cmd(cmd, timeout=30)
    return format_result(r)


@mcp.tool()
async def metal_shader(
    shader: str,
    sdk: str = "macosx",
    warnings: bool = True,
    werror: bool = False,
    std: str = "",
    output: str = "",
    build_metallib: bool = False,
) -> str:
    """Compile and validate a Metal shader file.

    Args:
        shader: Path to .metal shader file.
        sdk: Target SDK ("macosx" or "iphoneos").
        warnings: Enable -Weverything (default True).
        werror: Treat warnings as errors.
        std: Metal language standard (e.g., "metal3.0"). Empty = default.
        output: Output file path. Empty = /dev/null (validation only).
        build_metallib: If True, build the full pipeline (.air -> .metalar -> .metallib).
    """
    parts = []

    # Compile
    cmd = ["xcrun", "-sdk", sdk, "metal", "-c", "-gline-tables-only"]
    if warnings:
        cmd.append("-Weverything")
    if werror:
        cmd.append("-Werror")
    if std:
        cmd.extend(["-std", std])

    if build_metallib:
        air_path = output.replace(".metallib", ".air") if output else shader.replace(".metal", ".air")
        cmd.extend([shader, "-o", air_path])
    else:
        out = output or "/dev/null"
        cmd.extend([shader, "-o", out])

    r = await run_cmd(cmd, timeout=30)
    parts.append(f"Compile: {format_result(r)}")

    # Full pipeline if requested
    if build_metallib and r["ok"]:
        metalar_path = air_path.replace(".air", ".metalar")
        metallib_path = output or shader.replace(".metal", ".metallib")

        r_ar = await run_cmd([
            "xcrun", "-sdk", sdk, "metal-ar", "rcs", metalar_path, air_path,
        ])
        parts.append(f"Archive: {format_result(r_ar)}")

        if r_ar["ok"]:
            r_lib = await run_cmd([
                "xcrun", "-sdk", sdk, "metallib", metalar_path, "-o", metallib_path,
            ])
            parts.append(f"Link: {format_result(r_lib)}")

    return "\n".join(parts)


@mcp.tool()
async def metal_validate(
    app: str,
    shader_validation: bool = True,
    timeout: int = 10,
    args: list[str] | None = None,
) -> str:
    """Run a Metal app with validation layers and capture errors.

    Enables MTL_DEBUG_LAYER and optionally MTL_SHADER_VALIDATION,
    then checks stderr and macOS unified log for Metal errors.

    Args:
        app: Path to executable.
        shader_validation: Also enable MTL_SHADER_VALIDATION (default True).
        timeout: How long to run the app (seconds).
        args: Extra arguments to pass to the app.
    """
    env = {"MTL_DEBUG_LAYER": "1"}
    if shader_validation:
        env["MTL_SHADER_VALIDATION"] = "1"

    cmd = [app] + (args or [])
    r = await run_cmd(cmd, timeout=timeout, env=env)
    parts = [f"App output:\n{format_result(r)}"]

    # Check unified log for Metal errors
    r_log = await run_cmd([
        "log", "show",
        "--predicate", 'subsystem == "com.apple.Metal"',
        "--last", f"{timeout + 5}s",
        "--level", "error",
    ], timeout=15)

    if r_log["ok"] and r_log["output"].strip():
        log_lines = r_log["output"].strip().split("\n")
        # Filter out the header line
        error_lines = [l for l in log_lines if "error" in l.lower() or "fault" in l.lower()]
        if error_lines:
            parts.append(f"\nMetal log errors ({len(error_lines)}):")
            for line in error_lines[:20]:
                parts.append(f"  {line}")
        else:
            parts.append("\nMetal log: no errors found")
    else:
        parts.append("\nMetal log: no errors found")

    return "\n".join(parts)


@mcp.tool()
async def metal_hud(
    app: str,
    duration: int = 10,
    args: list[str] | None = None,
) -> str:
    """Run a Metal app with Performance HUD and collect metrics.

    Enables MTL_HUD_ENABLED and MTL_HUD_LOGGING_ENABLED, runs the app
    for the specified duration, then reads HUD metrics from unified log.

    Args:
        app: Path to executable.
        duration: How long to run (seconds).
        args: Extra arguments to pass to the app.
    """
    env = {
        "MTL_HUD_ENABLED": "1",
        "MTL_HUD_LOGGING_ENABLED": "1",
    }

    cmd = [app] + (args or [])
    r = await run_cmd(cmd, timeout=duration + 5, env=env)
    parts = [f"App: {'exited normally' if r['ok'] else 'exited with error'}"]

    # Read HUD data from log
    r_log = await run_cmd([
        "log", "show",
        "--predicate", 'subsystem == "com.apple.Metal" AND category == "HUD"',
        "--last", f"{duration + 10}s",
    ], timeout=15)

    if r_log["ok"] and r_log["output"].strip():
        log_lines = r_log["output"].strip().split("\n")
        # Filter for actual data lines (skip header)
        data_lines = [
            l for l in log_lines
            if any(kw in l for kw in ("FPS", "GPU", "Memory", "frame"))
        ]
        if data_lines:
            parts.append(f"\nHUD metrics ({len(data_lines)} entries):")
            for line in data_lines[:30]:
                parts.append(f"  {line}")
        else:
            parts.append(f"\nHUD log: {len(log_lines)} lines (no FPS/GPU metrics parsed)")
            for line in log_lines[:10]:
                parts.append(f"  {line}")
    else:
        parts.append("\nHUD log: no data captured")

    return "\n".join(parts)


@mcp.tool()
async def metal_screenshot(
    app: str = "",
    output: str = "output.png",
    method: str = "app",
    app_args: list[str] | None = None,
) -> str:
    """Capture a screenshot of a Metal app's output.

    Returns the screenshot as base64-encoded PNG inline.

    Args:
        app: Path to executable (for app method) or empty (for screencapture).
        output: Output PNG file path.
        method: "app" to use app's --screenshot flag, "screencapture" for macOS window capture.
        app_args: Extra arguments for the app.
    """
    if method == "app" and app:
        cmd = [app, "--screenshot"] + (app_args or [])
        r = await run_cmd(cmd, timeout=30)
        if not r["ok"]:
            return f"App screenshot failed: {format_result(r)}"
    elif method == "screencapture":
        r = await run_cmd(["screencapture", "-x", output], timeout=10)
        if not r["ok"]:
            return f"screencapture failed: {format_result(r)}"
    else:
        return "Specify app path with method='app' or use method='screencapture'"

    # Read and encode the screenshot
    if os.path.exists(output):
        size = os.path.getsize(output)
        with open(output, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        return f"Screenshot saved: {output} ({size:,} bytes)\n\ndata:image/png;base64,{b64}"
    else:
        return f"Screenshot file not found at {output}"


@mcp.tool()
async def metal_command(
    command: list[str],
    timeout: int = 60,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
) -> str:
    """Run an arbitrary command (generic fallback).

    Use this for commands not covered by the specialized tools,
    such as custom build scripts, xctrace subcommands, etc.

    Args:
        command: Command and arguments as a list (e.g., ["xcrun", "xctrace", "list", "templates"]).
        timeout: Timeout in seconds.
        env: Optional environment variables.
        cwd: Optional working directory.
    """
    r = await run_cmd(command, timeout=timeout, env=env, cwd=cwd)
    return format_result(r)


# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------


@mcp.resource("metal://traces")
async def list_traces() -> str:
    """List .trace files in the traces/ directory."""
    pattern = os.path.join(TRACES_DIR, "**/*.trace")
    traces = glob.glob(pattern, recursive=True)

    if not traces:
        return f"No .trace files found in {TRACES_DIR}"

    lines = [f"Traces in {TRACES_DIR}:"]
    for t in sorted(traces):
        try:
            # .trace is a directory bundle
            size = sum(
                os.path.getsize(os.path.join(dp, f))
                for dp, _, fns in os.walk(t)
                for f in fns
            )
            lines.append(f"  {os.path.relpath(t, TRACES_DIR):40s}  {size:>12,} bytes")
        except OSError:
            lines.append(f"  {os.path.relpath(t, TRACES_DIR)}")

    return "\n".join(lines)


@mcp.resource("metal://captures")
async def list_captures() -> str:
    """List .gputrace bundles in the current directory tree."""
    pattern = os.path.join(os.getcwd(), "**/*.gputrace")
    captures = glob.glob(pattern, recursive=True)

    if not captures:
        return "No .gputrace bundles found"

    lines = ["GPU trace captures:"]
    for c in sorted(captures):
        try:
            size = sum(
                os.path.getsize(os.path.join(dp, f))
                for dp, _, fns in os.walk(c)
                for f in fns
            )
            lines.append(f"  {c:60s}  {size:>12,} bytes")
        except OSError:
            lines.append(f"  {c}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------


@mcp.prompt()
def debug_rendering_bug() -> str:
    """Autonomous Metal debugging workflow — screenshot + capture + source + fix loop."""
    return RECIPE_RENDERING_BUG


@mcp.prompt()
def profile_performance() -> str:
    """Record trace, export, parse, and analyze GPU performance."""
    return RECIPE_PROFILE_PERFORMANCE


@mcp.prompt()
def fix_shader_errors() -> str:
    """Compile with -Weverything, runtime validation, build metallib pipeline."""
    return RECIPE_SHADER_ERRORS


@mcp.prompt()
def detect_api_misuse() -> str:
    """MTL_DEBUG_LAYER=1, check logs for Metal API validation errors."""
    return RECIPE_API_MISUSE


@mcp.prompt()
def monitor_realtime() -> str:
    """HUD metrics streaming — FPS, GPU time, memory."""
    return RECIPE_MONITOR_REALTIME


@mcp.prompt()
def compare_performance() -> str:
    """Before/after trace comparison workflow."""
    return RECIPE_COMPARE_PERF


@mcp.prompt()
def capture_frame() -> str:
    """Capture .gputrace for Xcode debugging — native Metal and MoltenVK."""
    return RECIPE_CAPTURE_FRAME


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run()
