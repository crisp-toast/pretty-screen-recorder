import Foundation
import CoreGraphics

/// Where everything sits on the output canvas ("stage"), in output pixels, top-left origin.
public struct StageLayout {
    public let outputSize: CGSize
    public let frame: FrameGeometry
    /// The framed recording (frame.outerSize scaled) placed on the stage.
    public let framedRect: CGRect
    /// Stage pixels per frame-space pixel.
    public let scale: CGFloat
    /// The source video's rect on the stage.
    public let videoStageRect: CGRect
    /// The device screen / viewport rect on the stage.
    public let screenStageRect: CGRect
    /// Source video size after crop.
    public let videoSize: CGSize
    /// Crop origin in source pixels (events are offset by this).
    public let cropOrigin: CGPoint
    /// 1 for contain; >1 when `fit: cover` needs the camera pushed in to fill the frame.
    public let baseZoom: CGFloat
    /// The region the camera must keep in view.
    public let cameraBounds: CGRect
    public let cover: Bool

    public init(outputSize: CGSize, frame: FrameGeometry, layout: LayoutSpec, videoSize: CGSize, cropOrigin: CGPoint) {
        self.outputSize = outputSize
        self.frame = frame
        self.videoSize = videoSize
        self.cropOrigin = cropOrigin
        let W = outputSize.width, H = outputSize.height
        let pad = CGFloat(clamp(layout.padding, 0, 0.45)) * min(W, H)
        let head = CGFloat(clamp(layout.headroom, 0, 0.6)) * H, foot = CGFloat(clamp(layout.footroom, 0, 0.6)) * H
        var avail = CGRect(x: pad, y: pad + head, width: W - pad * 2, height: max(H * 0.1, H - pad * 2 - head - foot))
        let sc = CGFloat(clamp(layout.scale, 0.1, 3))
        avail = avail.insetBy(dx: avail.width * (1 - sc) / 2, dy: avail.height * (1 - sc) / 2)
        var fr = aspectFit(frame.outerSize, in: avail)
        fr.origin.x += CGFloat(layout.offsetX) * W
        fr.origin.y += CGFloat(layout.offsetY) * H
        framedRect = fr
        scale = fr.width / max(frame.outerSize.width, 1)
        videoStageRect = CGRect(x: fr.minX + frame.videoRect.minX * scale, y: fr.minY + frame.videoRect.minY * scale,
                                width: frame.videoRect.width * scale, height: frame.videoRect.height * scale)
        screenStageRect = CGRect(x: fr.minX + frame.screenRect.minX * scale, y: fr.minY + frame.screenRect.minY * scale,
                                 width: frame.screenRect.width * scale, height: frame.screenRect.height * scale)
        cover = layout.fit == "cover"
        if cover {
            baseZoom = max(1, max(W / videoStageRect.width, H / videoStageRect.height) * 1.0005)
            cameraBounds = videoStageRect
        } else {
            baseZoom = 1
            cameraBounds = CGRect(origin: .zero, size: outputSize)
        }
    }

    /// Source-video pixel → stage pixel.
    public func stagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: videoStageRect.minX + (p.x - cropOrigin.x) / videoSize.width * videoStageRect.width,
                y: videoStageRect.minY + (p.y - cropOrigin.y) / videoSize.height * videoStageRect.height)
    }

    /// Normalized source point (0-1 of the uncropped video) → stage pixel.
    public func stagePoint(normalized n: NPoint, fullSize: CGSize) -> CGPoint {
        stagePoint(CGPoint(x: n.x * fullSize.width, y: n.y * fullSize.height))
    }

    public func stageRect(normalized r: NRect, fullSize: CGSize) -> CGRect {
        let a = stagePoint(CGPoint(x: r.x * fullSize.width, y: r.y * fullSize.height))
        let b = stagePoint(CGPoint(x: (r.x + r.w) * fullSize.width, y: (r.y + r.h) * fullSize.height))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Stage pixels per source pixel.
    public var contentScale: CGFloat { videoStageRect.width / max(videoSize.width, 1) }
}
