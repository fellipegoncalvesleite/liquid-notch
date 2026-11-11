import AppKit
import SwiftUI

/// Picture in picture for a video watched in the island (owner, 11-11: "let people move it around as a picture in
/// picture"): its own floating window, dragged anywhere by its picture, resized from its edges at 16:9, above other
/// windows on every Space (fullscreen ones too). Hovering it shows × and a button back into the island. It never takes
/// focus from the app you're in.
@MainActor
final class VideoPiP {
    private var panel: NSPanel?
    var onClose: (() -> Void)?
    var onBackToIsland: (() -> Void)?

    var isShown: Bool { panel?.isVisible == true }

    func show(layer: CALayer, aspect: Double) {
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: PiPContent(layer: layer, close: { [weak self] in self?.onClose?() },
                                                      back: { [weak self] in self?.onBackToIsland?() }))
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.contentAspectRatio = NSSize(width: aspect, height: 1)
        if !p.isVisible, let screen = NSScreen.main {
            // Top right, under the menu bar, like the system's own picture in picture.
            let w = 448.0, h = (w / aspect).rounded(), v = screen.visibleFrame
            p.setFrame(NSRect(x: v.maxX - w - 20, y: v.maxY - h - 20, width: w, height: h), display: false)
        }
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 448, height: 252),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.minSize = NSSize(width: 240, height: 135)
        p.isReleasedWhenClosed = false
        return p
    }
}

private struct PiPContent: View {
    let layer: CALayer
    let close: () -> Void
    let back: () -> Void
    @State private var over = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PiPLayerView(layer: layer)
            HStack(spacing: 8) {
                button("xmark", "Close", close)
                Spacer()
                button("pip.exit", "Back to the island", back)
            }
            .padding(10)
            .opacity(over ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: over)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { over = $0 }
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The mirror's layer, moved into the window (a layer has one parent: the island's view lets go of it first).
private struct PiPLayerView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        layer.removeFromSuperlayer()
        v.layer?.addSublayer(layer)
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { layer.frame = v.bounds }
}
