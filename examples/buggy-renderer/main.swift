// main.swift — Buggy Metal host code for testing metal-ai-skill
//
// This file contains INTENTIONAL BUGS for Claude Code to find and fix.
// There are 5 host-side issues planted in this file.
//
// Build & run:
//   xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
//   xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib
//   swiftc -framework Metal -framework CoreGraphics main.swift -o buggy_renderer
//   ./buggy_renderer
//

import Foundation
import Metal

// ============================================================
// HOST-SIDE BUGS:
//
// BUG 6: Buffer too small — energyBuffer allocated for (particleCount / 2)
//         instead of particleCount, causing GPU write OOB.
//
// BUG 7: Threadgroup size not checked against device max —
//         hardcoded to 512 which may exceed device limits on some GPUs,
//         AND dispatch doesn't round up, missing trailing particles.
//
// BUG 8: Redundant dispatch loop — runs the simulation kernel 200 times
//         per "frame" when the user only needs 1 step per frame.
//         Wastes massive GPU time, will dominate xctrace profile.
//
// BUG 9: Reads buffer before waitUntilCompleted — race condition
//         where CPU reads GPU results before the command buffer finishes.
//
// BUG 10: No error handling on command buffer — if the GPU faults,
//          the error is silently ignored. Should check .error after completion.
// ============================================================

let PARTICLE_COUNT: Int = 10000
let FRAME_COUNT: Int = 5

// --- Setup ---

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device available")
    exit(1)
}
print("Metal device: \(device.name)")
print("Max threads per threadgroup: \(device.maxThreadsPerThreadgroup)")

guard let commandQueue = device.makeCommandQueue() else {
    print("ERROR: Failed to create command queue")
    exit(1)
}

// Load shader library
let libraryURL = URL(fileURLWithPath: "./Shaders.metallib")
let library: MTLLibrary
do {
    library = try device.makeLibrary(URL: libraryURL)
} catch {
    print("ERROR: Failed to load Shaders.metallib: \(error)")
    print("Build shaders first:")
    print("  xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air")
    print("  xcrun -sdk macosx metallib Shaders.air -o Shaders.metallib")
    exit(1)
}

// Create pipeline states
func makePipeline(_ name: String) -> MTLComputePipelineState {
    guard let function = library.makeFunction(name: name) else {
        print("ERROR: Function '\(name)' not found in shader library")
        exit(1)
    }
    do {
        return try device.makeComputePipelineState(function: function)
    } catch {
        print("ERROR: Failed to create pipeline for '\(name)': \(error)")
        exit(1)
    }
}

let simulatePipeline   = makePipeline("particle_simulate")
let postprocessPipeline = makePipeline("color_postprocess")
let blurPipeline       = makePipeline("energy_blur")

// --- Structures (must match shader) ---

struct Particle {
    var position: SIMD4<Float>  // xyz = position, w = mass
    var velocity: SIMD4<Float>  // xyz = velocity, w = lifetime
    var color: SIMD4<Float>     // rgba
}

struct SimParams {
    var particleCount: UInt32
    var deltaTime: Float
    var damping: Float
    var gravity: Float
}

// --- Create Buffers ---

// Initialize particles with random positions and colors
var particles = [Particle]()
for i in 0..<PARTICLE_COUNT {
    let angle = Float(i) / Float(PARTICLE_COUNT) * 2.0 * Float.pi
    let radius = Float.random(in: 0.1...2.0)
    let p = Particle(
        position: SIMD4<Float>(cos(angle) * radius,
                               Float.random(in: -1...1),
                               sin(angle) * radius,
                               Float.random(in: 0.5...5.0)),  // mass
        velocity: SIMD4<Float>(Float.random(in: -0.5...0.5),
                               Float.random(in: 0...2.0),
                               Float.random(in: -0.5...0.5),
                               Float.random(in: 1.0...5.0)),  // lifetime
        color:    SIMD4<Float>(Float.random(in: 0...1),
                               Float.random(in: 0...1),
                               Float.random(in: 0...1),
                               1.0)
    )
    particles.append(p)
}

let particleBufferSize = MemoryLayout<Particle>.stride * PARTICLE_COUNT
guard let particleBuffer = device.makeBuffer(
    bytes: &particles,
    length: particleBufferSize,
    options: .storageModeShared
) else {
    print("ERROR: Failed to create particle buffer")
    exit(1)
}
particleBuffer.label = "Particle Buffer"

