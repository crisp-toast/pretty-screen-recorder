import Foundation
import CoreGraphics

public enum AutoEdit {
    // MARK: Smart Zooms

    struct Activity { var t: Double; var end: Double; var x: Double; var y: Double; var context: NRect? = nil }

    /// Place zooms where the action is: clusters of clicks and typing bursts.
    /// Agent markers (type "zoom") become manual zooms on their target rect.
    /// Phones: push in on what a tap reveals, the way an editor would — anticipate the tap, hold on
    /// the result, merge taps close in time and space, and leave breathing room between zooms.
    static func mobileZooms(events: InputEvents, duration: Double, avoid: [ZoomSegment]) -> [ZoomSegment] {
        let W = max(events.width, 1), H = max(events.height, 1)
        let taps = events.clicks.filter { $0.button == "left" }.sorted { $0.t < $1.t }
        var groups: [[ClickEvent]] = []
        for tap in taps {
            if var g = groups.last, let last = g.last, tap.t - last.t < 2.4, abs(tap.y - last.y) / H < 0.34 {
                g.append(tap); groups[groups.count - 1] = g
            } else { groups.append([tap]) }
        }
        var out: [ZoomSegment] = []
        for g in groups {
            let first = g.first!.t, last = g.last!.t
            var start = max(0, first - 0.55), end = min(duration, last + 2.1)
            if let prev = out.last, start < prev.end { start = prev.end }
            guard end - start >= 1.4 else { continue }
            if avoid.contains(where: { start < $0.end && $0.start < end }) { continue }
            let fx = g.map(\.x).reduce(0, +) / Double(g.count) / W
            let fy = g.map(\.y).reduce(0, +) / Double(g.count) / H
            // Taps on the tab bar or nav bar change screens: frame the screen's upper content instead.
            let focusY = fy > 0.86 ? 0.42 : fy < 0.1 ? 0.3 : fy
            // A phone is narrow: push in straight (centered horizontally) so the frame crops evenly,
            // and only as far as keeps the tapped region readable without losing the device.
            _ = fx
            out.append(ZoomSegment(start: round3(start), end: round3(end), level: 1.38, mode: "manual",
                                   focus: NPoint(x: 0.5, y: round3(clamp(focusY, 0.3, 0.7))), auto: true))
        }
        // Zooms close together join into one continuous push that pans between taps, instead of
        // pumping in and out.
        if out.count > 1 {
            for k in 1..<out.count where out[k].start - out[k - 1].end < 2.0 {
                out[k - 1].end = out[k].start
            }
        }
        return out
    }

