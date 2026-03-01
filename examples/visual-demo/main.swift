// main.swift — Headless Metal renderer that draws a colored triangle to PNG

import Foundation
import Metal
import CoreGraphics
import ImageIO

// --- Constants ---

let WIDTH  = 512
let HEIGHT = 512

// --- Vertex Data ---

// Packed vertex layout: float2 position + float4 color = 24 bytes, no padding
struct Vertex {
    var px: Float; var py: Float           // position
    var cr: Float; var cg: Float           // color
    var cb: Float; var ca: Float
}

let vertices: [Vertex] = [
    Vertex(px: 0.9, py: 0.8,   cr: 1, cg: 0, cb: 0, ca: 1),  // RED
    Vertex(px: -0.8, py: -0.8, cr: 0, cg: 1, cb: 0, ca: 1),  // GREEN
    Vertex(px: 0.8, py: -0.8,  cr: 0, cg: 0, cb: 1, ca: 1),  // BLUE
]

// --- Metal Setup ---

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device")
    exit(1)
}
print("Device: \(device.name)")

guard let commandQueue = device.makeCommandQueue() else {
    print("ERROR: No command queue")
    exit(1)
}

// Load shaders
let libraryURL = URL(fileURLWithPath: "./Shaders.metallib")
let library: MTLLibrary
do {
    library = try device.makeLibrary(URL: libraryURL)
} catch {
    print("ERROR: \(error)")
    print("Build shaders: xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air && xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib")
    exit(1)
}

guard let vertFunc = library.makeFunction(name: "vertex_main"),
      let fragFunc = library.makeFunction(name: "fragment_main") else {
    print("ERROR: Shader functions not found")
    exit(1)
}

// --- Pipeline ---

let vertexDescriptor = MTLVertexDescriptor()
// position: float2 at offset 0
vertexDescriptor.attributes[0].format = .float2
vertexDescriptor.attributes[0].offset = 0
vertexDescriptor.attributes[0].bufferIndex = 0
// color: float4 at offset 8 (right after float2 position)
vertexDescriptor.attributes[1].format = .float4
vertexDescriptor.attributes[1].offset = 8
vertexDescriptor.attributes[1].bufferIndex = 0
// stride: 6 floats = 24 bytes
vertexDescriptor.layouts[0].stride = 24

let pipelineDesc = MTLRenderPipelineDescriptor()
pipelineDesc.vertexFunction = vertFunc
pipelineDesc.fragmentFunction = fragFunc
pipelineDesc.vertexDescriptor = vertexDescriptor
pipelineDesc.colorAttachments[0].pixelFormat = .rgba8Unorm

let pipeline: MTLRenderPipelineState
do {
    pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
} catch {
    print("ERROR: Pipeline: \(error)")
    exit(1)
}

// --- Vertex Buffer ---

var vertexData = vertices
let vertexBuffer = device.makeBuffer(
    bytes: &vertexData,
    length: 24 * vertices.count,
    options: .storageModeShared
)!
vertexBuffer.label = "Triangle Vertices"

// --- Render Target ---

let texDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm,
    width: WIDTH,
    height: HEIGHT,
    mipmapped: false
)
texDesc.usage = [.renderTarget, .shaderRead]
texDesc.storageMode = .shared

let renderTarget = device.makeTexture(descriptor: texDesc)!
renderTarget.label = "Render Target"

// --- GPU Capture Setup ---

let captureManager = MTLCaptureManager.shared()
let captureEnabled = captureManager.supportsDestination(.gpuTraceDocument)
let captureOutputPath = "./capture.gputrace"

if captureEnabled {
    let fm = FileManager.default
    if fm.fileExists(atPath: captureOutputPath) {
        try? fm.removeItem(atPath: captureOutputPath)
    }
    let captureDesc = MTLCaptureDescriptor()
    captureDesc.captureObject = device
    captureDesc.destination = .gpuTraceDocument
    captureDesc.outputURL = URL(fileURLWithPath: captureOutputPath)
    do {
        try captureManager.startCapture(with: captureDesc)
        print("GPU capture started → \(captureOutputPath)")
    } catch {
        print("Capture failed: \(error)")
    }
}

// --- Render ---

let renderPassDesc = MTLRenderPassDescriptor()
renderPassDesc.colorAttachments[0].texture = renderTarget
renderPassDesc.colorAttachments[0].loadAction = .clear
renderPassDesc.colorAttachments[0].storeAction = .store

renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

guard let commandBuffer = commandQueue.makeCommandBuffer() else {
    print("ERROR: No command buffer")
    exit(1)
}
commandBuffer.label = "Render Frame"

guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
    print("ERROR: No render encoder")
    exit(1)
}
encoder.label = "Triangle Draw"
encoder.setRenderPipelineState(pipeline)
encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
encoder.endEncoding()

// Blit to ensure CPU can read
if let blit = commandBuffer.makeBlitCommandEncoder() {
    blit.label = "Sync to CPU"
    #if os(macOS)
    if renderTarget.storageMode == .managed {
        blit.synchronize(resource: renderTarget)
    }
    #endif
    blit.endEncoding()
}

commandBuffer.commit()
commandBuffer.waitUntilCompleted()

if commandBuffer.status == .error {
    print("GPU ERROR: \(commandBuffer.error?.localizedDescription ?? "unknown")")
}

// Stop capture
if captureEnabled && captureManager.isCapturing {
    captureManager.stopCapture()
    print("GPU capture saved: \(captureOutputPath)")
}

// --- Read Pixels ---

let bytesPerRow = 4 * WIDTH
let pixelCount = WIDTH * HEIGHT
var pixelData = [UInt8](repeating: 0, count: bytesPerRow * HEIGHT)
renderTarget.getBytes(
    &pixelData,
    bytesPerRow: bytesPerRow,
    from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: WIDTH, height: HEIGHT, depth: 1)),
    mipmapLevel: 0
)

// --- Analyze ---

var nonBlackPixels = 0
var totalR: Int = 0, totalG: Int = 0, totalB: Int = 0, totalA: Int = 0
for i in stride(from: 0, to: pixelData.count, by: 4) {
    let r = pixelData[i], g = pixelData[i+1], b = pixelData[i+2], a = pixelData[i+3]
    if r > 0 || g > 0 || b > 0 {
        nonBlackPixels += 1
        totalR += Int(r); totalG += Int(g); totalB += Int(b); totalA += Int(a)
    }
}

print("\nRender results (\(WIDTH)x\(HEIGHT)):")
print("  Non-black pixels: \(nonBlackPixels) / \(pixelCount) (\(String(format: "%.1f", Double(nonBlackPixels) / Double(pixelCount) * 100))%)")
if nonBlackPixels > 0 {
    print("  Avg color: R=\(totalR/nonBlackPixels) G=\(totalG/nonBlackPixels) B=\(totalB/nonBlackPixels) A=\(totalA/nonBlackPixels)")
}

// Check for specific pixel at center-ish where triangle should be
let centerIdx = (HEIGHT / 3 * bytesPerRow) + (WIDTH / 2 * 4)
let cr = pixelData[centerIdx], cg = pixelData[centerIdx+1], cb = pixelData[centerIdx+2], ca = pixelData[centerIdx+3]
print("  Center sample: RGBA(\(cr), \(cg), \(cb), \(ca))")

// Warn about visible issues
if totalA > 0 && totalA / max(nonBlackPixels, 1) < 128 {
    print("  WARNING: Low average alpha — triangle may be transparent!")
}
if nonBlackPixels < pixelCount / 10 {
    print("  WARNING: Very few colored pixels — triangle may be off-screen or degenerate!")
}

// --- Save PNG ---

let outputPath = "./output.png"
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

guard let context = CGContext(
    data: &pixelData,
    width: WIDTH,
    height: HEIGHT,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo.rawValue
) else {
    print("ERROR: Failed to create CGContext")
    exit(1)
}

guard let image = context.makeImage() else {
    print("ERROR: Failed to create CGImage")
    exit(1)
}

let url = URL(fileURLWithPath: outputPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    print("ERROR: Failed to create PNG destination")
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
if CGImageDestinationFinalize(dest) {
    print("\nSaved: \(outputPath)")
} else {
    print("ERROR: Failed to write PNG")
}

print("\nTo debug with Claude:")
print("  METAL_CAPTURE_ENABLED=1 ./visual_demo")
print("  python3 ../../parse_gputrace.py capture.gputrace")
print("  python3 ../../parse_gputrace.py capture.gputrace --buffer 'Triangle Vertices' --layout 'float2,float4' --index 0-2")
