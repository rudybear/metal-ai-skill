// Shaders.metal — Triangle vertex/fragment shaders

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
    out.position = float4(in.position.x, in.position.y * -1.0, 0.0, 1.0);
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
