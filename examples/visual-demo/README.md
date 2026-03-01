# Visual Demo — Metal Debug Skill

A headless Metal rendering app with **5 intentional bugs** that produce visibly broken output. Designed to demonstrate Claude Code's ability to diagnose rendering issues from `.gputrace` buffer analysis.

## What It Renders

A colored triangle (red/green/blue vertices) to a 512x512 offscreen texture, saved as `output.png`. The bugs make it look obviously wrong — lopsided, color-swapped, and transparent.

## Quick Start

```bash
chmod +x build_and_run.sh
./build_and_run.sh                # Build, render, save output.png
open output.png                   # View the broken result

./build_and_run.sh --capture      # Capture + analyze .gputrace
```

## The 5 Bugs

| # | File | Bug | How Claude Detects It |
|---|------|-----|----------------------|
| 1 | Shaders.metal | R/B channels swapped in fragment shader | Vertex buffer has RED at vertex 0, but output shows BLUE there |
| 2 | Shaders.metal | Y axis flipped in vertex shader | Red vertex (top) appears at bottom of output |
| 3 | Shaders.metal | Alpha multiplied by 0 (transparent) | Render target pixels all have A=0 |
| 4 | main.swift | Top vertex X=0.9 instead of 0.0 (lopsided) | `parse_gputrace.py --buffer "Triangle Vertices"` shows wrong position |
| 5 | main.swift | Clear color is black instead of dark gray | Code review |

## How Claude Debugs It

```bash
# 1. Capture a frame
METAL_CAPTURE_ENABLED=1 ./visual_demo

# 2. List resources
python3 ../../parse_gputrace.py capture.gputrace
# Resources:
#   MTLBuffer-X-0  → Triangle Vertices
#   MTLTexture-Y-0 → Render Target

# 3. Read vertex buffer — spots Bug 4 (wrong position)
python3 ../../parse_gputrace.py capture.gputrace \
  --buffer "Triangle Vertices" --layout "float2,float4" --index 0-2
# [0] (0.9000, 0.8000) | (1.0000, 0.0000, 0.0000, 1.0000)  ← X should be 0.0!
# [1] (-0.8000, -0.8000) | (0.0000, 1.0000, 0.0000, 1.0000)
# [2] (0.8000, -0.8000) | (0.0000, 0.0000, 1.0000, 1.0000)

# 4. Claude reads the shaders, spots Bugs 1, 2, 3
# 5. Claude reads main.swift, spots Bug 5
# 6. Claude fixes all bugs, rebuilds, verifies output.png is correct
```

## Expected Output

**Before (buggy)**: Lopsided triangle, wrong colors, transparent on black background
**After (fixed)**: Centered triangle with R/G/B vertices on dark gray background
