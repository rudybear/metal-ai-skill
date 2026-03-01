"""
Debugging recipe strings for MCP prompts.

Each recipe maps to a SKILL.md workflow (Section 6 + Section 9).
These are registered as MCP prompts so LLM clients can invoke them.
"""

RECIPE_RENDERING_BUG = """\
# Autonomous Metal Debugging Workflow

Debug a Metal rendering issue using parallel signal gathering and iterative fix/verify.

## Step 1: Gather all signal sources (run in parallel)

A. **Screenshot** the app's rendered output:
   ```bash
   ./build_and_run.sh --screenshot
   # OR: screencapture -w -x output.png
   ```

B. **Capture .gputrace** (programmatic):
   ```bash
   METAL_CAPTURE_ENABLED=1 ./your_app
   ```

C. **Compile shaders** with maximum warnings:
   ```bash
   xcrun -sdk macosx metal -c -Weverything Shaders.metal -o /dev/null 2>&1
   ```

D. **Read source code** — .metal files and Swift/ObjC renderer code.

## Step 2: Analyze the capture

```bash
python3 parse_gputrace.py capture.gputrace
ls capture.gputrace/MTLBuffer-* 2>/dev/null && echo "BUFFER DATA AVAILABLE"
ls capture.gputrace/MTLTexture-* 2>/dev/null && echo "TEXTURE DATA AVAILABLE"
```

- If MTLBuffer files exist: parse buffer data directly
- If no MTLBuffer files: fall back to source code analysis
- If MTLTexture files exist: read render target data

## Step 3: Diagnose from all available sources

| Source | What it reveals |
|--------|----------------|
| Screenshot | Wrong colors, flipped geometry, missing faces, blank screen |
| Source code | Logic errors, buffer layout mismatches, shader math bugs |
| Capture metadata | Resource inventory, shader function names, labels |
| Shader warnings | Unused variables, implicit conversions, precision issues |
| Validation errors | Mismatched formats, out-of-bounds access, shader faults |

## Step 4: Fix and verify

1. Apply fixes to source code
2. Rebuild and screenshot
3. Compare before/after visually
4. If still wrong, repeat from Step 1
"""

RECIPE_PROFILE_PERFORMANCE = """\
# GPU Performance Profiling

Profile a Metal app to identify GPU bottlenecks.

## Steps

1. Record a Metal System Trace:
   ```bash
   xcrun xctrace record \\
     --template 'Metal System Trace' \\
     --time-limit 10s \\
     --output perf.trace \\
     --launch -- /path/to/app
   ```

2. Check available data:
   ```bash
   xcrun xctrace export --input perf.trace --toc
   ```

3. Export GPU driver events:
   ```bash
   xcrun xctrace export --input perf.trace \\
     --output gpu_events.xml \\
     --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'
   ```

4. Parse and analyze:
   ```bash
   python3 parse_trace.py gpu_events.xml --summary
   python3 parse_trace.py gpu_events.xml --format json --limit 50
   ```

5. Export GPU counters (Apple Silicon):
   ```bash
   xcrun xctrace export --input perf.trace \\
     --output gpu_counters.xml \\
     --xpath '/trace-toc/run[@number="1"]/data/table[@schema="gpu-counter-intervals"]'
   ```

## Red flags
- GPU busy time > 16ms per frame (below 60fps)
- Large wire memory events (excessive per-frame allocation)
- Gaps between GPU submissions (CPU bottleneck)
- Long shader execution intervals (complex shaders)
"""

RECIPE_SHADER_ERRORS = """\
# Shader Compilation & Validation

Find and fix Metal shader errors.

## Steps

1. Compile with maximum diagnostics:
   ```bash
   xcrun -sdk macosx metal -c -gline-tables-only -Weverything -Werror \\
     MyShader.metal -o /dev/null 2>&1
   ```

2. If compile succeeds but runtime fails, check Metal version:
   ```bash
   xcrun -sdk macosx metal -c -std=metal3.0 MyShader.metal -o /dev/null 2>&1
   ```

3. Check runtime shader errors:
   ```bash
   MTL_SHADER_VALIDATION=1 /path/to/app 2>&1 | head -100
   ```

4. Stream shader validation errors:
   ```bash
   log stream --predicate 'subsystem == "com.apple.Metal"' --level error &
   MTL_SHADER_VALIDATION=1 /path/to/app
   ```

5. Build the full pipeline (.metal -> .air -> .metalar -> .metallib):
   ```bash
   xcrun -sdk macosx metal -c -gline-tables-only MyShader.metal -o MyShader.air
   xcrun -sdk macosx metal-ar rcs MyShader.metalar MyShader.air
   xcrun -sdk macosx metallib MyShader.metalar -o MyShader.metallib
   ```

## Common errors
| Error | Cause | Fix |
|-------|-------|-----|
| undeclared identifier | Missing variable/function | Check spelling, includes, scope |
| no matching function | Wrong argument types | Verify types match signature |
| cannot convert | Type mismatch | Use explicit casts |
| address space mismatch | Wrong buffer qualifier | Check device/constant/threadgroup |
"""

