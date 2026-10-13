import SwiftUI
import PrettyCore

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var scale: CGFloat = 1
    @State private var hoverX: CGFloat?

    let rulerH: CGFloat = 26, zoomH: CGFloat = 30, clipH: CGFloat = 54, gap: CGFloat = 8, inset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - inset * 2, 100) * scale
            ScrollView(.horizontal, showsIndicators: scale > 1) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: width + inset * 2, height: geo.size.height)
                    ruler(width: width)
                        .offset(x: inset)
                    zoomTrack(width: width)
                        .offset(x: inset, y: rulerH + gap)
                    clipTrack(width: width)
                        .offset(x: inset, y: rulerH + gap + zoomH + gap)
                    playhead(width: width, height: rulerH + gap * 2 + zoomH + clipH + 6)
                        .offset(x: inset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $scale, in: 1...8).frame(width: 90).controlSize(.mini)
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(6)
            }
        }
    }

    func x(_ t: Double, _ width: CGFloat) -> CGFloat { CGFloat(t / max(model.duration, 0.001)) * width }
    func t(_ x: CGFloat, _ width: CGFloat) -> Double { clamp(Double(x / width) * model.duration, 0, model.duration) }

    // MARK: Ruler

    func ruler(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let d = model.duration
            guard d > 0 else { return }
            let pxPerSec = width / CGFloat(d)
            let step: Double = pxPerSec > 160 ? 0.5 : pxPerSec > 70 ? 1 : pxPerSec > 30 ? 2 : pxPerSec > 12 ? 5 : 10
            var s = 0.0
            while s <= d + 0.001 {
                let xx = x(s, width)
                var p = Path(); p.move(to: CGPoint(x: xx, y: 18)); p.addLine(to: CGPoint(x: xx, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 1)
                let label = String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) + (step < 1 && s.truncatingRemainder(dividingBy: 1) != 0 ? ".5" : "")
                ctx.draw(Text(label).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.5)),
                         at: CGPoint(x: xx + 2, y: 7), anchor: .topLeading)
                s += step
            }
        }
        .frame(width: width, height: rulerH)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.seek(to: t(v.location.x, width)) })
    }

    // MARK: Zoom track

    func zoomTrack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045))
                .frame(width: width, height: zoomH)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                    model.addZoom(atOutput: t(p.x, width))
                }
                .contextMenu {
                    Button("Regenerate Smart Zooms") { model.regenerateZooms() }
                    Button("Clear All Zooms", role: .destructive) { model.project.zoom.segments = []; model.selectedZoom = nil }
                }
            ForEach(model.project.zoom.segments, id: \.id) { z in
                if let r = model.studio.map.outputRanges(source: z.start, z.end).first {
                    ZoomBlock(model: model, zoom: z, start: r.0, end: r.1, width: width, height: zoomH)
                }
            }
        }
        .frame(width: width, height: zoomH, alignment: .topLeading)
    }

    // MARK: Clip track

    func clipTrack(width: CGFloat) -> some View {
        let pieces = model.pieces
        return ZStack(alignment: .topLeading) {
            // Filmstrip
            Canvas { ctx, size in
                let thumbs = model.thumbnails
                guard !thumbs.isEmpty else {
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22))); return
                }
                let aspect = CGFloat(thumbs[0].width) / CGFloat(max(thumbs[0].height, 1))
                let tw = max(size.height * aspect, 20)
                var xx: CGFloat = 0
                while xx < size.width {
                    // Thumbnail for this position (map output → source).
                    let s = model.studio.map.source(atOutput: t(xx + tw / 2, width))
                    let i = clamp(Int(s / max(model.studio.sourceDuration, 0.001) * Double(thumbs.count)), 0, thumbs.count - 1)
                    ctx.draw(Image(decorative: thumbs[i], scale: 1), in: CGRect(x: xx, y: 0, width: tw, height: size.height))
                    xx += tw
                }
            }
            .frame(width: width, height: clipH)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Pieces (between splits) — selectable for deletion.
            ForEach(Array(pieces.enumerated()), id: \.offset) { i, p in
                let a = x(model.studio.map.output(atSource: p.0), width), b = x(model.studio.map.output(atSource: p.1), width)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(model.selectedPiece == i ? Color.accentColor : Color.white.opacity(pieces.count > 1 ? 0.25 : 0.0),
                                  lineWidth: model.selectedPiece == i ? 3 : 1)
                    .background(model.selectedPiece == i ? Color.accentColor.opacity(0.15) : Color.clear)
                    .frame(width: max(b - a - 2, 2), height: clipH)
                    .offset(x: a + 1)
                    .allowsHitTesting(false)
            }
            // Cut boundaries in the output (where removed content was).
            ForEach(Array(model.studio.map.cutPoints.enumerated()), id: \.offset) { _, c in
                Rectangle().fill(Color.orange.opacity(0.9)).frame(width: 2, height: clipH + 6).offset(x: x(c, width) - 1, y: -3)
            }
            if model.bladeMode, let hx = hoverX {
                Rectangle().fill(Color.red).frame(width: 1.5, height: clipH + 10).offset(x: hx, y: -5).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: clipH, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            let tt = t(p.x, width)
            if model.bladeMode { model.split(atOutput: tt); return }
            let s = model.studio.map.source(atOutput: tt)
            if pieces.count > 1, let i = pieces.firstIndex(where: { s >= $0.0 && s <= $0.1 }) {
                model.selectedPiece = model.selectedPiece == i ? nil : i
                model.selectedZoom = nil
            }
            model.seek(to: tt)
        }
        .contextMenu {
            Button("Split at Playhead  ⌘B") { model.splitAtPlayhead() }
            if let p = model.selectedPiece { Button("Delete Selected Piece") { model.cutPiece(p) } }
            Button("Compress Idle Time") { model.compressIdle() }
            Button("Restore All Cuts") { model.resetCuts() }
        }
    }

    // MARK: Playhead

    func playhead(width: CGFloat, height: CGFloat) -> some View {
        let px = x(model.currentTime, width)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 1.5, height: height)
            Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 9, height: 9).offset(y: 14)
        }
        .frame(width: 14, height: height)
        .contentShape(Rectangle())
        .offset(x: px - 7)
        .gesture(DragGesture().onChanged { v in model.seek(to: t(px + v.translation.width, width)) })
    }
}

