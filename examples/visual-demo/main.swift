// main.swift — Metal triangle renderer (windowed)

import Cocoa
import Metal
import MetalKit

// --- Vertex Data ---

// Packed layout: float2 position + float4 color = 24 bytes, no padding
struct Vertex {
    var px: Float; var py: Float
    var cr: Float; var cg: Float
    var cb: Float; var ca: Float
}

let vertices: [Vertex] = [
    Vertex(px: 0.9, py: 0.8,   cr: 1, cg: 0, cb: 0, ca: 1),  // RED
    Vertex(px: -0.8, py: -0.8, cr: 0, cg: 1, cb: 0, ca: 1),  // GREEN
    Vertex(px: 0.8, py: -0.8,  cr: 0, cg: 0, cb: 1, ca: 1),  // BLUE
]

// --- Renderer ---

class TriangleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let captureManager = MTLCaptureManager.shared()
    let captureMode: Bool
    var frameCount = 0

    init(device: MTLDevice, view: MTKView, captureMode: Bool) {
        self.device = device
        self.captureMode = captureMode
        self.commandQueue = device.makeCommandQueue()!

        let libraryURL = URL(fileURLWithPath: "./Shaders.metallib")
        let library = try! device.makeLibrary(URL: libraryURL)
        let vertFunc = library.makeFunction(name: "vertex_main")!
        let fragFunc = library.makeFunction(name: "fragment_main")!

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float4
        vd.attributes[1].offset = 8
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 24

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vertFunc
        pd.fragmentFunction = fragFunc
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pd)

        var data = vertices
        self.vertexBuffer = device.makeBuffer(
            bytes: &data, length: 24 * vertices.count,
            options: .storageModeShared
        )!
        self.vertexBuffer.label = "Triangle Vertices"

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        // Capture first frame if METAL_CAPTURE_ENABLED=1
        if frameCount == 0 && captureManager.supportsDestination(.gpuTraceDocument) {
            let path = "./capture.gputrace"
            let fm = FileManager.default
            if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
            let cd = MTLCaptureDescriptor()
            cd.captureObject = device
            cd.destination = .gpuTraceDocument
            cd.outputURL = URL(fileURLWithPath: path)
            do {
                try captureManager.startCapture(with: cd)
                print("GPU capture started → \(path)")
            } catch {
                print("Capture failed: \(error)")
            }
        }

        let cb = commandQueue.makeCommandBuffer()!
        cb.label = "Render Frame"

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.label = "Triangle Draw"
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()

        // Stop capture after first frame
        if frameCount == 0 && captureManager.isCapturing {
            cb.waitUntilCompleted()
            captureManager.stopCapture()
            print("GPU capture saved: ./capture.gputrace")
            if captureMode {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }

        frameCount += 1
    }
}

// --- App Delegate ---

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return true
    }
}

// --- Main ---

let captureMode = CommandLine.arguments.contains("--capture")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: No Metal device")
    exit(1)
}
print("Device: \(device.name)")

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 512, height: 512),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "Metal Triangle"
window.center()

let metalView = MTKView(frame: window.contentView!.bounds, device: device)
metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
metalView.colorPixelFormat = .bgra8Unorm
metalView.preferredFramesPerSecond = 60
metalView.autoresizingMask = [.width, .height]

let renderer = TriangleRenderer(device: device, view: metalView, captureMode: captureMode)
metalView.delegate = renderer

window.contentView = metalView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
