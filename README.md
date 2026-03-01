# metal-ai-skill

A [Claude Code skill](https://docs.anthropic.com/en/docs/claude-code/skills) for GPU debugging and profiling on Apple's Metal ecosystem.

This is the Metal counterpart to [renderdoc-skill](https://github.com/rudybear/renderdoc-skill). While renderdoc-skill provides GPU debugging for Vulkan/D3D/GL via RenderDoc's `rdc-cli`, metal-ai-skill provides GPU profiling, validation, and shader analysis for Metal apps on macOS via Apple's native toolchain.

## What It Does

Teaches Claude Code how to:

- **Profile** Metal GPU performance using `xctrace` (Metal System Trace) on macOS and iOS devices
- **Export** GPU profiling data as parseable XML (driver events, counters, timelines)
- **Validate** Metal API usage and shader execution with validation layers
- **Monitor** real-time GPU performance via Metal Performance HUD
- **Compile** and validate Metal shaders from the command line
- **Capture** Metal frames to `.gputrace` for Xcode debugging
- **Debug** Vulkan apps on macOS via MoltenVK

## Quick Setup

### 1. Prerequisites

- macOS with Metal-capable GPU (Apple Silicon or AMD)
- **Full Xcode** installed (not just Command Line Tools)
- For Vulkan apps: MoltenVK
- For iOS profiling: physical device connected via USB, device trusted

Verify your setup:

```bash
xcode-select -p                     # Should show Xcode.app path
xcrun xctrace version               # Should print version
xcrun -sdk macosx metal --version   # Should print Metal compiler version
```

### 2. Install the Skill

Copy the `.claude/` directory into your project root:

```bash
# Clone
git clone https://github.com/rudybear/metal-ai-skill.git

# Copy skill into your project
cp -r metal-ai-skill/.claude /path/to/your/project/
```

Or add as a git submodule:

```bash
cd /path/to/your/project
git submodule add https://github.com/rudybear/metal-ai-skill.git .metal-ai
cp -r .metal-ai/.claude .
```

### 3. Customize CLAUDE.md

Edit `CLAUDE.md` in your project root with your app-specific details (executable path, shader locations, debug markers).

## Usage

Once installed, Claude Code will automatically use this skill when you ask about Metal GPU debugging. Example prompts:

- *"Profile my Metal app for 10 seconds and show me what's slow"*
- *"Check this shader for compilation errors"*
- *"Run my app with Metal validation and show me any API errors"*
- *"Capture a frame of my Vulkan app on macOS for debugging"*
- *"Compare GPU performance before and after my shader change"*
- *"Monitor real-time FPS and GPU time while I test"*

## Architecture

```
metal-ai-skill/
├── .claude/
│   └── skills/
│       └── metal-gpu-debug/
│           ├── SKILL.md                          # Main skill definition
│           └── references/
│               ├── xctrace-quick-ref.md          # xctrace command reference
│               └── debugging-recipes.md          # Extended debugging workflows
├── examples/
│   ├── buggy-renderer/                           # 10-bug compute shader demo
│   │   ├── main.swift                            # Headless particle simulation
│   │   ├── Shaders.metal                         # 5 shader bugs + 5 host bugs
│   │   └── build_and_run.sh
│   └── visual-demo/                              # 5-bug rendering demo
│       ├── main.swift                            # Headless triangle renderer → PNG
│       ├── Shaders.metal                         # 3 shader bugs (BGR, Y-flip, alpha=0)
│       └── build_and_run.sh
├── CLAUDE.md                                     # Project context for Claude Code
├── capture_frame.swift                           # Example: programmatic frame capture
├── parse_trace.py                                # Parse xctrace XML exports to TSV/JSON/CSV
├── parse_gputrace.py                             # Inspect .gputrace buffer/texture data from CLI
├── LICENSE
└── README.md
```

## Key Differences from renderdoc-skill

| Feature | renderdoc-skill | metal-ai-skill |
|---------|----------------|-------------------|
| **Primary tool** | `rdc-cli` (66 commands) | `xctrace` + env vars + `xcrun metal` |
| **APIs** | Vulkan, D3D11/12, OpenGL | Metal (+ Vulkan via MoltenVK) |
| **Platform** | Windows, Linux, Android | macOS, iOS/iPadOS (via USB) |
| **Capture format** | `.rdc` (full CLI access) | `.gputrace` (Xcode GUI + CLI buffer inspection) |
| **CLI inspection** | Full (draws, pipeline, pixels, shaders) | Profiling + validation + buffer data (via labels) |
| **Shader debugging** | Step-through from CLI | Compile-time validation only (runtime in Xcode) |
| **GPU profiling** | GPU counters (limited) | Full xctrace + Metal Counters API |
| **Validation** | API validation flag | API + Shader validation layers |
| **Performance HUD** | N/A | Built-in MTL_HUD_ENABLED |

The fundamental difference: RenderDoc gives you full post-mortem capture inspection from CLI. Metal's tooling splits between CLI (profiling, validation, shader compilation, buffer data readback) and Xcode GUI (draw call stepping, shader debugging, pixel history). This skill maximizes what's available from CLI, including the label injection technique for reading buffer/texture data directly from `.gputrace` captures.

## Examples

### Profile GPU performance

```bash
# Claude Code will run:
xcrun xctrace record --template 'Metal System Trace' --time-limit 10s \
  --output traces/profile.trace --launch -- ./MyApp
xcrun xctrace export --input traces/profile.trace --toc
xcrun xctrace export --input traces/profile.trace --output traces/analysis/events.xml \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'
```

### Validate Metal API usage

```bash
# Claude Code will run:
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./MyApp 2>&1 | tee validation.log
```

### Compile and check shaders

```bash
# Claude Code will run:
xcrun -sdk macosx metal -c -Weverything -Werror Shaders.metal -o /dev/null
```

### Inspect buffer data from .gputrace captures

```bash
# Claude Code captures a frame, then reads buffer contents by label:
METAL_CAPTURE_ENABLED=1 ./MyApp

python3 parse_gputrace.py capture.gputrace
# Resources:
#   MTLBuffer-10-0   491,520 bytes  → Particle Buffer
#   MTLBuffer-14-0   163,840 bytes  → Color Output Buffer

python3 parse_gputrace.py capture.gputrace --buffer "Color Output" --layout float4 --index 100
# [100] (0.5909, 0.7278, 0.5450, 1.0000)
```

## Visual Demo

The `examples/visual-demo/` contains a broken Metal renderer with **5 intentional bugs** that produce visibly wrong output. It demonstrates how Claude Code diagnoses rendering issues from `.gputrace` buffer analysis and shader review.

**Before (buggy)** — lopsided, wrong colors, transparent on black:

![Before — buggy output](examples/visual-demo/before.png)

**How Claude fixes it:**

```bash
cd examples/visual-demo
./build_and_run.sh --capture     # Render + capture .gputrace

# Claude analyzes the capture:
python3 ../../parse_gputrace.py capture.gputrace
# Resources:
#   MTLTexture-8-0   → Render Target
# Shader Functions: vertex_main, fragment_main

# Claude reads Shaders.metal — spots 3 bugs:
#   Bug 1: R/B channels swapped (color.b assigned to red)
#   Bug 2: Y axis flipped (position.y * -1.0)
#   Bug 3: Alpha multiplied by 0.0 (transparent)

# Claude reads main.swift — spots 2 bugs:
#   Bug 4: Top vertex X=0.9 instead of 0.0 (lopsided)
#   Bug 5: Clear color is black instead of dark gray

# Claude fixes all 5, rebuilds, verifies output.png is correct
```

**After (fixed)** — centered triangle with R/G/B vertices on dark gray:

The triangle should show RED at top, GREEN at bottom-left, BLUE at bottom-right on a dark gray background, fully opaque.

See also `examples/buggy-renderer/` for a more complex 10-bug compute shader demo.

## License

MIT — see [LICENSE](LICENSE).

## Related Projects

- [renderdoc-skill](https://github.com/rudybear/renderdoc-skill) — RenderDoc GPU debugging skill for Vulkan/D3D/GL
- [RenderDoc](https://github.com/baldurk/renderdoc) — The underlying graphics debugger
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) — Vulkan to Metal translation layer
