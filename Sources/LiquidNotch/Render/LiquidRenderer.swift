import AppKit
import Metal
import QuartzCore

enum RenderError: Error, CustomStringConvertible {
    case noDevice, shaderNotFound, pipeline(String)

    var description: String {
        switch self {
        case .noDevice: "No Metal device"
        case .shaderNotFound: "LiquidShape.metal not found in the bundle or the source tree"
        case .pipeline(let m): "Shader pipeline failed: \(m)"
        }
    }
}

/// Owns the Metal pipeline for the liquid surface. Draws into a layer's drawable
/// (the app) or into an offscreen texture (snapshots).
@MainActor
final class LiquidRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.queue = queue

        // Compiled from source at launch (~tens of ms, once). Precompiling needs the
        // separately downloaded Metal Toolchain, which a contributor may not have;
        // runtime compilation keeps `swift build` + `build_app.sh` the whole setup.
        let source = try String(contentsOf: Self.shaderURL(), encoding: .utf8)
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "liquid_vertex")
            desc.fragmentFunction = library.makeFunction(name: "liquid_fragment")
            desc.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RenderError.pipeline("\(error)")
        }
    }

    private static func shaderURL() throws -> URL {
        if let url = Bundle.main.url(forResource: "LiquidShape", withExtension: "metal") { return url }
        // `swift run` from the source tree.
        let local = URL(fileURLWithPath: devFile()).deletingLastPathComponent()
            .appendingPathComponent("LiquidShape.metal")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        throw RenderError.shaderNotFound
    }

    func encode(into texture: MTLTexture, uniforms: ShapeUniforms, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<ShapeUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The layer presents with the transaction, so the drawable joins the Core Animation commit that carries the
    /// content's frame: the shape and its text land on screen together (the sim's canvas and HTML do).
    func draw(to layer: CAMetalLayer, uniforms: ShapeUniforms) {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, uniforms: uniforms, commandBuffer: cb)
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
    }

    /// Renders one frame offscreen and returns BGRA premultiplied bytes.
    func renderOffscreen(width: Int, height: Int, uniforms: ShapeUniforms) -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else { return [] }
        encode(into: tex, uniforms: uniforms, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }
}

/// Layer-hosting view whose layer is the liquid surface.
@MainActor
final class LiquidView: NSView {
    let metalLayer = CAMetalLayer()
    private let renderer: LiquidRenderer

    init(renderer: LiquidRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = LiquidRenderer.pixelFormat
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Draw on demand: the frame clock decides when.
        metalLayer.needsDisplayOnBoundsChange = false
        // In step with the SwiftUI content above it (11-06 polish: the content could trail the shape by a frame).
        metalLayer.presentsWithTransaction = true
        layer = metalLayer
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func draw(_ uniforms: ShapeUniforms) {
        renderer.draw(to: metalLayer, uniforms: uniforms)
    }
}
