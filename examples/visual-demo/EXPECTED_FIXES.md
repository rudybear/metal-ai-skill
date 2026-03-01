# Expected Fixes — Visual Demo Answer Key

## Bug 1: Color channels swapped (BGR instead of RGB)

**File**: `Shaders.metal`, `fragment_main`
**Detection**: `parse_gputrace.py --buffer "Triangle Vertices"` shows vertex 0 has color (1,0,0,1) = RED, but the output pixel at that vertex shows blue — channels are swapped.

**Fix**:
```metal
// REPLACE:
float r = color.b;
float g = color.g;
float b = color.r;

// WITH:
float r = color.r;
float g = color.g;
float b = color.b;
```

## Bug 2: Y axis flipped (triangle upside-down)

**File**: `Shaders.metal`, `vertex_main`
**Detection**: Visual inspection of output.png — red vertex should be at top but appears at bottom.

**Fix**:
```metal
// REPLACE:
out.position = float4(in.position.x, in.position.y * -1.0, 0.0, 1.0);

// WITH:
out.position = float4(in.position.x, in.position.y, 0.0, 1.0);
```

## Bug 3: Alpha forced to zero (transparent output)

**File**: `Shaders.metal`, `fragment_main`
**Detection**: `parse_gputrace.py` shows render target pixels all have A=0. App prints "WARNING: Low average alpha".

**Fix**:
```metal
// REPLACE:
float a = color.a * 0.0;

// WITH:
float a = color.a;
```

## Bug 4: Top vertex position wrong (lopsided triangle)

**File**: `main.swift`, vertex data
**Detection**: `parse_gputrace.py --buffer "Triangle Vertices" --layout "float2,float4" --index 0-2` shows vertex 0 position is (0.9, 0.8) instead of (0.0, 0.8).

**Fix**:
```swift
// REPLACE:
Vertex(position: SIMD2<Float>(0.9, 0.8), ...)

// WITH:
Vertex(position: SIMD2<Float>(0.0, 0.8), ...)
```

## Bug 5: Clear color is black (should be dark gray)

**File**: `main.swift`, render pass descriptor
**Detection**: Code review — black background makes it hard to see the triangle edges.

**Fix**:
```swift
// REPLACE:
renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

// WITH:
renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
```

## Verification

After all fixes:
```bash
./build_and_run.sh
open output.png
# Should show: centered equilateral-ish triangle with
# RED at top, GREEN at bottom-left, BLUE at bottom-right
# on a dark gray background, fully opaque
```