RECIPE_API_MISUSE = """\
# Metal API Validation

Detect Metal API misuse with validation layers.

## Steps

1. Run with full API validation:
   ```bash
   MTL_DEBUG_LAYER=1 /path/to/app 2>&1 | tee validation.log
   ```

2. Check for errors:
   ```bash
   grep -i "error\\|warning\\|invalid\\|violation\\|failed" validation.log
   ```

3. For deeper validation, add shader validation:
   ```bash
   MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 /path/to/app 2>&1 | tee full_validation.log
   ```

4. Stream structured Metal log data:
   ```bash
   log stream --predicate 'subsystem == "com.apple.Metal"' --level error
   ```

## Common issues
| Error Pattern | Meaning | Fix |
|--------------|---------|-----|
| GPU Address Fault | Out-of-bounds buffer access | Check buffer sizes, offsets |
| Shader Validation Error | GPU-side OOB or race | Check array indices, sync |
| Invalid Resource | Using deleted/nil resource | Check resource lifetimes |
| Incompatible Pixel Format | Format mismatch | Verify texture formats |
"""

RECIPE_MONITOR_REALTIME = """\
# Real-Time Performance Monitoring

Monitor Metal performance with the built-in HUD.

## Steps

1. Launch app with HUD and logging:
   ```bash
   MTL_HUD_ENABLED=1 MTL_HUD_LOGGING_ENABLED=1 /path/to/app &
   APP_PID=$!
   ```

2. Stream HUD metrics:
   ```bash
   log stream --predicate 'subsystem == "com.apple.Metal" AND category == "HUD"'
   ```

3. Collect HUD data for analysis:
   ```bash
   log show --predicate 'subsystem == "com.apple.Metal" AND category == "HUD"' \\
     --last 30s > hud_data.log
   ```

4. When done:
   ```bash
   kill $APP_PID
   ```

## HUD metrics
- FPS (frames per second)
- Present interval / frame time (ms)
- GPU time (ms)
- Process memory (MB)
- GPU memory (MB)
- Display refresh rate
- Rendering path (direct vs composited)
"""

RECIPE_COMPARE_PERF = """\
# Performance Comparison (Before/After)

Compare GPU performance across code changes.

## Steps

1. Record baseline:
   ```bash
   xcrun xctrace record \\
     --template 'Metal System Trace' \\
     --time-limit 10s --no-prompt \\
     --output baseline.trace \\
     --launch -- /path/to/app_before
   ```

2. Record after changes:
   ```bash
   xcrun xctrace record \\
     --template 'Metal System Trace' \\
     --time-limit 10s --no-prompt \\
     --output changed.trace \\
     --launch -- /path/to/app_after
   ```

3. Export both:
   ```bash
   for trace in baseline changed; do
     xcrun xctrace export \\
       --input ${{trace}}.trace \\
       --output ${{trace}}_events.xml \\
       --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'
   done
   ```

4. Parse and compare:
   ```bash
   python3 parse_trace.py baseline_events.xml --summary
   python3 parse_trace.py changed_events.xml --summary
   ```
"""

RECIPE_CAPTURE_FRAME = """\
# Frame Capture for Xcode Debugging

Capture a Metal frame to .gputrace for inspection in Xcode.

## For native Metal apps

1. Ensure capture is enabled (one of):
   - Set `METAL_CAPTURE_ENABLED=1` environment variable
   - Add `MetalCaptureEnabled=true` to Info.plist
   - Use MTLCaptureManager in code

2. Run the app:
   ```bash
   METAL_CAPTURE_ENABLED=1 ./your_app
   ```

## For Vulkan apps (via MoltenVK)

```bash
METAL_CAPTURE_ENABLED=1 \\
MVK_CONFIG_AUTO_GPU_CAPTURE_SCOPE=2 \\
MVK_CONFIG_AUTO_GPU_CAPTURE_OUTPUT_FILE=/tmp/capture.gputrace \\
/path/to/vulkan/app
```

## Inspect the capture

```bash
# List resources and shaders
python3 parse_gputrace.py capture.gputrace

# Read buffer data (if available)
python3 parse_gputrace.py capture.gputrace --buffer "Vertex" --layout float4 --index 0-10

# Open in Xcode
open capture.gputrace
```

## Xcode Metal Debugger capabilities
- Step through draw calls
- Inspect pipeline state at each draw
- View bound textures and buffers
- Debug shaders line-by-line
- Check pixel history
- View GPU timeline
"""

# Map recipe names to strings for prompt registration
ALL_RECIPES = {
    "rendering_bug": RECIPE_RENDERING_BUG,
    "profile_performance": RECIPE_PROFILE_PERFORMANCE,
    "shader_errors": RECIPE_SHADER_ERRORS,
    "api_misuse": RECIPE_API_MISUSE,
    "monitor_realtime": RECIPE_MONITOR_REALTIME,
    "compare_perf": RECIPE_COMPARE_PERF,
    "capture_frame": RECIPE_CAPTURE_FRAME,
}
