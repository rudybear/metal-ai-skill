#!/usr/bin/env swift
//
// capture_frame.swift
// Programmatic Metal frame capture using MTLCaptureManager.
//
// Usage:
//   swift capture_frame.swift /path/to/output.gputrace
//
// Prerequisites:
//   - Full Xcode installed
//   - METAL_CAPTURE_ENABLED=1 environment variable set
//     OR MetalCaptureEnabled=true in the target app's Info.plist
//
// This script demonstrates standalone frame capture. In practice,
// integrate MTLCaptureManager into your app for more control.
//

import Foundation
import Metal

// MARK: - Configuration

let outputPath: String
if CommandLine.arguments.count > 1 {
    outputPath = CommandLine.arguments[1]
} else {
    outputPath = "/tmp/metal_capture.gputrace"
}

// MARK: - Setup

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device available")
    exit(1)
}

print("Metal device: \(device.name)")
print("Output: \(outputPath)")

let captureManager = MTLCaptureManager.shared()

guard captureManager.supportsDestination(.gpuTraceDocument) else {
    print("ERROR: GPU trace capture not supported.")
    print("Ensure METAL_CAPTURE_ENABLED=1 is set in environment.")
    exit(1)
}

// MARK: - Capture

let descriptor = MTLCaptureDescriptor()
descriptor.captureObject = device
descriptor.destination = .gpuTraceDocument
descriptor.outputURL = URL(fileURLWithPath: outputPath)

do {
    try captureManager.startCapture(with: descriptor)
    print("Capture started...")
} catch {
    print("ERROR: Failed to start capture: \(error)")
    print("Common fixes:")
    print("  - Set METAL_CAPTURE_ENABLED=1 environment variable")
    print("  - Ensure no other capture is in progress")
    print("  - Delete existing file at output path")
    exit(1)
}

// MARK: - Do GPU Work Here
//
// In a real app, this is where your render loop would execute.
// The capture records all Metal commands between start and stop.
//
// Example: create a command buffer and submit trivial work.

guard let commandQueue = device.makeCommandQueue() else {
    print("ERROR: Failed to create command queue")
    exit(1)
}

if let commandBuffer = commandQueue.makeCommandBuffer() {
    commandBuffer.label = "Capture Frame"

    // Add your render/compute commands here.
    // For this example, we just commit an empty buffer.
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error {
        print("WARNING: Command buffer error: \(error)")
    }
}

// MARK: - Stop Capture

captureManager.stopCapture()
print("Capture saved to: \(outputPath)")
print("Open with: open \(outputPath)")
