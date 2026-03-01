// Shaders.metal — Visual demo with intentional rendering bugs
//
// Renders a colored triangle to an offscreen texture.
// Contains INTENTIONAL BUGS for Claude Code to find via .gputrace analysis.
//
// BUG 1: Fragment shader swaps red and blue channels (BGR instead of RGB)
// BUG 2: Vertex shader flips Y axis (triangle renders upside-down)
// BUG 3: Fragment shader multiplies alpha by 0.0 (fully transparent output)

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;

    // BUG 2: Y axis is flipped — multiply by -1.0 instead of 1.0
    // This renders the triangle upside-down
    out.position = float4(in.position.x, in.position.y * -1.0, 0.0, 1.0);

    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    float4 color = in.color;

    // BUG 1: Red and blue channels are swapped (BGR output)
    float r = color.b;  // WRONG: should be color.r
    float g = color.g;
    float b = color.r;  // WRONG: should be color.b

    // BUG 3: Alpha forced to 0.0 — makes everything transparent
    // When blended or composited, nothing will be visible
    float a = color.a * 0.0;  // WRONG: should be color.a * 1.0 (or just color.a)

    return float4(r, g, b, a);
}
