# Session Context: metal-ai-skill Development

This document captures the full context from the claude.ai design session (2026-02-28)
where metal-ai-skill was conceived, researched, and built. Feed this to Claude Code
so it has complete context for continuing development.

## Origin

metal-ai-skill extends the renderdoc-skill project (github.com/rudybear/renderdoc-skill)
to Apple's Metal ecosystem. renderdoc-skill gives Claude Code 66 CLI commands for GPU
debugging Vulkan/D3D/GL apps via RenderDoc. The question was: can we do the same for Metal?

## Key Finding: No Direct Equivalent, But a Viable Composition

There is no `rdc-cli` equivalent for Metal. Apple's GPU debugging is Xcode-centric with
a proprietary `.gputrace` format that has no public parsing API. However, a viable skill
was built by composing multiple Apple tools:

### Tools That Work from CLI (what this skill uses)

1. **xctrace** — CLI for Instruments. Records Metal System Traces, exports GPU data as
   parseable XML. This is the primary tool. Supports macOS and iOS devices over USB.

2. **Metal validation layers** — `MTL_DEBUG_LAYER=1` (API validation) and
   `MTL_SHADER_VALIDATION=1` (GPU shader validation). Errors go to stderr and macOS
   unified log (`log stream --predicate 'subsystem == "com.apple.Metal"'`).

3. **Metal Performance HUD** — `MTL_HUD_ENABLED=1` real-time overlay with FPS, GPU time,
   memory. `MTL_HUD_LOGGING_ENABLED=1` logs metrics to system log for parsing.

4. **xcrun metal** — Shader compiler toolchain. `.metal` → `.air` → `.metallib`.
   Supports `-Weverything -Werror` for compile-time validation.

5. **MTLCaptureManager** — Programmatic `.gputrace` capture API (Swift/ObjC).
   `METAL_CAPTURE_ENABLED=1` env var required.

6. **macOS `log` command** — Reads Metal validation errors and HUD data from unified log.

### What Requires Xcode GUI (cannot automate from CLI)

- Inspecting `.gputrace` captures (draw calls, pipeline state, textures, shaders)
- Pixel history
- Shader step-through debugging
- Render target export from captures
- Acceleration structure viewer

### The Gap

renderdoc-skill's biggest strength is post-mortem capture inspection from CLI (open .rdc →
inspect draws → check pipeline → export render targets → debug pixels). Metal has NO CLI
equivalent for this. `.gputrace` files are Xcode-only black boxes.

