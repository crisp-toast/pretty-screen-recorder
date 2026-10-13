import Foundation
import AppKit
import CoreMedia

/// Polls the pointer (no permissions needed), watches mouse buttons, and taps keys when
/// Input Monitoring is granted. Times are host-clock seconds so they line up with
/// ScreenCaptureKit sample timestamps.
public final class InputMonitor {
    public struct Mapping {
        /// Capture origin in global top-left point coordinates.
        public var origin: CGPoint
        /// Pixels per point in the captured video.
        public var scale: CGFloat
        public init(origin: CGPoint, scale: CGFloat) { self.origin = origin; self.scale = scale }
    }

    public var mapping: Mapping
    public var mappingProvider: (() -> Mapping?)?
    private(set) var mouse: [[Double]] = []
    private(set) var clicks: [ClickEvent] = []
    private(set) var keys: [KeyEvent] = []
    private(set) var cursors: [CursorChange] = []
    private var timer: DispatchSourceTimer?
    private var lastButtons = 0
    private var openClicks: [Int: Int] = [:]
    private var lastPos: CGPoint?
    private var lastKind = ""
    private var tick = 0
    private var tap: CFMachPort?
    private let queue = DispatchQueue(label: "pretty.input", qos: .userInteractive)
    public private(set) var keysAvailable = false
    private let lock = NSLock()

    public init(mapping: Mapping) { self.mapping = mapping }

    public static func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - mapping.origin.x) * mapping.scale, y: (p.y - mapping.origin.y) * mapping.scale)
    }

    /// Global pointer position in top-left point coordinates.
    static func pointer() -> CGPoint {
        if let e = CGEvent(source: nil) { return e.location }
        let m = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: h - m.y)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        startKeyTap()
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func poll() {
        tick += 1
        if tick % 12 == 0, let m = mappingProvider?() { mapping = m }
        let now = InputMonitor.hostNow()
        let g = InputMonitor.pointer()
        let p = local(g)
        lock.lock(); defer { lock.unlock() }
        if lastPos == nil || abs(p.x - lastPos!.x) + abs(p.y - lastPos!.y) > 0.25 {
            mouse.append([now, Double(p.x), Double(p.y)])
            lastPos = p
        }
        let buttons = NSEvent.pressedMouseButtons
        if buttons != lastButtons {
            for b in 0..<3 {
                let was = lastButtons & (1 << b) != 0, isDown = buttons & (1 << b) != 0
                if !was && isDown {
                    clicks.append(ClickEvent(t: now, x: Double(p.x), y: Double(p.y), up: nil, button: ["left", "right", "middle"][b]))
                    openClicks[b] = clicks.count - 1
                } else if was && !isDown, let i = openClicks[b] {
                    clicks[i].up = now; openClicks[b] = nil
                }
            }
            lastButtons = buttons
        }
        if tick % 6 == 0 {
            let k = InputMonitor.currentCursorKind()
            if k != lastKind { cursors.append(CursorChange(t: now, kind: k)); lastKind = k }
        }
    }

    /// Best-effort classification of the system cursor via its hotspot/size signature.
    static func currentCursorKind() -> String {
        guard let c = NSCursor.currentSystem else { return "arrow" }
        let hs = c.hotSpot, sz = c.image.size
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(a.x - x) < 1.5 && abs(a.y - y) < 1.5 }
        if let ib = NSCursor.iBeam.image.size as CGSize?, sz == ib, near(hs, NSCursor.iBeam.hotSpot.x, NSCursor.iBeam.hotSpot.y) { return "text" }
        if sz == NSCursor.pointingHand.image.size && near(hs, NSCursor.pointingHand.hotSpot.x, NSCursor.pointingHand.hotSpot.y) { return "pointer" }
        if sz == NSCursor.openHand.image.size && near(hs, NSCursor.openHand.hotSpot.x, NSCursor.openHand.hotSpot.y) { return "grab" }
        if sz == NSCursor.closedHand.image.size && near(hs, NSCursor.closedHand.hotSpot.x, NSCursor.closedHand.hotSpot.y) { return "grabbing" }
        if sz == NSCursor.crosshair.image.size && near(hs, NSCursor.crosshair.hotSpot.x, NSCursor.crosshair.hotSpot.y) { return "crosshair" }
        return "arrow"
    }

    // MARK: Keys (needs Input Monitoring; silently skipped otherwise)

    private func startKeyTap() {
        guard CGPreflightListenEventAccess() else { keysAvailable = false; return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            if type == .keyDown, let refcon {
                Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue().handleKey(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: ref) else { keysAvailable = false; return }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keysAvailable = true
    }

    static let keyNames: [Int64: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 117: "forwarddelete", 123: "left", 124: "right",
        125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown", 76: "return",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private func handleKey(_ e: CGEvent) {
        let now = InputMonitor.hostNow()
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let f = e.flags
        var mods: [String] = []
        if f.contains(.maskControl) { mods.append("ctrl") }
        if f.contains(.maskAlternate) { mods.append("opt") }
        if f.contains(.maskShift) { mods.append("shift") }
        if f.contains(.maskCommand) { mods.append("cmd") }
        var name = InputMonitor.keyNames[code]
        if name == nil {
            // Character without modifiers applied (so ⌘K reads "k", not a control char).
            var len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let plain = e.copy() ?? e
            plain.flags = f.contains(.maskShift) ? .maskShift : []
            plain.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
            name = String(utf16CodeUnits: chars, count: len)
        }
        guard let key = name, !key.isEmpty else { return }
        lock.lock(); keys.append(KeyEvent(t: now, key: key, mods: mods)); lock.unlock()
    }

    /// Snapshot as events relative to `t0` (host seconds of the first video frame).
    public func events(t0: Double, width: Double, height: Double, pointScale: Double) -> InputEvents {
        lock.lock(); defer { lock.unlock() }
        var ev = InputEvents()
        ev.width = width; ev.height = height; ev.pointScale = pointScale
        ev.mouse = mouse.filter { $0[0] >= t0 - 0.5 }.map { [max(0, round3($0[0] - t0)), round3($0[1]), round3($0[2])] }
        ev.clicks = clicks.filter { $0.t >= t0 }.map { var c = $0; c.t = round3(c.t - t0); c.up = c.up.map { round3($0 - t0) }; return c }
        ev.keys = keys.filter { $0.t >= t0 }.map { var k = $0; k.t = round3(k.t - t0); return k }
        ev.cursors = cursors.map { CursorChange(t: max(0, round3($0.t - t0)), kind: $0.kind) }
        return ev
    }
}
