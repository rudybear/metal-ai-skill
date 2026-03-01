# Metal GPU Debugging + Claude Code

## Project Overview

This project wires Claude Code to Apple's Metal GPU debugging ecosystem via `xctrace`, Metal environment variables, and the `xcrun metal` shader toolchain. It enables automated GPU profiling, validation, shader analysis, and frame capture for Metal applications on macOS.

## Tools

- **xctrace** (`xcrun xctrace`): CLI for Instruments — records Metal System Traces, exports GPU data as XML
- **xcrun metal**: Metal shader compiler (`.metal` → `.air` → `.metallib`)
- **Metal environment variables**: `MTL_DEBUG_LAYER`, `MTL_SHADER_VALIDATION`, `MTL_HUD_ENABLED`, etc.
- **macOS `log` command**: Reads Metal validation errors and HUD data from unified log
- **parse_gputrace.py**: CLI tool for extracting buffer/texture data from `.gputrace` captures using label injection
- **parse_trace.py**: CLI tool for parsing xctrace XML exports into structured TSV/JSON/CSV

## Environment

- Requires **full Xcode** (not just Command Line Tools)
- Traces go in `./traces/` (or any directory you choose)
- Exported XML analysis goes in `./traces/analysis/`
- Shader compilation workspace: `./shaders/`

## Your Application (customize this section)

<!-- Replace with your application details -->
- **Executable**: `/path/to/your/app`
- **Graphics API**: Metal / Vulkan (via MoltenVK)
- **Debug markers**: List any MTLCommandEncoder labels your app sets (e.g., "Shadow Pass", "GBuffer")
- **Metal shaders**: Location of .metal source files
- **Scenes / modes**: List any flags or scenes relevant to profiling

## Prerequisites

- macOS with Apple Silicon or AMD GPU with Metal support
- Xcode installed (full, not just CLT)
- For Vulkan apps: MoltenVK configured

## Quick Start

```bash
# Check setup
xcode-select -p
xcrun xctrace version
xcrun -sdk macosx metal --version

# Profile your app (10 seconds)
xcrun xctrace record \
  --template 'Metal System Trace' \
  --time-limit 10s \
  --output ./traces/profile.trace \
  --launch -- /path/to/your/app

# See what was captured
xcrun xctrace export --input ./traces/profile.trace --toc

# Export GPU data
xcrun xctrace export --input ./traces/profile.trace \
  --output ./traces/analysis/gpu_events.xml \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'

# Validate shader
xcrun -sdk macosx metal -c -Weverything MyShader.metal -o /dev/null
```

## Metal GPU Debugging Skill

See `.claude/skills/metal-gpu-debug/SKILL.md` for the full GPU debugging skill with workflows, recipes, and command reference.
