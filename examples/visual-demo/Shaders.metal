// Shaders.metal — Cube vertex/fragment shaders

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

struct Uniforms {
    float4x4 mvpMatrix;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;
    out.position = uniforms.mvpMatrix * float4(in.position, 1.0);
    out.position.y *= -1.0;
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    float4 color = in.color;

    float r = color.b;
    float g = color.g;
    float b = color.r;
    float a = color.a * 0.0;

    return float4(r, g, b, a);
}
