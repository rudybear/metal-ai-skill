// main.swift — Metal cube renderer (windowed)

import Cocoa
import Metal
import MetalKit
import simd

// --- Vertex Data ---

// Packed layout: float3 position + float4 color = 28 bytes, no padding
struct Vertex {
    var px: Float; var py: Float; var pz: Float
    var cr: Float; var cg: Float
    var cb: Float; var ca: Float
}

// --- Uniforms ---

struct Uniforms {
    var mvpMatrix: float4x4
}

// --- Matrix Helpers ---

func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let y = 1.0 / tanf(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
    ))
}

func translationMatrix(_ tx: Float, _ ty: Float, _ tz: Float) -> float4x4 {
    return float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(tx, ty, tz, 1)
    ))
}

func rotationMatrixY(_ angle: Float) -> float4x4 {
    let c = cosf(angle)
    let s = sinf(angle)
    return float4x4(columns: (
        SIMD4<Float>(c, 0, -s, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(s, 0, c, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

func rotationMatrixX(_ angle: Float) -> float4x4 {
    let c = cosf(angle)
    let s = sinf(angle)
    return float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, c, s, 0),
        SIMD4<Float>(0, -s, c, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

// --- Cube Geometry ---

func makeCubeVertices() -> [Vertex] {
    let s: Float = 0.5

    // Per-face colors
    let RED     = (cr: Float(1), cg: Float(0), cb: Float(0), ca: Float(1))
    let GREEN   = (cr: Float(0), cg: Float(1), cb: Float(0), ca: Float(1))
    let BLUE    = (cr: Float(0), cg: Float(0), cb: Float(1), ca: Float(1))
    let YELLOW  = (cr: Float(1), cg: Float(1), cb: Float(0), ca: Float(1))
    let MAGENTA = (cr: Float(1), cg: Float(0), cb: Float(1), ca: Float(1))
    let CYAN    = (cr: Float(0), cg: Float(1), cb: Float(1), ca: Float(1))

    func v(_ px: Float, _ py: Float, _ pz: Float,
           _ c: (cr: Float, cg: Float, cb: Float, ca: Float)) -> Vertex {
        return Vertex(px: px, py: py, pz: pz, cr: c.cr, cg: c.cg, cb: c.cb, ca: c.ca)
    }

    // BUG: Front face vertices 2 and 4 use (0, 0, s) instead of (s, s, s)
    return [
        // Front face (z = +s) — RED
        v(-s, -s,  s, RED), v( s, -s,  s, RED), v( 0,  0,  s, RED),
        v(-s, -s,  s, RED), v( 0,  0,  s, RED), v(-s,  s,  s, RED),

        // Back face (z = -s) — GREEN
        v( s, -s, -s, GREEN), v(-s, -s, -s, GREEN), v(-s,  s, -s, GREEN),
        v( s, -s, -s, GREEN), v(-s,  s, -s, GREEN), v( s,  s, -s, GREEN),

        // Top face (y = +s) — BLUE
        v(-s,  s,  s, BLUE), v( s,  s,  s, BLUE), v( s,  s, -s, BLUE),
        v(-s,  s,  s, BLUE), v( s,  s, -s, BLUE), v(-s,  s, -s, BLUE),

        // Bottom face (y = -s) — YELLOW
        v(-s, -s, -s, YELLOW), v( s, -s, -s, YELLOW), v( s, -s,  s, YELLOW),
        v(-s, -s, -s, YELLOW), v( s, -s,  s, YELLOW), v(-s, -s,  s, YELLOW),

        // Right face (x = +s) — MAGENTA
        v( s, -s,  s, MAGENTA), v( s, -s, -s, MAGENTA), v( s,  s, -s, MAGENTA),
        v( s, -s,  s, MAGENTA), v( s,  s, -s, MAGENTA), v( s,  s,  s, MAGENTA),

        // Left face (x = -s) — CYAN
        v(-s, -s, -s, CYAN), v(-s, -s,  s, CYAN), v(-s,  s,  s, CYAN),
        v(-s, -s, -s, CYAN), v(-s,  s,  s, CYAN), v(-s,  s, -s, CYAN),
    ]
}

// --- Renderer ---

class CubeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let captureManager = MTLCaptureManager.shared()
    let captureMode: Bool
    let screenshotMode: Bool
    let screenshotPath: String
    var frameCount = 0

    init(device: MTLDevice, view: MTKView, captureMode: Bool, screenshotMode: Bool, screenshotPath: String = "./output.png") {
        self.device = device
        self.captureMode = captureMode
        self.screenshotMode = screenshotMode
        self.screenshotPath = screenshotPath
        self.commandQueue = device.makeCommandQueue()!

        let libraryURL = URL(fileURLWithPath: "./Shaders.metallib")
        let library = try! device.makeLibrary(URL: libraryURL)
        let vertFunc = library.makeFunction(name: "vertex_main")!
        let fragFunc = library.makeFunction(name: "fragment_main")!

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float4
        vd.attributes[1].offset = 12
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 28

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vertFunc
        pd.fragmentFunction = fragFunc
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.depthAttachmentPixelFormat = .depth32Float

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pd)

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)!

        let cubeVerts = makeCubeVertices()
        self.vertexCount = cubeVerts.count
        var data = cubeVerts
        self.vertexBuffer = device.makeBuffer(
            bytes: &data, length: 28 * cubeVerts.count,
            options: .storageModeShared
        )!
        self.vertexBuffer.label = "Cube Vertices"

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

        // Build MVP matrix
        let model = rotationMatrixY(0.6) * rotationMatrixX(0.4)
        let view_mat = translationMatrix(0, 0, -3)
        let projection = perspectiveMatrix(fovY: Float.pi / 4.0, aspect: 1.0, near: 0.1, far: 100.0)
        let mvp = projection * view_mat * model
        var uniforms = Uniforms(mvpMatrix: mvp)

        let cb = commandQueue.makeCommandBuffer()!
        cb.label = "Render Frame"

        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.label = "Cube Draw"
        enc.setRenderPipelineState(pipelineState)
        enc.setDepthStencilState(depthStencilState)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
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

        // Save screenshot after a few frames to ensure window is fully rendered
        if frameCount == 3 && screenshotMode {
            cb.waitUntilCompleted()
            Self.saveTexture(drawable.texture, to: screenshotPath)
            print("Screenshot saved: \(screenshotPath)")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }

        frameCount += 1
    }

    static func saveTexture(_ texture: MTLTexture, to path: String) {
        let w = texture.width, h = texture.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1)),
                         mipmapLevel: 0)
        // BGRA → RGBA, force alpha to 255 for screenshot visibility
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let tmp = pixels[i]
            pixels[i] = pixels[i + 2]
            pixels[i + 2] = tmp
            pixels[i + 3] = 255
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: bytesPerRow, bitsPerPixel: 32)!
        memcpy(rep.bitmapData!, &pixels, pixels.count)
        let data = rep.representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: path))
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
let screenshotMode = CommandLine.arguments.contains("--screenshot")

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
window.title = "Metal Cube"
window.center()

let metalView = MTKView(frame: window.contentView!.bounds, device: device)
metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
metalView.colorPixelFormat = .bgra8Unorm
metalView.depthStencilPixelFormat = .depth32Float
metalView.preferredFramesPerSecond = 60
metalView.autoresizingMask = [.width, .height]
if screenshotMode {
    metalView.framebufferOnly = false  // Allow texture readback for screenshots
}

let renderer = CubeRenderer(device: device, view: metalView, captureMode: captureMode, screenshotMode: screenshotMode)
metalView.delegate = renderer

window.contentView = metalView
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