struct ZoomBlock: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment
    let start: Double, end: Double, width: CGFloat, height: CGFloat
    @State private var dragStart: CGFloat = 0
    @State private var dragEnd: CGFloat = 0

    var body: some View {
        let d = max(model.duration, 0.001)
        let a = CGFloat(start / d) * width + dragStart, b = CGFloat(end / d) * width + dragEnd
        let selected = model.selectedZoom == zoom.id
        let label = "Zoom \(Int((zoom.level * 100).rounded()))%" + (zoom.mode == "manual" ? " · Manual" : "")
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor : Color(white: 0.33))
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).padding(.horizontal, 6)
            HStack {
                handle(left: true, a: a, b: b)
                Spacer()
                handle(left: false, a: a, b: b)
            }
        }
        .frame(width: max(b - a, 12), height: height)
        .offset(x: a)
        .onTapGesture { model.selectedZoom = zoom.id; model.selectedPiece = nil }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            dragStart = v.translation.width; dragEnd = v.translation.width
        }.onEnded { v in
            commit(da: v.translation.width, db: v.translation.width)
        })
        .contextMenu {
            Button("Follow Cursor") { model.updateZoom(zoom.id) { $0.mode = "follow" } }
            Button("Manual (click preview to set focus)") { model.selectedZoom = zoom.id; model.manualFocusPick = true }
            Divider()
            Button("Delete Zoom", role: .destructive) { model.project.zoom.segments.removeAll { $0.id == zoom.id }; model.selectedZoom = nil }
            Button("Clear All Zooms", role: .destructive) { model.project.zoom.segments = []; model.selectedZoom = nil }
        }
    }

    func handle(left: Bool, a: CGFloat, b: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8, height: height)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.55)).frame(width: 2, height: height * 0.42))
            .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if left { dragStart = v.translation.width } else { dragEnd = v.translation.width }
            }.onEnded { v in
                if left { commit(da: v.translation.width, db: 0) } else { commit(da: 0, db: v.translation.width) }
            })
    }

    func commit(da: CGFloat, db: CGFloat) {
        let d = max(model.duration, 0.001)
        let na = start + Double(da / width) * d, nb = end + Double(db / width) * d
        dragStart = 0; dragEnd = 0
        model.updateZoom(zoom.id, outStart: min(na, nb - 0.3), outEnd: nb)
        model.selectedZoom = zoom.id
    }
}