    public static func smartZooms(events: InputEvents, duration: Double, level: Double, mode: String, kind: String) -> [ZoomSegment] {
        let W = max(events.width, 1), H = max(events.height, 1)
        var segs: [ZoomSegment] = []

        // Explicit markers first.
        for m in events.markers where m.type == "zoom" {
            let d = m.duration ?? 2.5
            var lvl = m.level ?? level
            var focus: NPoint? = nil
            if let r = m.rect {
                focus = NPoint(x: r.x + r.w / 2, y: r.y + r.h / 2)
                // Fit the target comfortably inside the zoomed view (a zoom of L shows 1/L of each axis).
                let fit = 0.82 / max(r.w, r.h, 0.01)
                if m.level == nil { lvl = clamp(min(fit, 2.2), 1.15, 2.2) }
            }
            segs.append(ZoomSegment(start: max(0, m.t - 0.15), end: min(duration, m.t + d), level: lvl,
                                    mode: focus != nil ? "manual" : mode, focus: focus, auto: true))
        }
        let mobile = ["ios", "mobile-web", "android"].contains(kind)
        if mobile { return (segs + mobileZooms(events: events, duration: duration, avoid: segs)).sorted { $0.start < $1.start } }

        var acts: [Activity] = events.clicks.filter { $0.button == "left" }.map { Activity(t: $0.t, end: $0.release, x: $0.x, y: $0.y, context: $0.context) }
        // Typing bursts → focus on where the user last clicked (the field).
        let typing = events.keys.filter { !$0.isShortcut }
        var bursts: [(Double, Double)] = []
        for k in typing {
            if let l = bursts.last, k.t - l.1 < 1.0 { bursts[bursts.count - 1].1 = k.t } else { bursts.append((k.t, k.t)) }
        }
        for (a, b) in bursts where b - a > 0.3 || typing.filter({ $0.t >= a && $0.t <= b }).count >= 3 {
            if let c = events.clicks.last(where: { $0.t <= a && a - $0.t < 10 }) {
                acts.append(Activity(t: a, end: b, x: c.x, y: c.y, context: c.context))
            }
        }
        acts.sort { $0.t < $1.t }
        // Ignore activity covered by explicit markers.
        acts.removeAll { a in segs.contains { a.t >= $0.start && a.t <= $0.end } }

        // Cluster in time and space.
        let spatial = 0.32 * min(W, H)
        var clusters: [[Activity]] = []
        for a in acts {
            if var c = clusters.last, let last = c.last {
                let cx = c.map(\.x).reduce(0, +) / Double(c.count), cy = c.map(\.y).reduce(0, +) / Double(c.count)
                if a.t - last.end < 2.6 && hypot(a.x - cx, a.y - cy) < spatial {
                    c.append(a); clusters[clusters.count - 1] = c; continue
                }
            }
            clusters.append([a])
        }

        var autoSegs: [ZoomSegment] = []
        for c in clusters {
            let first = c.first!.t, last = c.map(\.end).max()!
            var start = max(0, first - 0.9), end = min(duration, last + 1.6)
            if end - start < 1.9 { end = min(duration, start + 1.9) }
            if end - start < 0.8 { continue }
            let xs = c.map(\.x), ys = c.map(\.y)
            var lvl = level, zmode = mode
            var fx = (xs.min()! + xs.max()!) / 2 / W, fy = (ys.min()! + ys.max()!) / 2 / H
            let contexts = c.compactMap(\.context)
            if !contexts.isEmpty {
                // Frame the whole container (card, dialog, form) with breathing room, so headings and
                // surrounding context stay in view — steadier than following the cursor.
                let minX = contexts.map(\.x).min()!, minY = contexts.map(\.y).min()!
                let maxX = contexts.map { $0.x + $0.w }.max()!, maxY = contexts.map { $0.y + $0.h }.max()!
                let pad = 0.03
                let w = min(1, maxX - minX + pad * 2), h = min(1, maxY - minY + pad * 2)
                let fit = 0.92 / max(w, h)
                if fit < 1.12 { continue } // the context is nearly the whole screen: no zoom needed
                lvl = clamp(min(fit, max(level, 1.15) * 1.35), 1.12, 2.2)
                fx = (minX + maxX) / 2; fy = (minY + maxY) / 2
                zmode = "manual"
            } else {
                let extent = max((xs.max()! - xs.min()!) / W, (ys.max()! - ys.min()!) / H)
                if extent > 0.01 { lvl = min(level, 0.7 / extent) }
                lvl = clamp(lvl, 1.2, 2.5)
            }
            if let prev = autoSegs.last, start - prev.end < 0.7 {
                // Connect: shorten the gap so the camera pans instead of zooming out.
                let mid = (prev.end + start) / 2
                autoSegs[autoSegs.count - 1].end = mid
                start = mid
            }
            autoSegs.append(ZoomSegment(start: start, end: end, level: (lvl * 100).rounded() / 100, mode: zmode,
                                        focus: NPoint(x: round3(fx), y: round3(fy)), auto: true))
        }
        // Directed (marker) zooms win: trim automatic ones away from them.
        var trimmed: [ZoomSegment] = []
        for var z in autoSegs {
            for m in segs where z.start < m.end && m.start < z.end {
                if z.start < m.start { z.end = min(z.end, m.start) } else { z.start = max(z.start, m.end) }
            }
            if z.end - z.start >= 0.9 { trimmed.append(z) }
        }
        for i in trimmed.indices { trimmed[i].start = round3(trimmed[i].start); trimmed[i].end = round3(trimmed[i].end) }
        return (segs + trimmed).sorted { $0.start < $1.start }
    }

    // MARK: Idle compression

    /// Find stretches with no input and no pixel changes, and cut (or speed up) their middles.
    public static func idleRanges(events: InputEvents, duration: Double, freezes: [(Double, Double)], spec: IdleSpec,
                                  trimStart: Double = 0, trimEnd: Double? = nil) -> (cuts: [TimeRange], speed: [SpeedRange]) {
        let t0 = trimStart, t1 = trimEnd ?? duration
        var busy: [(Double, Double)] = []
        func mark(_ a: Double, _ b: Double) { busy.append((a - spec.keepBefore, b + spec.keepAfter)) }
        var lastXY: (Double, Double)? = nil
        for m in events.mouse where m.count >= 3 {
            if let l = lastXY, abs(l.0 - m[1]) + abs(l.1 - m[2]) < 1.5 { continue }
            if lastXY != nil { mark(m[0], m[0]) }
            lastXY = (m[1], m[2])
        }
        for c in events.clicks { mark(c.t, c.release) }
        for k in events.keys { mark(k.t, k.t) }
        for s in events.scrolls { mark(s.t, s.t + 0.3) }
        for m in events.markers { mark(m.t, m.t + (m.duration ?? 0)) }
        // Visual activity = everything that is not frozen.
        var cursor = 0.0
        for (a, b) in freezes.sorted(by: { $0.0 < $1.0 }) {
            if a > cursor { busy.append((cursor, a + spec.keepAfter)) }
            cursor = max(cursor, b)
        }
        if cursor < duration && !freezes.isEmpty { busy.append((cursor, duration)) }
        if freezes.isEmpty && events.mouse.isEmpty && events.clicks.isEmpty { return ([], []) }

        busy = busy.map { (max(t0, $0.0), min(t1, $0.1)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for b in busy {
            if let l = merged.last, b.0 <= l.1 { merged[merged.count - 1].1 = max(l.1, b.1) } else { merged.append(b) }
        }
        var gaps: [(Double, Double)] = []
        var c = t0
        for b in merged { if b.0 > c { gaps.append((c, b.0)) }; c = max(c, b.1) }
        if c < t1 { gaps.append((c, t1)) }
        let idle = gaps.filter { $0.1 - $0.0 >= spec.minGap }
        if spec.mode == "speed" {
            return ([], idle.map { SpeedRange(start: round3($0.0), end: round3($0.1), rate: spec.rate, auto: true) })
        }
        return (idle.map { TimeRange(start: round3($0.0), end: round3($0.1), auto: true) }, [])
    }
}
