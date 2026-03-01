// Shaders.metal — Buggy Metal shaders for testing metal-ai-skill
//
// This file contains INTENTIONAL BUGS for Claude Code to find and fix.
// Do not fix these manually — use them to test the automated debugging pipeline.
//
// There are 5 shader-side issues planted in this file.

#include <metal_stdlib>
using namespace metal;

// ============================================================
// BUG 1: Unused variable (compiler warning)
//   The 'epsilon' constant is declared but never used anywhere.
//   Should trigger -Wunused-variable.
// ============================================================

// BUG 2: Expensive math in inner loop (performance)
//   Using sin/cos/pow in a tight loop when a simple multiply would suffice.
//   This will show up as long shader execution in xctrace profiling.

// BUG 3: Potential out-of-bounds write (shader validation)
//   The kernel writes to output[gid] without checking if gid < dataSize.
//   With non-aligned threadgroup sizes, threads past the end will write OOB.

// BUG 4: Wrong color calculation (logic/visual bug)
//   The gamma correction uses gamma=0.45 (inverted) instead of 2.2,
//   AND applies it before the color transform instead of after.
//   Result: washed-out, incorrectly bright output.

// BUG 5: Integer overflow in index calculation
//   When computing neighbor indices for the blur kernel, the code uses
//   unsigned int subtraction (gid - 1) which wraps around to UINT_MAX
//   when gid == 0, causing a massive out-of-bounds read.


// ---------- Structures ----------

struct Particle {
    float4 position;    // xyz = position, w = mass
    float4 velocity;    // xyz = velocity, w = lifetime
    float4 color;       // rgba
};

struct SimParams {
    uint   particleCount;
    float  deltaTime;
    float  damping;
    float  gravity;
};


// ---------- Kernel 1: Particle Simulation ----------
// Simulates N-body particle physics (simplified)

kernel void particle_simulate(
    device Particle*       particles  [[buffer(0)]],
    constant SimParams&    params     [[buffer(1)]],
    device float*          energyOut  [[buffer(2)]],
    uint                   gid        [[thread_position_in_grid]])
{
    // BUG 1: FIXED — removed unused variable 'epsilon'

    // BUG 3: FIXED — bounds check added
    if (gid >= params.particleCount) return;

    Particle p = particles[gid];

    // Apply gravity
    p.velocity.y -= params.gravity * params.deltaTime;

    // Apply damping
    p.velocity.xyz *= params.damping;

    // BUG 2: FIXED — replaced expensive transcendentals with cheap linear approximation
    float3 turbulence = float3(
        fract(p.position.x * 1.37) - 0.5,
        fract(p.position.y * 2.41) - 0.5,
        fract(p.position.z * 0.73) - 0.5
    ) * 0.01;
    p.velocity.xyz += turbulence;

    // Update position
    p.position.xyz += p.velocity.xyz * params.deltaTime;

    // Decrease lifetime
    p.velocity.w -= params.deltaTime;

    // Compute kinetic energy
    float speed = length(p.velocity.xyz);
    float energy = 0.5 * p.position.w * speed * speed;
    energyOut[gid] = energy;

    particles[gid] = p;
}


// ---------- Kernel 2: Color Post-Process ----------
// Applies gamma correction and tone mapping to particle colors

kernel void color_postprocess(
    device Particle*    particles  [[buffer(0)]],
    constant SimParams& params     [[buffer(1)]],
    device float4*      colorOut   [[buffer(2)]],
    uint                gid        [[thread_position_in_grid]])
{
    // BUG 3: FIXED — bounds check added
    if (gid >= params.particleCount) return;

    float4 color = particles[gid].color;

    // BUG 4: FIXED — correct order (tonemapping first, then gamma) and correct gamma value
    // 1. Reinhard tonemapping FIRST (in linear space)
    color.rgb = color.rgb / (color.rgb + 1.0);

    // 2. Gamma correction AFTER tonemapping (linear -> sRGB)
    float gamma = 2.2;
    color.rgb = pow(max(color.rgb, 0.001), float3(1.0 / gamma));

    // 3. Fade based on lifetime
    float lifetime = particles[gid].velocity.w;
    color.a *= saturate(lifetime);

    colorOut[gid] = color;
}


// ---------- Kernel 3: Spatial Blur ----------
// 1D blur over particle energies for smoothing

kernel void energy_blur(
    device float*       energyIn   [[buffer(0)]],
    device float*       energyOut  [[buffer(1)]],
    constant SimParams& params     [[buffer(2)]],
    uint                gid        [[thread_position_in_grid]])
{
    // BUG 3: FIXED — bounds check added
    if (gid >= params.particleCount) return;

    // BUG 5: FIXED — clamp neighbor indices to avoid underflow/overflow
    uint left  = (gid > 0) ? gid - 1 : 0;
    uint right = (gid < params.particleCount - 1) ? gid + 1 : params.particleCount - 1;

    float sum = energyIn[left] + energyIn[gid] + energyIn[right];
    energyOut[gid] = sum / 3.0;
}
