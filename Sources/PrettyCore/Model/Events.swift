import Foundation

// events.json — input telemetry recorded alongside the screen video.
// All coordinates are in SOURCE VIDEO PIXELS (top-left origin); all times are seconds
// from the first video frame. Every recorder (screen, web, simulator, manual marks) writes this.

public struct InputEvents: Codable {
    public var version: Int = 1
    public var width: Double = 0
    public var height: Double = 0
    public var pointScale: Double = 2
    /// Mouse samples: [t, x, y]
    public var mouse: [[Double]] = []
    public var clicks: [ClickEvent] = []
    public var keys: [KeyEvent] = []
    public var scrolls: [ScrollEvent] = []
    /// Cursor shape changes: t + kind (arrow | pointer | text | grab | grabbing | crosshair | notAllowed | resize...)
    public var cursors: [CursorChange] = []
    /// Agent-placed hints (zoom/caption/spotlight markers from storyboards).
    public var markers: [Marker] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case version, width, height, pointScale, mouse, clicks, keys, scrolls, cursors, markers }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.v(.version, 1); width = try c.v(.width, 0); height = try c.v(.height, 0)
        pointScale = try c.v(.pointScale, 2); mouse = try c.v(.mouse, []); clicks = try c.v(.clicks, [])
        keys = try c.v(.keys, []); scrolls = try c.v(.scrolls, []); cursors = try c.v(.cursors, [])
        markers = try c.v(.markers, [])
    }

    public static func load(_ url: URL) throws -> InputEvents {
        try JSONDecoder().decode(InputEvents.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url)
    }

    public mutating func sortAll() {
        mouse.sort { $0[0] < $1[0] }
        clicks.sort { $0.t < $1.t }
        keys.sort { $0.t < $1.t }
        scrolls.sort { $0.t < $1.t }
        cursors.sort { $0.t < $1.t }
        markers.sort { $0.t < $1.t }
    }
}

public struct ClickEvent: Codable {
    public var t: Double
    public var x: Double
    public var y: Double
    /// Release time (defaults to t + 0.08).
    public var up: Double? = nil
    /// left | right | middle
    public var button: String = "left"
    /// true for touches on mobile recordings.
    public var touch: Bool = false
    /// Normalized rect of the clicked element, and of the meaningful container around it
    /// (card, dialog, form, section). Smart Zooms frame the context so headings stay in view.
    public var rect: NRect? = nil
    public var context: NRect? = nil
    /// Why this action happened (from a directed storyboard), and the selector that was clicked.
    public var why: String? = nil
    public var target: String? = nil
    public init(t: Double, x: Double, y: Double, up: Double? = nil, button: String = "left", touch: Bool = false) {
        self.t = t; self.x = x; self.y = y; self.up = up; self.button = button; self.touch = touch
    }
    enum CodingKeys: String, CodingKey { case t, x, y, up, button, touch, rect, context, why, target }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t); x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        up = try c.decodeIfPresent(Double.self, forKey: .up); button = try c.v(.button, "left"); touch = try c.v(.touch, false)
        rect = try c.decodeIfPresent(NRect.self, forKey: .rect); context = try c.decodeIfPresent(NRect.self, forKey: .context)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        target = try c.decodeIfPresent(String.self, forKey: .target)
    }
    public var release: Double { up ?? (t + 0.08) }
}

public struct KeyEvent: Codable {
    public var t: Double
    /// Key name: single characters ("a", "K"), or names: return, tab, space, delete, escape, left, right, up, down, f1...
    public var key: String
    /// Modifiers: cmd, shift, opt, ctrl, fn
    public var mods: [String] = []
    public init(t: Double, key: String, mods: [String] = []) { self.t = t; self.key = key; self.mods = mods }
    enum CodingKeys: String, CodingKey { case t, key, mods }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t); key = try c.decode(String.self, forKey: .key); mods = try c.v(.mods, [])
    }
    /// A "shortcut" has a command-like modifier (shift alone is just typing).
    public var isShortcut: Bool { mods.contains { $0 == "cmd" || $0 == "ctrl" || $0 == "opt" || $0 == "fn" } }
}

public struct ScrollEvent: Codable {
    public var t: Double
    public var dx: Double = 0
    public var dy: Double = 0
    public var x: Double? = nil
    public var y: Double? = nil
    public init(t: Double, dx: Double, dy: Double, x: Double? = nil, y: Double? = nil) { self.t = t; self.dx = dx; self.dy = dy; self.x = x; self.y = y }
    enum CodingKeys: String, CodingKey { case t, dx, dy, x, y }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t); dx = try c.v(.dx, 0); dy = try c.v(.dy, 0)
        x = try c.decodeIfPresent(Double.self, forKey: .x); y = try c.decodeIfPresent(Double.self, forKey: .y)
    }
}

public struct CursorChange: Codable {
    public var t: Double
    public var kind: String
    public init(t: Double, kind: String) { self.t = t; self.kind = kind }
}

public struct Marker: Codable {
    public var t: Double
    /// zoom | caption | spotlight | highlight | note | cut-start | cut-end
    public var type: String
    public var duration: Double? = nil
    public var level: Double? = nil
    /// Normalized source rect for zoom / spotlight targets.
    public var rect: NRect? = nil
    public var text: String? = nil
    /// For "beat" markers: the storyboard beat index.
    public var index: Int? = nil
    public init(t: Double, type: String, duration: Double? = nil, level: Double? = nil, rect: NRect? = nil, text: String? = nil, index: Int? = nil) {
        self.t = t; self.type = type; self.duration = duration; self.level = level; self.rect = rect; self.text = text; self.index = index
    }
}
