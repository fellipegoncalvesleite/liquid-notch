import AppKit
import SceneKit

/// The AirPods 4 buds in 3D (model: AirPods 4 by Falah3D, sketchfab.com/3dFalah, CC BY 4.0; light: Poly Haven
/// "Studio Small 08", CC0), on AirPane's stage as the sim's `Pods3D` sets it up: one scene, loaded once, rendered
/// offscreen into an image. The ears, the ball and the card all draw that image, so they stay in step and keep
/// SwiftUI's blur, the island's clip and the stills (an `SCNView` would get none of them), and there is only ever one
/// pair in the scene (two loads used to show two pairs, one moving and one standing still behind it).
@MainActor final class BudsStage {
    static let shared = BudsStage()

    /// The sway: the pair faces you and turns about its own vertical axis, never a full turn (owner, 10-31). AirPane's
    /// sin(t·0.55)·0.34 rad barely moved in the ~5 s the moment shows (owner, 11-07: "the airpods aren't spinning"), so
    /// it's ±30° every 4.5 s, eased in over 0.8 s, with AirPane's slight tilt and bob. t = 0 is the front.
    nonisolated static func pose(at t: Double) -> (yaw: Double, pitch: Double, bob: Double) {
        let k = min(1, max(0, t / 0.8)), ramp = k * k * (3 - 2 * k)
        return (sin(t * 1.4) * 0.52 * ramp, sin(t * 0.8) * 0.025 * ramp, sin(t * 1.1) * 0.012 * ramp)
    }

    /// Width over height of every frame (the sim's 150 × 132 stage).
    nonisolated static let aspect = 150.0 / 132.0

    private(set) var isReady = false
    private var failed = false
    private var loading: Task<Void, Never>?
    private var built: Built?
    /// Where the buds sit in every frame at the front (unit rect, top-left origin), measured once.
    private(set) var budsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The last frame drawn at each pixel height: every place asking for the same frame shares one render.
    private var cache: [Int: (t: Double?, image: CGImage)] = [:]
    private var swayStart: Date?, lastAsked: Date?
    /// The sway time of the last moving frame asked for.
    private(set) var swayTime: Double?
    /// Loaded, the stage holds ~100 MB (the model ~40, the studio light ~30): it lets go a minute after the buds were
    /// last drawn, and the next showing loads it again (the cutout, the same front view, stands in meanwhile).
    nonisolated static let keepAlive: TimeInterval = 60
    private var lastUse = Date.distantPast
    private var sweeper: Task<Void, Never>?

    /// Starts the one load off the main thread (a second caller waits for the first).
    func load() async {
        if isReady || failed { return }
        if let loading { await loading.value; return }
        let task = Task { install(await Task.detached(priority: .utility) { Self.build() }.value) }
        loading = task
        await task.value
    }

    /// Loads on the spot, for stills and tests (nothing to wait on there).
    func loadNow() {
        guard !isReady, !failed, loading == nil else { return }
        install(Self.build())
    }

    private func install(_ b: Built?) {
        loading = nil
        guard let b else { failed = true; return }
        built = b
        budsRect = b.budsRect
        isReady = true
        touch()
    }

    /// Lets the scene go (it loads again on the next showing).
    func unload() {
        built = nil
        cache = [:]
        isReady = false
        swayStart = nil
        lastAsked = nil
        sweeper?.cancel()
        sweeper = nil
    }