The skill compensates by being strong on:
- Profiling (xctrace beats RenderDoc's GPU counters)
- Validation (two layers: API + shader)
- Shader compilation diagnostics
- Real-time monitoring (Performance HUD)
- Automated pipeline (doctor → record → export → parse → analyze → report)

## Architecture Decisions

1. **Standalone repo** (not merged into renderdoc-skill) — different platforms, tools, and
   evolution trajectories. They reference each other in READMEs.

2. **Same directory convention** — `.claude/skills/metal-gpu-debug/SKILL.md` mirrors
   `.claude/skills/renderdoc-gpu-debug/SKILL.md`. Both can coexist in a project.

3. **Fire-and-forget sessions** — Unlike RenderDoc's daemon model (open/close), xctrace
   recordings are self-contained. No session state to manage.

4. **Automated pipeline** — SKILL.md Section 1 has the full autonomous workflow:
   Doctor → Record → Export → Parse → Analyze → Report → Cleanup.
   This is what tells Claude Code HOW to drive the tools end-to-end.

5. **parse_trace.py** — Helper script for parsing xctrace XML exports. Handles the
   ref-node resolution system that xctrace XML uses (nodes with `id` attrs are originals,
   nodes with `ref` attrs point back). Outputs TSV/JSON/CSV.

## xctrace Key Details

### Recording
```
xcrun xctrace record --template 'Metal System Trace' --time-limit 10s --no-prompt \
  --output trace.trace --launch -- /path/to/app
```
- Always use `--no-prompt` for automation
- Always use `--time-limit`
- `--device NAME_OR_UDID` for iOS
- `--attach PID_OR_NAME` for running processes
- `--env VAR=value` to set env vars on launched process

### Exporting
```
xcrun xctrace export --input trace.trace --toc                    # see what's in it
xcrun xctrace export --input trace.trace --output events.xml \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'
```

### Key schemas
- `metal-driver-event-intervals` — GPU work, wire memory, resource events
- `gpu-counter-intervals` — hardware performance counters
- `metal-gpu-intervals` — per-encoder GPU execution intervals
- Availability varies by Xcode version, template, GPU — always check TOC first

### XML reference system
Nodes with `id="42"` are originals. Nodes with `ref="42"` point back. Must resolve
refs when parsing. parse_trace.py handles this.

## iOS Support

xctrace profiles iOS/iPadOS devices over USB identically to local Mac profiling.
- `xcrun xctrace list devices` to discover devices
- `--launch` uses bundle identifier (not path) on iOS
- `--attach` uses process name or PID
- `.trace` files are the same format — all export/parse works identically
- Shader compilation uses `-sdk iphoneos` instead of `-sdk macosx`
- `.gputrace` capture on iOS requires Xcode attached

## MoltenVK Bridge

Vulkan apps on macOS via MoltenVK can auto-generate `.gputrace`:
```
METAL_CAPTURE_ENABLED=1
MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE=2        # first frame
MVK_CONFIG_AUTO_GPU_CAPTURE_OUTPUT_FILE=/tmp/capture.gputrace
```

## Test Project: buggy-renderer

`examples/buggy-renderer/` contains a headless Metal compute app (particle simulation)
with 10 intentional bugs spanning 5 detection categories. Designed so Claude Code must
use ALL parts of the skill to find all bugs.

### The 10 Bugs

**Shader-side (Shaders.metal):**
1. Unused variable `epsilon` — caught by `xcrun metal -Weverything`
2. Expensive sin/cos/pow in loop — caught by xctrace profiling
3. No bounds check (`if gid >= count return`) — caught by `MTL_SHADER_VALIDATION=1`
4. Wrong gamma (0.45 not 2.2) + wrong order (gamma before tonemapping) — code review
5. Unsigned underflow `gid - 1` when gid==0 → OOB read — caught by shader validation

**Host-side (main.swift):**
6. Energy buffer allocated at half size — caught by `MTL_DEBUG_LAYER=1`
7. Hardcoded threadgroup size 512 + truncated dispatch (no round-up) — code review
8. Simulation kernel dispatched 200x per frame — caught by xctrace profiling
9. Buffer read before `waitUntilCompleted()` — race condition, code review
10. No `commandBuffer.error` checking — missing error handling, code review

### Detection method coverage
- Shader compilation: Bug 1
- API validation: Bugs 3, 5, 6
- Shader validation: Bugs 3, 5
- Performance profiling: Bugs 2, 8
- Code review/analysis: Bugs 4, 7, 9, 10

Answer key: `examples/buggy-renderer/EXPECTED_FIXES.md`

### Build (no Xcode project needed)
```bash
cd examples/buggy-renderer
xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib
swiftc -framework Metal -framework CoreGraphics main.swift -o buggy_renderer
./buggy_renderer
```

Or use the helper: `./build_and_run.sh --full`

## File Structure

```
metal-ai-skill/
├── .claude/skills/metal-gpu-debug/
│   ├── SKILL.md                              # Main skill (11+ sections)
│   └── references/
│       ├── xctrace-quick-ref.md              # Command reference
│       └── debugging-recipes.md              # 9 step-by-step recipes
├── examples/buggy-renderer/
│   ├── Shaders.metal                         # Buggy Metal shaders (5 bugs)
│   ├── main.swift                            # Buggy host code (5 bugs) + MTLCaptureManager
│   ├── build_and_run.sh                      # Build/validate/profile helper
│   ├── README.md                             # Test prompts and scoring
│   └── EXPECTED_FIXES.md                     # Answer key
├── CLAUDE.md                                 # Project context for Claude Code
├── README.md                                 # Setup and usage guide
├── capture_frame.swift                       # MTLCaptureManager example
├── parse_trace.py                            # xctrace XML parser
├── parse_gputrace.py                         # .gputrace buffer/texture inspector (label injection)
└── LICENSE                                   # MIT
```

## Open Source References

- renderdoc-skill: github.com/rudybear/renderdoc-skill
- RenderDoc: github.com/baldurk/renderdoc
- MoltenVK: github.com/KhronosGroup/MoltenVK
- PyObjC Metal: pypi.org/project/pyobjc-framework-Metal
- TraceUtility: github.com/Qusic/TraceUtility
- xctraceprof: github.com/fzhinkin/xctraceprof

## Next Steps

1. Test all 10 bugs with Claude Code using the skill
2. Publish to github.com/rudybear/metal-ai-skill
3. Consider MCP server wrapper (like renderdoc-skill has mcp_server/)
4. Consider PyObjC-based live debugging helper (Phase 3 from research)
5. Upstream to anthropics/skills or agentskills.io
