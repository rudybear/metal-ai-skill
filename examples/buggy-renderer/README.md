# Buggy Renderer — Metal Debug Skill Test Project

A headless Metal compute application with **10 intentional bugs** for testing whether Claude Code can automatically detect and fix GPU issues using the `metal-ai-skill`.

## What It Does

Simulates 10,000 particles using Metal compute shaders:
1. **Particle simulation** — N-body physics with gravity, damping, turbulence
2. **Color post-processing** — gamma correction and tonemapping
3. **Energy blur** — spatial smoothing of kinetic energy values

The app runs 5 frames and reports per-frame metrics. It should run in under a second on any Metal-capable Mac, but bugs make it slow, produce wrong results, and risk GPU faults.

## Quick Start

```bash
chmod +x build_and_run.sh

# Build and run normally (you'll see warnings and wrong output)
./build_and_run.sh

# Run the full analysis pipeline
./build_and_run.sh --full
```

## How to Test with Claude Code

Copy or symlink the `.claude/` skill directory into this project, then ask Claude Code to debug it:

```bash
# Setup
cp -r ../../.claude .

# Then in Claude Code, try these prompts:
```

### Test Prompts (from easiest to hardest)

**Level 1 — Shader compilation**
> "Check the Metal shaders in this project for any issues"

Expected: Claude runs `xcrun metal -Weverything -Werror` and finds the unused variable warning.

**Level 2 — Validation errors**
> "Run buggy_renderer with Metal validation and tell me what's wrong"

Expected: Claude runs with `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`, detects the undersized buffer (BUG 6) and OOB access (BUG 3, 5).

**Level 3 — Performance profiling**
> "Profile this Metal app and find why it's slow"

Expected: Claude records an xctrace trace, exports GPU events, and identifies the 200x redundant dispatch loop (BUG 8) dominating GPU time.

**Level 4 — Visual/logic bugs**
> "The particle colors look washed out — debug the color post-processing"

Expected: Claude examines the shader, finds the inverted gamma and wrong tonemapping order (BUG 4).

**Level 5 — Full automated fix**
> "Find and fix all bugs in this Metal project"

Expected: Claude runs the full pipeline (doctor → shader check → validate → profile → analyze), identifies all 10 bugs, and produces corrected `main.swift` and `Shaders.metal`.

## The 10 Bugs

The bugs are split across shader code and host code, spanning different categories that exercise different parts of the debugging skill:

| # | Location | Category | Detection Method |
|---|----------|----------|-----------------|
| 1 | Shaders.metal | Compiler warning | `xcrun metal -Weverything` |
| 2 | Shaders.metal | Performance | xctrace profiling (long shader time) |
| 3 | Shaders.metal | Correctness | `MTL_SHADER_VALIDATION=1` (OOB write) |
| 4 | Shaders.metal | Logic/visual | Code review + output analysis |
| 5 | Shaders.metal | Correctness | `MTL_SHADER_VALIDATION=1` (OOB read) |
| 6 | main.swift | API misuse | `MTL_DEBUG_LAYER=1` (buffer too small) |
| 7 | main.swift | Correctness | Code review + device query |
| 8 | main.swift | Performance | xctrace profiling (200x dispatch) |
| 9 | main.swift | Race condition | Code review + validation |
| 10 | main.swift | Error handling | Code review |

### Detection method coverage

- **Shader compilation** (`xcrun metal -Weverything`): Bug 1
- **API validation** (`MTL_DEBUG_LAYER=1`): Bugs 3, 5, 6
- **Shader validation** (`MTL_SHADER_VALIDATION=1`): Bugs 3, 5
- **Performance profiling** (`xctrace`): Bugs 2, 8
- **Code review / analysis**: Bugs 4, 7, 9, 10

This means Claude needs to use **all parts of the skill** to find all bugs — no single tool catches everything.

## Scoring

After Claude attempts fixes, run `./build_and_run.sh --full` again:

- **Shader compiles with no warnings** → Bugs 1 fixed
- **No validation errors** → Bugs 3, 5, 6 fixed
- **Frame time < 50ms** (was ~500ms+) → Bug 8 fixed
- **Color distribution: < 20% bright** (was > 50%) → Bug 4 fixed
- **All particles processed** (no "only X of Y" warning) → Bug 7 fixed
- **No race condition** (read after waitUntilCompleted) → Bug 9 fixed
- **Error checking present** → Bug 10 fixed
- **Shader math simplified** → Bug 2 fixed (optional — correctness first)

## Expected Fix Summary

See [EXPECTED_FIXES.md](EXPECTED_FIXES.md) for the complete answer key with corrected code.