    private func touch() {
        lastUse = Date()
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastUse) > Self.keepAlive { self.unload(); return }
            }
        }
    }

    /// The models in the scene and the buds shown (the `POD1` check: one model, two buds).
    var models: Int { built?.renderer.scene?.rootNode.childNodes.filter { $0.camera == nil && $0.light == nil }.count ?? 0 }
    var budsShown: Int { built?.content.childNodes.filter { !$0.isHidden }.count ?? 0 }

    /// The frame for a moment of the sway, buds `height` points tall at the front. `date` nil = the front, still.
    /// The sway starts from the front when the buds show again after half a second or more unseen.
    func image(at date: Date?, timeScale: Double = 1, height: Double, scale: Double) -> CGImage? {
        guard let date else { return image(sway: nil, height: height, scale: scale) }
        if swayStart == nil || lastAsked.map({ date.timeIntervalSince($0) > 0.5 }) ?? true { swayStart = date }
        if lastAsked.map({ date > $0 }) ?? true { lastAsked = date }
        let t = max(0, date.timeIntervalSince(swayStart ?? date)) * max(timeScale, 0.05)
        swayTime = t
        return image(sway: t, height: height, scale: scale)
    }

    /// The frame at sway time `t` (nil = the front, still).
    func image(sway t: Double?, height: Double, scale: Double) -> CGImage? {
        guard let b = built else { return nil }
        touch()
        let pixels = max(8, Int((height / budsRect.height * scale).rounded(.up)))
        if let hit = cache[pixels], hit.t == t { return hit.image }
        let p = t.map(Self.pose) ?? (yaw: 0, pitch: 0, bob: 0)
        b.root.eulerAngles = SCNVector3(CGFloat(p.pitch), CGFloat(p.yaw), 0)
        b.root.position = SCNVector3(0, CGFloat(0.06 + p.bob), 0)
        guard let image = b.render(pixels: pixels) else { return nil }
        cache[pixels] = (t, image)
        return image
    }

    // MARK: - Building the stage (off the main thread)

    /// The scene, its renderer and the buds, handed from the loading thread to the main one (never used on both).
    final class Built: @unchecked Sendable {
        let renderer: SCNRenderer
        let root: SCNNode       // turns and bobs; the buds' centre is its origin
        let content: SCNNode    // the model's top-level parts: the two buds shown, the rest hidden
        var budsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        init(renderer: SCNRenderer, root: SCNNode, content: SCNNode) {
            self.renderer = renderer; self.root = root; self.content = content
        }

        func render(pixels: Int) -> CGImage? {
            let size = CGSize(width: (Double(pixels) * BudsStage.aspect).rounded(), height: Double(pixels))
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            var rect = CGRect(origin: .zero, size: size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }

    /// The rig's bud nodes (AirPane's `airpods-4.rig.json`, names from the Sketchfab export).
    nonisolated static let budNames = ["oTgukKFHsbAaGBa", "MSpBhwzeYpJKGDV"]

    nonisolated static func build() -> Built? {
        guard let url = resource("airpods-4", "usdz"),
              let file = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        // AirPane's light: the photographed studio at 1.05 and one key light at (1.5, 4, 2). No shadows: the buds are
        // alone here, as in the sim.
        if let hdr = resource("studio", "hdr") {
            scene.lightingEnvironment.contents = hdr
            scene.lightingEnvironment.intensity = 1.05
        } else {
            let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 900
            let n = SCNNode(); n.light = ambient; scene.rootNode.addChildNode(n)
        }
        let key = SCNLight()
        key.type = .directional
        key.intensity = 500
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(1.5, 4, 2)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)
        // AirPane's camera: 25° from slightly above.
        let camera = SCNCamera()
        camera.fieldOfView = 25
        camera.zNear = 2.4
        camera.zFar = 9
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0.2
        camera.bloomIntensity = 0
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1.35, 4.7)
        cameraNode.look(at: SCNVector3(0, 0.1, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Only the buds: each one is lifted to the top of the model and everything else is hidden (AirPane's `.buds`).
        let content = SCNNode()
        for child in file.rootNode.childNodes { content.addChildNode(child) }
        plasticize(content)
        let buds = budNames.compactMap { content.childNode(withName: $0, recursively: true) }
        guard buds.count == 2 else { return nil }
        for bud in buds {
            let wrapper = SCNNode()
            content.addChildNode(wrapper)
            reparent(bud, to: wrapper)
        }
        let wrappers = Set(buds.compactMap { $0.parent.map(ObjectIdentifier.init) })
        for n in content.childNodes where !wrappers.contains(ObjectIdentifier(n)) { n.isHidden = true }

        // AirPane's bud shot, framed a quarter tighter as in the sim (its stage is small): the pair centred on the
        // root, which turns about its own vertical axis.
        let box = bounds(of: content, in: content)
        let size = SCNVector3(box.max.x - box.min.x, box.max.y - box.min.y, box.max.z - box.min.z)
        guard size.x > 0, size.y > 0 else { return nil }
        let s = min(2.05 / size.x, 1.62 / size.y, 1.9 / max(size.z, 0.001))
        content.position = SCNVector3(-(box.min.x + box.max.x) / 2, -(box.min.y + box.max.y) / 2, -(box.min.z + box.max.z) / 2)
        let root = SCNNode()
        root.addChildNode(content)
        root.scale = SCNVector3(s, s, s)
        root.position = SCNVector3(0, 0.06, 0)
        scene.rootNode.addChildNode(root)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let built = Built(renderer: renderer, root: root, content: content)
        // The first render compiles the shaders here, not on the frame the buds first show; it also measures where
        // the buds sit, so each place can size them by their height as it did the cutout.
        guard let front = built.render(pixels: 300), let rect = opaqueRect(front) else { return nil }
        built.budsRect = rect
        return built
    }

    /// The bounds of the pixels that aren't clear, as a unit rect (top-left origin).
    nonisolated static func opaqueRect(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        return CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                      width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h))
    }

    /// A bundled file, or the source tree's `Resources/` (`swift run`, tests).
    nonisolated static func resource(_ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        let local = URL(fileURLWithPath: devFile()).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    // MARK: - AirPane's stage helpers (Earshot/ModelStage/StageScene.swift)

    /// Bounding box of every visible geometry under `node`, expressed in `space`.
    nonisolated static func bounds(of node: SCNNode, in space: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        var lo = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        func visit(_ n: SCNNode) {
            guard !n.isHidden else { return }
            if let g = n.geometry {
                let (a, b) = g.boundingBox
                for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                    let p = n.convertPosition(SCNVector3(x, y, z), to: space)
                    lo = SCNVector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                    hi = SCNVector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                } } }
            }
            n.childNodes.forEach(visit)
        }
        visit(node)
        if lo.x > hi.x { return (SCNVector3Zero, SCNVector3Zero) }
        return (lo, hi)
    }

    nonisolated static func reparent(_ node: SCNNode, to parent: SCNNode) {
        let world = node.worldTransform
        node.removeFromParentNode()
        parent.addChildNode(node)
        node.transform = parent.convertTransform(world, from: nil)
    }

    /// Apple's white plastic: a satin base under a thin clear gloss. Exports often arrive as a near-mirror
    /// (roughness ≈ 0.05), which blows out to flat white under studio light.
    nonisolated static func plasticize(_ node: SCNNode) {
        node.enumerateHierarchy { n, _ in
            for m in n.geometry?.materials ?? [] {
                m.lightingModel = .physicallyBased
                if m.normal.contents != nil { m.normal.intensity = 0.6 }
                // Skip glowing parts (the status light); "black" emission arrives in assorted colour spaces.
                if let e = m.emission.contents {
                    if let c = (e as? NSColor)?.usingColorSpace(.deviceRGB) { if c.brightnessComponent > 0.02 { continue } } else { continue }
                }
                let raw = m.diffuse.contents
                let color: NSColor? = (raw as? NSColor) ?? {
                    guard let raw, CFGetTypeID(raw as CFTypeRef) == CGColor.typeID else { return nil }
                    return NSColor(cgColor: raw as! CGColor)
                }()
                if let c = color?.usingColorSpace(.deviceRGB), c.brightnessComponent > 0.6 {
                    m.diffuse.contents = NSColor(white: 0.92 * c.brightnessComponent, alpha: c.alphaComponent)
                    m.roughness.contents = 0.42
                    m.metalness.contents = 0.0
                    m.clearCoat.contents = 0.65
                    m.clearCoatRoughness.contents = 0.12
                } else if let r = m.roughness.contents as? NSNumber, r.doubleValue < 0.2 {
                    // Near-mirror chrome and gloss read as CG at card size.
                    m.roughness.contents = (m.metalness.contents as? NSNumber).map { $0.doubleValue > 0.5 ? 0.3 : 0.32 } ?? 0.32
                }
            }
        }
    }
}
