import SwiftUI
import MetalKit
import AVFoundation
import CoreImage
import PrettyCore

/// Live preview: pulls frames from the player (or a still generator when paused) and renders
/// them through the exact same Composer the exporter uses.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> PreviewRenderer { PreviewRenderer(model: model) }

    func makeNSView(context: Context) -> MTKView {
        let v = ClickableMTKView(frame: .zero, device: context.coordinator.device)
        v.delegate = context.coordinator
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.layer?.isOpaque = true
        v.onClick = { [weak coord = context.coordinator] p, size in coord?.handleClick(p, viewSize: size) }
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.model = model
        v.isPaused = !model.isPlaying
        v.enableSetNeedsDisplay = !model.isPlaying
        context.coordinator.requestStill()
        v.needsDisplay = true
        _ = model.renderVersion
    }
}

final class ClickableMTKView: MTKView {
    var onClick: ((CGPoint, CGSize) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: p.x, y: bounds.height - p.y), bounds.size)
    }
}

final class PreviewRenderer: NSObject, MTKViewDelegate {
    var model: EditorModel
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    lazy var ci = CIContext(mtlDevice: device, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])
    weak var view: MTKView?
    private var composer: Composer?
    private var composerKey = ""
    private var lastFrame: CIImage?
    private var stillGen: AVAssetImageGenerator?
    private var stillAsset: AVAsset?
    private var pendingStill: Double?
    private var stillInFlight = false
    private var camGrabber: FrameGrabber?
    private var camURL: URL?
    private var lastCamFrame: CIImage?
    private var lastCamFetch = Date.distantPast
    private var contentRect = CGRect.zero

    init(model: EditorModel) { self.model = model }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    @MainActor func requestStill() {
        guard !model.isPlaying else { return }
        pendingStill = model.currentTime
        fetchStill()
    }

    @MainActor private func fetchStill() {
        guard !stillInFlight, let t = pendingStill, let asset = model.compositionAsset else { return }
        if stillAsset !== asset {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
            stillGen = g; stillAsset = asset
        }
        pendingStill = nil
        stillInFlight = true
        let gen = stillGen!
        gen.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 60000)) { [weak self] img, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stillInFlight = false
                if let img { self.lastFrame = CIImage(cgImage: img) }
                self.view?.needsDisplay = true
                MainActor.assumeIsolated { self.fetchStill() }
            }
        }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawMain(view) }
    }

    @MainActor private func drawMain(_ view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 4, size.height > 4 else { return }
        var t = model.currentTime
        if model.isPlaying, let out = model.videoOutput {
            let it = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: it), let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil) {
                lastFrame = CIImage(cvPixelBuffer: pb)
            }
            if it.seconds.isFinite { t = it.seconds }
        }
        // Fit the export canvas into the view.
        let exp = model.exportSettings?.size ?? CGSize(width: 1920, height: 1080)
        let margin: CGFloat = 0
        let target = aspectFit(exp, in: CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)).integral
        let key = "\(Int(target.width))x\(Int(target.height))|\(model.projectVersion)"
        if composer == nil || composerKey != key {
            composer = Composer(studio: model.studio, size: target.size)
            composer?.safeArea = model.exportSettings?.safe ?? [0, 0, 0, 0]
            composerKey = key
        }
        guard let comp = composer else { return }
        contentRect = target
        // Camera bubble frame (throttled while playing).
        var cam: CIImage? = nil
        if let cu = model.studio.cameraURL, model.project.camera.show {
            if camURL != cu { camGrabber = FrameGrabber(url: cu); camURL = cu }
            if !model.isPlaying || Date().timeIntervalSince(lastCamFetch) > 0.08 {
                lastCamFrame = camGrabber?.frame(at: model.studio.map.source(atOutput: t) + model.project.camera.offset)
                lastCamFetch = Date()
            }
            cam = lastCamFrame
        }
        let frame = comp.render(t: t, source: lastFrame, cameraFrame: cam)
        let placed = frame.transformed(by: CGAffineTransform(translationX: target.minX, y: size.height - target.maxY))
        let bg = CIImage(color: CIColor(red: 0.118, green: 0.118, blue: 0.125)).cropped(to: CGRect(origin: .zero, size: size))
        ci.render(placed.composited(over: bg), to: drawable.texture, commandBuffer: cb, bounds: CGRect(origin: .zero, size: size), colorSpace: sRGB)
        cb.present(drawable)
        cb.commit()
    }

    /// Clicking the preview while picking a manual zoom focus sets it.
    @MainActor func handleClick(_ p: CGPoint, viewSize: CGSize) {
        guard model.manualFocusPick, let id = model.selectedZoom, let comp = composer, let v = view else { return }
        let scale = v.drawableSize.width / max(viewSize.width, 1)
        let px = CGPoint(x: p.x * scale - contentRect.minX, y: p.y * scale - contentRect.minY)
        let st = comp.camera.state(at: model.currentTime)
        let W = comp.size.width, H = comp.size.height
        let stage = CGPoint(x: (px.x - W / 2) / st.zoom + st.center.x, y: (px.y - H / 2) / st.zoom + st.center.y)
        let L = comp.layout
        let src = CGPoint(x: (stage.x - L.videoStageRect.minX) / L.contentScale + L.cropOrigin.x,
                          y: (stage.y - L.videoStageRect.minY) / L.contentScale + L.cropOrigin.y)
        let n = NPoint(x: round3(clamp(Double(src.x / model.studio.videoSize.width), 0, 1)),
                       y: round3(clamp(Double(src.y / model.studio.videoSize.height), 0, 1)))
        model.updateZoom(id) { z in z.mode = "manual"; z.focus = n }
        model.manualFocusPick = false
    }
}
