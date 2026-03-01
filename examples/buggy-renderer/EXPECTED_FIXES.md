# Expected Fixes — Answer Key

This documents all 10 bugs and their correct fixes. Use this to verify Claude Code's automated debugging results.

---

## Bug 1: Unused variable in shader (Warning)

**File**: `Shaders.metal`, line ~60
**Detection**: `xcrun -sdk macosx metal -c -Weverything -Werror Shaders.metal`
**Error**: `-Wunused-variable: unused variable 'epsilon'`

**Fix**: Remove the unused variable.
```metal
// DELETE this line:
float epsilon = 0.0001;
```

---

## Bug 2: Expensive math in shader (Performance)

**File**: `Shaders.metal`, `particle_simulate` kernel
**Detection**: xctrace profiling shows long shader execution time
**Issue**: Uses `sin`, `cos`, `pow`, `atan2` in a tight loop when a simple linear perturbation would work.

**Fix**: Replace transcendental math with cheap linear approximation.
```metal
// REPLACE the turbulence block with:
float3 turbulence = float3(
    fract(p.position.x * 1.37) - 0.5,
    fract(p.position.y * 2.41) - 0.5,
    fract(p.position.z * 0.73) - 0.5
) * 0.01;
p.velocity.xyz += turbulence;
```

---

## Bug 3: No bounds check in kernels (OOB Write)

**File**: `Shaders.metal`, all three kernels
**Detection**: `MTL_SHADER_VALIDATION=1` → GPU address fault
**Issue**: Threads with `gid >= particleCount` write past buffer end.

**Fix**: Add early-return bounds check at the top of EVERY kernel.
```metal
// ADD as first line in particle_simulate, color_postprocess, and energy_blur:
if (gid >= params.particleCount) return;
```

---

## Bug 4: Wrong gamma/tonemapping order (Visual)

**File**: `Shaders.metal`, `color_postprocess` kernel
**Detection**: Code review + output shows >50% of particles are too bright
**Issue**: (a) Gamma value 0.45 is the inverse of what's intended. (b) Gamma applied before tonemapping instead of after.

**Fix**: Correct the order and gamma value.
```metal
// REPLACE the entire color_postprocess body (after bounds check) with:
float4 color = particles[gid].color;

// 1. Reinhard tonemapping FIRST (in linear space)
color.rgb = color.rgb / (color.rgb + 1.0);

// 2. Gamma correction AFTER tonemapping (linear → sRGB)
float gamma = 2.2;
color.rgb = pow(max(color.rgb, 0.001), float3(1.0 / gamma));

// 3. Fade based on lifetime
float lifetime = particles[gid].velocity.w;
color.a *= saturate(lifetime);

colorOut[gid] = color;
```

---

## Bug 5: Unsigned integer underflow in blur (OOB Read)

**File**: `Shaders.metal`, `energy_blur` kernel
**Detection**: `MTL_SHADER_VALIDATION=1` → GPU address fault when gid == 0
**Issue**: `gid - 1` wraps to `UINT_MAX` when `gid == 0`. Similarly `gid + 1` overflows at the last element.

**Fix**: Clamp neighbor indices.
```metal
// REPLACE:
uint left  = gid - 1;
uint right = gid + 1;

// WITH:
uint left  = (gid > 0) ? gid - 1 : 0;
uint right = (gid < params.particleCount - 1) ? gid + 1 : params.particleCount - 1;
```

---

## Bug 6: Energy buffer too small (API Misuse)

**File**: `main.swift`, line ~118
**Detection**: `MTL_DEBUG_LAYER=1` → buffer overrun / GPU address fault
**Issue**: Buffer allocated for `PARTICLE_COUNT / 2` instead of `PARTICLE_COUNT`.

**Fix**:
```swift
// REPLACE:
let energyBufferSize = MemoryLayout<Float>.stride * (PARTICLE_COUNT / 2)

// WITH:
let energyBufferSize = MemoryLayout<Float>.stride * PARTICLE_COUNT
```

---

## Bug 7: Hardcoded threadgroup size + truncated dispatch (Correctness)

**File**: `main.swift`, lines ~145-150
**Detection**: Console prints "WARNING: Only X of Y particles will be processed!"
**Issue**: (a) Threadgroup size hardcoded to 512, may exceed device max. (b) Integer division truncates, missing trailing particles.

**Fix**: Query pipeline for max threadgroup size and round up dispatch.
```swift
// REPLACE:
let threadsPerGroup = MTLSize(width: 512, height: 1, depth: 1)
let threadgroupCount = MTLSize(
    width: PARTICLE_COUNT / 512,
    height: 1,
    depth: 1
)

// WITH:
let maxThreads = simulatePipeline.maxTotalThreadsPerThreadgroup
let threadsPerGroup = MTLSize(width: min(maxThreads, 256), height: 1, depth: 1)
let threadgroupCount = MTLSize(
    width: (PARTICLE_COUNT + threadsPerGroup.width - 1) / threadsPerGroup.width,
    height: 1,
    depth: 1
)
```

---

## Bug 8: 200x redundant dispatch loop (Performance)

**File**: `main.swift`, line ~168
**Detection**: xctrace profiling → particle_simulate dominates GPU time
**Issue**: Simulation kernel dispatched 200 times per frame instead of once.

**Fix**:
```swift
// REPLACE:
for _ in 0..<200 {

// WITH:
for _ in 0..<1 {

// Or better, remove the loop entirely and just dispatch once.
```

---

## Bug 9: Read before GPU completion (Race Condition)

**File**: `main.swift`, lines ~191-198
**Detection**: Code review — buffer read happens before `commit()` and `waitUntilCompleted()`
**Issue**: CPU reads stale/undefined buffer contents.

**Fix**: Move the buffer read AFTER `waitUntilCompleted()`.
```swift
// MOVE THESE LINES:
commandBuffer.commit()
commandBuffer.waitUntilCompleted()

// TO BEFORE the energyPtr / totalEnergy reading code.
// The correct order is:
//   1. commit()
//   2. waitUntilCompleted()
//   3. THEN read buffers
```

---

## Bug 10: No error checking on command buffer (Error Handling)

**File**: `main.swift`, after `waitUntilCompleted()`
**Detection**: Code review — GPU faults are silently swallowed
**Issue**: If the GPU faults (due to bugs 3, 5, 6), the error is never reported.

**Fix**: Add error checking after wait.
```swift
commandBuffer.commit()
commandBuffer.waitUntilCompleted()

// ADD:
if commandBuffer.status == .error {
    print("GPU ERROR in frame \(frame): \(commandBuffer.error?.localizedDescription ?? "unknown")")
}
```

---

## Verification Checklist

After all fixes are applied:

```bash
# 1. Shader compiles cleanly
xcrun -sdk macosx metal -c -Weverything -Werror Shaders.metal -o Shaders.air
# Expected: no warnings, no errors

# 2. No validation errors
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./buggy_renderer
# Expected: clean run, no error output

# 3. Performance is reasonable
# Expected: < 50ms/frame (was 500ms+ with 200x loop)

# 4. Colors are correct
# Expected: "Color distribution" shows < 20% bright (was > 50%)

# 5. All particles processed
# Expected: no "WARNING: Only X of Y particles" message

# 6. Frame output is consistent
# Expected: energy and color values are deterministic per run
#           (no race condition producing random stale data)
```