var params = SimParams(
    particleCount: UInt32(PARTICLE_COUNT),
    deltaTime: 0.016,  // ~60fps
    damping: 0.99,
    gravity: 9.8
)
guard let paramsBuffer = device.makeBuffer(
    bytes: &params,
    length: MemoryLayout<SimParams>.stride,
    options: .storageModeShared
) else {
    print("ERROR: Failed to create params buffer")
    exit(1)
}
paramsBuffer.label = "SimParams Buffer"

// BUG 6: Energy buffer is half the required size!
// Should be: MemoryLayout<Float>.stride * PARTICLE_COUNT
// Actual:    MemoryLayout<Float>.stride * (PARTICLE_COUNT / 2)
// The GPU will write past the end of this buffer.
let energyBufferSize = MemoryLayout<Float>.stride * PARTICLE_COUNT  // BUG 6: FIXED — full size
guard let energyBuffer = device.makeBuffer(
    length: energyBufferSize,
    options: .storageModeShared
) else {
    print("ERROR: Failed to create energy buffer")
    exit(1)
}
energyBuffer.label = "Energy Buffer"

let energyOutBufferSize = MemoryLayout<Float>.stride * PARTICLE_COUNT
guard let energyOutBuffer = device.makeBuffer(
    length: energyOutBufferSize,
    options: .storageModeShared
) else {
    print("ERROR: Failed to create energy output buffer")
    exit(1)
}
energyOutBuffer.label = "Energy Output Buffer"

let colorOutBufferSize = MemoryLayout<SIMD4<Float>>.stride * PARTICLE_COUNT
guard let colorOutBuffer = device.makeBuffer(
    length: colorOutBufferSize,
    options: .storageModeShared
) else {
    print("ERROR: Failed to create color output buffer")
    exit(1)
}
colorOutBuffer.label = "Color Output Buffer"

// --- Dispatch Helpers ---

// BUG 7: FIXED — query pipeline for max threadgroup size and round up dispatch
let maxThreads = simulatePipeline.maxTotalThreadsPerThreadgroup
let threadsPerGroup = MTLSize(width: min(maxThreads, 256), height: 1, depth: 1)
let threadgroupCount = MTLSize(
    width: (PARTICLE_COUNT + threadsPerGroup.width - 1) / threadsPerGroup.width,
    height: 1,
    depth: 1
)

// --- GPU Capture Setup ---
// When METAL_CAPTURE_ENABLED=1 is set, capture the last frame to .gputrace
// Usage: METAL_CAPTURE_ENABLED=1 ./buggy_renderer
//        open ./capture.gputrace

let captureManager = MTLCaptureManager.shared()
let captureEnabled = captureManager.supportsDestination(.gpuTraceDocument)
let captureOutputPath = "./capture.gputrace"

if captureEnabled {
    print("GPU trace capture available — will capture last frame to \(captureOutputPath)")
} else if ProcessInfo.processInfo.environment["METAL_CAPTURE_ENABLED"] != nil {
    print("WARNING: METAL_CAPTURE_ENABLED is set but .gpuTraceDocument not supported")
}

// --- Simulation Loop ---

print("Running \(FRAME_COUNT) frames with \(PARTICLE_COUNT) particles...")
print("Threadgroups: \(threadgroupCount.width) x \(threadsPerGroup.width) = \(threadgroupCount.width * threadsPerGroup.width) threads")
print("Particles: \(PARTICLE_COUNT)")
if threadgroupCount.width * threadsPerGroup.width < PARTICLE_COUNT {
    // This warning exists but the bug is NOT fixed
    print("WARNING: Only \(threadgroupCount.width * threadsPerGroup.width) of \(PARTICLE_COUNT) particles will be processed!")
}

let startTime = CFAbsoluteTimeGetCurrent()

for frame in 0..<FRAME_COUNT {
    // Start GPU capture on the last frame
    let isLastFrame = (frame == FRAME_COUNT - 1)
    if isLastFrame && captureEnabled {
        // Remove old capture if it exists
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: captureOutputPath) {
            try? fileManager.removeItem(atPath: captureOutputPath)
        }

        let captureDescriptor = MTLCaptureDescriptor()
        captureDescriptor.captureObject = device
        captureDescriptor.destination = .gpuTraceDocument
        captureDescriptor.outputURL = URL(fileURLWithPath: captureOutputPath)
        do {
            try captureManager.startCapture(with: captureDescriptor)
            print("\nCapturing frame \(frame) to \(captureOutputPath)...")
        } catch {
            print("WARNING: Failed to start capture: \(error)")
        }
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        print("ERROR: Failed to create command buffer for frame \(frame)")
        continue
    }
    commandBuffer.label = "Frame \(frame)"

    // BUG 8: FIXED — dispatch simulation kernel once per frame
    if let encoder = commandBuffer.makeComputeCommandEncoder() {
        encoder.label = "Particle Simulate"
        encoder.setComputePipelineState(simulatePipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.setBuffer(energyBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    // Color post-process (once)
    if let encoder = commandBuffer.makeComputeCommandEncoder() {
        encoder.label = "Color Post-Process"
        encoder.setComputePipelineState(postprocessPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorOutBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    // Energy blur (once)
    if let encoder = commandBuffer.makeComputeCommandEncoder() {
        encoder.label = "Energy Blur"
        encoder.setComputePipelineState(blurPipeline)
        encoder.setBuffer(energyBuffer, offset: 0, index: 0)   // BUG 6: reads from undersized buffer
        encoder.setBuffer(energyOutBuffer, offset: 0, index: 1)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    // BUG 9: FIXED — commit and wait BEFORE reading results
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // BUG 10: FIXED — check for GPU errors after completion
    if commandBuffer.status == .error {
        print("GPU ERROR in frame \(frame): \(commandBuffer.error?.localizedDescription ?? "unknown")")
    }

    // Stop GPU capture after the last frame
    if isLastFrame && captureEnabled && captureManager.isCapturing {
        captureManager.stopCapture()
        print("GPU trace saved to: \(captureOutputPath)")
        print("Open with: open \(captureOutputPath)")
    }

    // Now safe to read GPU results
    let energyPtr = energyOutBuffer.contents().bindMemory(
        to: Float.self, capacity: PARTICLE_COUNT
    )
    var totalEnergy: Float = 0
    for i in 0..<min(100, PARTICLE_COUNT) {
        totalEnergy += energyPtr[i]
    }

    let colorPtr = colorOutBuffer.contents().bindMemory(
        to: SIMD4<Float>.self, capacity: PARTICLE_COUNT
    )
    let sampleColor = colorPtr[0]

    print("Frame \(frame): energy=\(String(format: "%.2f", totalEnergy)) " +
          "sample_color=(\(String(format: "%.3f", sampleColor.x)), " +
          "\(String(format: "%.3f", sampleColor.y)), " +
          "\(String(format: "%.3f", sampleColor.z)), " +
          "\(String(format: "%.3f", sampleColor.w)))")
}

let elapsed = CFAbsoluteTimeGetCurrent() - startTime
print("\nCompleted \(FRAME_COUNT) frames in \(String(format: "%.3f", elapsed))s")
print("Average: \(String(format: "%.1f", elapsed / Double(FRAME_COUNT) * 1000))ms/frame")

// Final validation: check if colors look correct
let finalColors = colorOutBuffer.contents().bindMemory(
    to: SIMD4<Float>.self, capacity: PARTICLE_COUNT
)
var brightCount = 0
var darkCount = 0
for i in 0..<PARTICLE_COUNT {
    let luminance = finalColors[i].x * 0.299 + finalColors[i].y * 0.587 + finalColors[i].z * 0.114
    if luminance > 0.8 { brightCount += 1 }
    if luminance < 0.1 { darkCount += 1 }
}
print("\nColor distribution: \(brightCount) bright, \(darkCount) dark, \(PARTICLE_COUNT - brightCount - darkCount) mid")
if brightCount > PARTICLE_COUNT / 2 {
    print("WARNING: Over 50% of particles are very bright — possible gamma/tonemapping issue")
}

print("\nDone. Run with MTL_DEBUG_LAYER=1 to check for API errors.")
print("Profile with: xcrun xctrace record --template 'Metal System Trace' --time-limit 10s --output trace.trace --launch -- ./buggy_renderer")
