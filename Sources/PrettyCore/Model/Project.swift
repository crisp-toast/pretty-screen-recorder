import Foundation

// The project document. Every field has a default, so a minimal project.json is just
// {"source": {"video": "sources/screen.mov"}}. Agents edit this JSON (or use `pretty set`).
//
// Time bases:
//   - zoom segments, cuts, speed ranges, spotlight/blur/highlight overlays: SOURCE time
//     (seconds into the raw recording), so they stay attached to the content when cuts change.
//   - text/image overlays, captions, voiceover, music: OUTPUT time (seconds into the final video),
//     unless an overlay sets "time": "source".

public struct Project: Codable, Equatable {
    public var version: Int = 1
    public var name: String = "Untitled"
    public var source = SourceSpec()
    /// Duration for projects with no source video (title cards). Ignored when a video exists.
    public var duration: Double? = nil
    public var timeline = TimelineSpec()
    public var zoom = ZoomSpec()
    public var cursor = CursorSpec()
    public var keystrokes = KeystrokeSpec()
    public var camera = CameraSpec()
    public var background = BackgroundSpec()
    public var layout = LayoutSpec()
    public var frame = FrameSpec()
    public var motion = MotionSpec()
    public var overlays: [Overlay] = []
    /// Full-screen kinetic type scenes (OUTPUT time): the recording steps aside while they play.
    public var scenes: [TextScene] = []
    /// Device moves (OUTPUT time): rise, tilt, orbit, push, drift, float — motion of the flat device.
    public var moves: [DeviceMove] = []
    /// Real 3D device shots (OUTPUT time), rendered with Blender; they replace the flat device while they play.
    public var shots: [DeviceShot] = []
    public var captions = CaptionSpec()
    public var audio = AudioSpec()
    public var export = ExportSpec()
    public var brand = BrandSpec()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, name, source, duration, timeline, zoom, cursor, keystrokes, camera, background,
             layout, frame, motion, overlays, scenes, moves, shots, captions, audio, export, brand
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = Project()
        version = try c.v(.version, z.version)
        name = try c.v(.name, z.name)
        source = try c.v(.source, z.source)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        timeline = try c.v(.timeline, z.timeline)
        zoom = try c.v(.zoom, z.zoom)
        cursor = try c.v(.cursor, z.cursor)
        keystrokes = try c.v(.keystrokes, z.keystrokes)
        camera = try c.v(.camera, z.camera)
        background = try c.v(.background, z.background)
        layout = try c.v(.layout, z.layout)
        frame = try c.v(.frame, z.frame)
        motion = try c.v(.motion, z.motion)
        overlays = try c.v(.overlays, z.overlays)
        scenes = try c.v(.scenes, z.scenes)
        moves = try c.v(.moves, z.moves)
        shots = try c.v(.shots, z.shots)
        captions = try c.v(.captions, z.captions)
        audio = try c.v(.audio, z.audio)
        export = try c.v(.export, z.export)
        brand = try c.v(.brand, z.brand)
    }
}

// MARK: - Source

public struct SourceSpec: Codable, Equatable {
    /// Screen recording, relative to the project bundle (or absolute).
    public var video: String? = nil
    /// Cursor / click / key telemetry (events.json), relative to the bundle.
    public var events: String? = nil
    /// Webcam or presenter video (any clip, e.g. an AI avatar), played in sync with the source.
    public var camera: String? = nil
    /// Separate microphone track (if not muxed into `video`).
    public var mic: String? = nil
    /// desktop | window | web | mobile-web | ios | android | video | card
    public var kind: String = "desktop"
    /// Source pixels per UI point (2 for Retina / DPR 2, 3 for iPhone). Scales the cursor.
    public var pointScale: Double = 2
    /// URL shown in the browser frame for web recordings.
    public var url: String? = nil
    /// Window/app title shown in a synthetic window frame.
    public var title: String? = nil
    /// Optional crop of the source, normalized 0-1.
    public var crop: NRect? = nil

    public init() {}
    enum CodingKeys: String, CodingKey { case video, events, camera, mic, kind, pointScale, url, title, crop }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = SourceSpec()
        video = try c.decodeIfPresent(String.self, forKey: .video)
        events = try c.decodeIfPresent(String.self, forKey: .events)
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        mic = try c.decodeIfPresent(String.self, forKey: .mic)
        kind = try c.v(.kind, z.kind)
        pointScale = try c.v(.pointScale, z.pointScale)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        crop = try c.decodeIfPresent(NRect.self, forKey: .crop)
    }
}

// MARK: - Timeline

public struct TimeRange: Codable, Equatable {
    public var start: Double
    public var end: Double
    /// true when generated automatically (idle compression); regenerated by `pretty auto`.
    public var auto: Bool = false
    public init(start: Double, end: Double, auto: Bool = false) { self.start = start; self.end = end; self.auto = auto }
    enum CodingKeys: String, CodingKey { case start, end, auto }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        auto = try c.v(.auto, false)
    }
}

public struct SpeedRange: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var rate: Double
    public var auto: Bool = false
    public init(start: Double, end: Double, rate: Double, auto: Bool = false) {
        self.start = start; self.end = end; self.rate = rate; self.auto = auto
    }
    enum CodingKeys: String, CodingKey { case start, end, rate, auto }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        rate = try c.v(.rate, 2)
        auto = try c.v(.auto, false)
    }
}

public struct IdleSpec: Codable, Equatable {
    /// Shorten stretches where nothing happens (no input, no pixels changing).
    /// Essential for agent-driven recordings, which have long "thinking" pauses.
    public var compress: Bool = false
    /// Only gaps longer than this many seconds are compressed.
    public var minGap: Double = 1.6
    /// Seconds kept before activity resumes (room for the cursor to glide in).
    public var keepBefore: Double = 0.7
    /// Seconds kept after activity stops (let animations settle).
    public var keepAfter: Double = 0.5
    /// "cut" removes the idle middle; "speed" fast-forwards it at `rate`.
    public var mode: String = "cut"
    public var rate: Double = 8
    public init() {}
    enum CodingKeys: String, CodingKey { case compress, minGap, keepBefore, keepAfter, mode, rate }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = IdleSpec()
        compress = try c.v(.compress, z.compress); minGap = try c.v(.minGap, z.minGap)
        keepBefore = try c.v(.keepBefore, z.keepBefore); keepAfter = try c.v(.keepAfter, z.keepAfter)
        mode = try c.v(.mode, z.mode); rate = try c.v(.rate, z.rate)
    }
}

/// A freeze-frame: hold the source frame at `at` for `duration` output seconds.
public struct HoldRange: Codable, Equatable {
    public var at: Double
    public var duration: Double
    public var auto: Bool = false
    public init(at: Double, duration: Double, auto: Bool = false) { self.at = at; self.duration = duration; self.auto = auto }
    enum CodingKeys: String, CodingKey { case at, duration, auto }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at); duration = try c.decode(Double.self, forKey: .duration); auto = try c.v(.auto, false)
    }
}

public struct TimelineSpec: Codable, Equatable {
    public var trimStart: Double = 0
    public var trimEnd: Double? = nil
    public var cuts: [TimeRange] = []
    public var speed: [SpeedRange] = []
    /// Freeze-frames (source time) — used by `pretty conform` to give an action room to breathe.
    public var holds: [HoldRange] = []
    public var idle = IdleSpec()
    public init() {}
    enum CodingKeys: String, CodingKey { case trimStart, trimEnd, cuts, speed, holds, idle }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = TimelineSpec()
        trimStart = try c.v(.trimStart, z.trimStart)
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        cuts = try c.v(.cuts, z.cuts); speed = try c.v(.speed, z.speed); holds = try c.v(.holds, z.holds); idle = try c.v(.idle, z.idle)
    }
}

// MARK: - Zoom

public struct ZoomSegment: Codable, Equatable {
    public var id: String = UUID().uuidString.prefix(8).lowercased()
    public var start: Double
    public var end: Double
    /// 1.0 = no zoom, 1.5 = 150% (CleanShot's default).
    public var level: Double = 1.5
    /// "follow" keeps the cursor in view; "manual" holds `focus`.
    public var mode: String = "follow"
    /// Focus point in normalized source coordinates (0-1). Used by manual mode, and as
    /// the initial target for follow mode.
    public var focus: NPoint? = nil
    public var auto: Bool = false
    public init(start: Double, end: Double, level: Double = 1.5, mode: String = "follow", focus: NPoint? = nil, auto: Bool = false) {
        self.start = start; self.end = end; self.level = level; self.mode = mode; self.focus = focus; self.auto = auto
    }
    enum CodingKeys: String, CodingKey { case id, start, end, level, mode, focus, auto }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? String(UUID().uuidString.prefix(8)).lowercased()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        level = try c.v(.level, 1.5); mode = try c.v(.mode, "follow")
        focus = try c.decodeIfPresent(NPoint.self, forKey: .focus); auto = try c.v(.auto, false)
    }
}

public struct ZoomSpec: Codable, Equatable {
    /// Generate Smart Zooms from clicks/typing when the project is created or `pretty auto` runs.
    public var auto: Bool = true
    /// Default zoom level for new zooms (walkthrough-friendly; context-framed zooms compute their own).
    public var level: Double = 1.45
    /// Default zoom mode for new zooms: follow | manual
    public var mode: String = "follow"
    public var segments: [ZoomSegment] = []
    /// Fraction of the visible area the cursor may roam before a follow-zoom pans (0-0.9).
    public var followDeadzone: Double = 0.5
    public init() {}
    enum CodingKeys: String, CodingKey { case auto, level, mode, segments, followDeadzone }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = ZoomSpec()
        auto = try c.v(.auto, z.auto); level = try c.v(.level, z.level); mode = try c.v(.mode, z.mode)
        segments = try c.v(.segments, z.segments); followDeadzone = try c.v(.followDeadzone, z.followDeadzone)
    }
}

// MARK: - Cursor & clicks

public struct RippleSpec: Codable, Equatable {
    public var enabled: Bool = true
    public var color: String = "blue"
    /// outline | filled
    public var style: String = "outline"
    public var size: Double = 1.0
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, color, style, size }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = RippleSpec()
        enabled = try c.v(.enabled, z.enabled); color = try c.v(.color, z.color)
        style = try c.v(.style, z.style); size = try c.v(.size, z.size)
    }
}

public struct CursorSpec: Codable, Equatable {
    public var show: Bool = true
    /// Multiplier on the native cursor size (CleanShot's slider runs 1x-3x).
    public var size: Double = 1.5
    /// macos (black arrow, white outline) | white (inverted) | dot (soft circle) | touch (finger-tip for mobile)
    public var style: String = "macos"
    /// raw | natural (light smoothing) | smooth (glides between resting points)
    public var motion: String = "smooth"
    /// "Press effect": cursor shrinks slightly while the button is down.
    public var pressEffect: Bool = true
    public var ripple = RippleSpec()
    public var hideWhenIdle: Bool = false
    public var idleDelay: Double = 1.5
    public var hideWhileTyping: Bool = false
    public var shadow: Bool = true
    public init() {}
    enum CodingKeys: String, CodingKey { case show, size, style, motion, pressEffect, ripple, hideWhenIdle, idleDelay, hideWhileTyping, shadow }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = CursorSpec()
        show = try c.v(.show, z.show); size = try c.v(.size, z.size); style = try c.v(.style, z.style)
        motion = try c.v(.motion, z.motion); pressEffect = try c.v(.pressEffect, z.pressEffect)
        ripple = try c.v(.ripple, z.ripple); hideWhenIdle = try c.v(.hideWhenIdle, z.hideWhenIdle)
        idleDelay = try c.v(.idleDelay, z.idleDelay); hideWhileTyping = try c.v(.hideWhileTyping, z.hideWhileTyping)
        shadow = try c.v(.shadow, z.shadow)
    }
}

// MARK: - Keystrokes

public struct KeystrokeSpec: Codable, Equatable {
    public var show: Bool = true
    /// shortcuts (only modifier combos like ⌘K) | all (every key, typing shown as text)
    public var mode: String = "shortcuts"
    /// bottom-center | bottom-left | bottom-right | top-center | top-left | top-right
    public var position: String = "bottom-center"
    public var size: Double = 1.0
    /// dark | light
    public var theme: String = "dark"
    /// Seconds a keystroke stays on screen after the last key.
    public var hold: Double = 1.1
    public init() {}
    enum CodingKeys: String, CodingKey { case show, mode, position, size, theme, hold }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = KeystrokeSpec()
        show = try c.v(.show, z.show); mode = try c.v(.mode, z.mode); position = try c.v(.position, z.position)
        size = try c.v(.size, z.size); theme = try c.v(.theme, z.theme); hold = try c.v(.hold, z.hold)
    }
}

// MARK: - Camera (webcam bubble)

public struct CameraSpec: Codable, Equatable {
    public var show: Bool = true
    /// circle | square | rectangle | vertical
    public var shape: String = "circle"
    /// Bubble width as a fraction of the output's shorter side.
    public var size: Double = 0.24
    /// 9-grid: top-left, top-center, top-right, middle-left, center, middle-right, bottom-left, bottom-center, bottom-right
    public var position: String = "bottom-right"
    public var flip: Bool = false
    /// Shrink the bubble slightly while zoomed in.
    public var shrinkOnZoom: Bool = true
    public var border: Double = 0
    public var borderColor: String = "white"
    /// Seconds to offset the camera clip relative to the screen recording.
    public var offset: Double = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case show, shape, size, position, flip, shrinkOnZoom, border, borderColor, offset }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = CameraSpec()
        show = try c.v(.show, z.show); shape = try c.v(.shape, z.shape); size = try c.v(.size, z.size)
        position = try c.v(.position, z.position); flip = try c.v(.flip, z.flip)
        shrinkOnZoom = try c.v(.shrinkOnZoom, z.shrinkOnZoom); border = try c.v(.border, z.border)
        borderColor = try c.v(.borderColor, z.borderColor); offset = try c.v(.offset, z.offset)
    }
}

// MARK: - Background

public struct BackgroundSpec: Codable, Equatable {
    /// gradient | color | image | blur | none
    public var type: String = "gradient"
    /// Built-in gradient name (see `pretty backgrounds`).
    public var preset: String = "aurora"
    /// Custom gradient colors (overrides preset when 2+ colors).
    public var colors: [String] = []
    /// Angle in degrees for custom linear gradients.
    public var angle: Double = 135
    public var color: String = "#101014"
    /// Image path (absolute or relative to bundle) for type=image.
    public var image: String? = nil
    /// Blur radius applied to image backgrounds (and the recording for type=blur), in output points.
    public var blur: Double = 0
    /// Film grain 0-1 (off by default; an invisible sub-LSB dither already prevents banding).
    public var grain: Double = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case type, preset, colors, angle, color, image, blur, grain }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = BackgroundSpec()
        type = try c.v(.type, z.type); preset = try c.v(.preset, z.preset); colors = try c.v(.colors, z.colors)
        angle = try c.v(.angle, z.angle); color = try c.v(.color, z.color)
        image = try c.decodeIfPresent(String.self, forKey: .image); blur = try c.v(.blur, z.blur)
        grain = try c.v(.grain, z.grain)
    }
}

// MARK: - Layout

public struct LayoutSpec: Codable, Equatable {
    /// auto | 16:9 | 9:16 | 1:1 | 4:5 | 5:4 | 4:3 | 3:4 | 3:2 | 2:3 | 21:9
    public var aspect: String = "auto"
    /// Space around the recording, as a fraction of the output's shorter side.
    public var padding: Double = 0.08
    /// Corner radius as a fraction of the recording's shorter side (ignored by device frames).
    public var corners: Double = 0.025
    /// Shadow intensity 0-1.
    public var shadow: Double = 0.55
    /// contain (whole recording visible) | cover (fill the frame, camera follows the action)
    public var fit: String = "contain"
    /// Nudge the recording inside the frame, normalized (-0.5...0.5). Useful to leave room for titles.
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// Scale of the recording inside the padded area (1 = fill the padded area).
    public var scale: Double = 1
    /// Subtle 1px inner border on the recording.
    public var border: Bool = true
    /// 3D tilt for hero shots, degrees (0 = flat).
    public var tiltX: Double = 0
    public var tiltY: Double = 0
    /// Reserve a band above / below the recording (fraction of output height) for titles and CTAs.
    /// Top/bottom text overlays center themselves in these bands automatically.
    public var headroom: Double = 0
    public var footroom: Double = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case aspect, padding, corners, shadow, fit, offsetX, offsetY, scale, border, tiltX, tiltY, headroom, footroom }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = LayoutSpec()
        aspect = try c.v(.aspect, z.aspect); padding = try c.v(.padding, z.padding); corners = try c.v(.corners, z.corners)
        shadow = try c.v(.shadow, z.shadow); fit = try c.v(.fit, z.fit); offsetX = try c.v(.offsetX, z.offsetX)
        offsetY = try c.v(.offsetY, z.offsetY); scale = try c.v(.scale, z.scale); border = try c.v(.border, z.border)
        tiltX = try c.v(.tiltX, z.tiltX); tiltY = try c.v(.tiltY, z.tiltY)
        headroom = try c.v(.headroom, z.headroom); footroom = try c.v(.footroom, z.footroom)
    }
}

// MARK: - Frame (device / browser / window chrome)

public struct FrameSpec: Codable, Equatable {
    /// auto | none | window | browser | iphone | ipad | android
    public var type: String = "auto"
    /// light | dark
    public var theme: String = "light"
    /// Device finish: black | silver | natural | desert | blue
    public var color: String = "black"
    /// Override the URL / title shown in browser and window chrome.
    public var url: String? = nil
    public var title: String? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case type, theme, color, url, title }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = FrameSpec()
        type = try c.v(.type, z.type); theme = try c.v(.theme, z.theme); color = try c.v(.color, z.color)
        url = try c.decodeIfPresent(String.self, forKey: .url); title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

// MARK: - Motion

public struct MotionSpec: Codable, Equatable {
    /// off | low | medium | high
    public var blur: String = "medium"
    /// smooth | dynamic (snappier, with a touch of overshoot)
    public var zoomAnimation: String = "smooth"
    public init() {}
    enum CodingKeys: String, CodingKey { case blur, zoomAnimation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = MotionSpec()
        blur = try c.v(.blur, z.blur); zoomAnimation = try c.v(.zoomAnimation, z.zoomAnimation)
    }
}

// MARK: - Overlays

public struct Overlay: Codable, Equatable {
    /// text | image | spotlight | blur | highlight
    public var type: String = "text"
    public var start: Double = 0
    public var end: Double = 3
    /// output | source. Text/image default to output time; spotlight/blur/highlight default to source time.
    public var time: String? = nil
    // text
    public var text: String? = nil
    /// title | subtitle | caption | label | kicker
    public var style: String = "title"
    /// top | center | bottom | top-left ... or a point via x/y
    public var position: String = "top"
    public var x: Double? = nil
    public var y: Double? = nil
    /// Text size multiplier on the style's default.
    public var size: Double = 1
    /// "auto" picks white or near-black from the background.
    public var color: String = "auto"
    /// Pill background color behind the text (null for none).
    public var fill: String? = nil
    public var font: String? = nil
    /// regular | medium | semibold | bold | heavy
    public var weight: String? = nil
    /// fade | rise | pop | slide | typewriter | none
    public var animation: String = "rise"
    /// Max text width as fraction of the output width.
    public var maxWidth: Double = 0.84
    // image
    public var path: String? = nil
    /// Width as a fraction of the output width (image overlays).
    public var width: Double = 0.18
    // spotlight / blur / highlight — rect in normalized source coordinates
    public var rect: NRect? = nil
    public var dim: Double = 0.6
    public var amount: Double = 18
    public var radius: Double = 0.012
    /// Optional tag ("headline" = made by a directed plan; replaced when it's re-applied).
    public var id: String? = nil
    public init() {}

    enum CodingKeys: String, CodingKey {
        case type, start, end, time, text, style, position, x, y, size, color, fill, font, weight, animation, maxWidth,
             path, width, rect, dim, amount, radius, id
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = Overlay()
        type = try c.v(.type, z.type); start = try c.v(.start, z.start); end = try c.v(.end, z.end)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        text = try c.decodeIfPresent(String.self, forKey: .text); style = try c.v(.style, z.style)
        position = try c.v(.position, z.position)
        x = try c.decodeIfPresent(Double.self, forKey: .x); y = try c.decodeIfPresent(Double.self, forKey: .y)
        size = try c.v(.size, z.size); color = try c.v(.color, z.color)
        fill = try c.decodeIfPresent(String.self, forKey: .fill); font = try c.decodeIfPresent(String.self, forKey: .font)
        weight = try c.decodeIfPresent(String.self, forKey: .weight); animation = try c.v(.animation, z.animation)
        maxWidth = try c.v(.maxWidth, z.maxWidth); path = try c.decodeIfPresent(String.self, forKey: .path)
        width = try c.v(.width, z.width); rect = try c.decodeIfPresent(NRect.self, forKey: .rect)
        dim = try c.v(.dim, z.dim); amount = try c.v(.amount, z.amount); radius = try c.v(.radius, z.radius)
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }

    public var usesSourceTime: Bool {
        if let t = time { return t == "source" }
        return ["spotlight", "blur", "highlight"].contains(type)
    }
}

// MARK: - Captions

public struct CaptionItem: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct CaptionSpec: Codable, Equatable {
    public var show: Bool = true
    /// Path to an .srt file (output time).
    public var srt: String? = nil
    public var items: [CaptionItem] = []
    /// pill | bar | plain
    public var style: String = "pill"
    /// bottom | top | center
    public var position: String = "bottom"
    public var size: Double = 1
    public var theme: String = "dark"
    /// Generate captions from voiceover lines (word-timed), when voiceover is in the mix.
    public var fromVoiceover: Bool = true
    /// Max words per caption chunk.
    public var maxWords: Int = 6
    public init() {}
    enum CodingKeys: String, CodingKey { case show, srt, items, style, position, size, theme, fromVoiceover, maxWords }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = CaptionSpec()
        show = try c.v(.show, z.show); srt = try c.decodeIfPresent(String.self, forKey: .srt)
        items = try c.v(.items, z.items); style = try c.v(.style, z.style); position = try c.v(.position, z.position)
        size = try c.v(.size, z.size); theme = try c.v(.theme, z.theme)
        fromVoiceover = try c.v(.fromVoiceover, z.fromVoiceover); maxWords = try c.v(.maxWords, z.maxWords)
    }
}

// MARK: - Audio

/// Procedural soundtrack request (`pretty music generate`).
public struct MusicGenSpec: Codable, Equatable {
    /// upbeat | corporate | chill | cinematic | minimal
    public var mood: String = "upbeat"
    public var bpm: Double? = nil
    /// Root key, e.g. "C", "F#", "Bb"; minor moods use the relative minor.
    public var key: String? = nil
    public var seed: Int = 7
    /// 0-1: how busy the arrangement is.
    public var energy: Double = 0.7
    public init() {}
    enum CodingKeys: String, CodingKey { case mood, bpm, key, seed, energy }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = MusicGenSpec()
        mood = try c.v(.mood, z.mood); bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        key = try c.decodeIfPresent(String.self, forKey: .key); seed = try c.v(.seed, z.seed); energy = try c.v(.energy, z.energy)
    }
}

public struct MusicSpec: Codable, Equatable {
    public var path: String? = nil
    public var volume: Double = 0.25
    public var fadeIn: Double = 0.5
    public var fadeOut: Double = 1.5
    /// Seconds into the music file to start from.
    public var offset: Double = 0
    /// Lower music under voiceover/mic.
    public var duck: Bool = true
    /// Tempo and first-downbeat time (seconds into the file), from generation or analysis.
    public var bpm: Double? = nil
    public var beatOffset: Double? = nil
    public var beatsPerBar: Int = 4
    /// How this track was made (kept so it can be regenerated at a new length).
    public var generate: MusicGenSpec? = nil
    /// Catalog reference, e.g. "incompetech:Carefree" or "licensed:Epidemic/Track.mp3".
    public var track: String? = nil
    public var title: String? = nil
    public var artist: String? = nil
    /// License and the credit line it requires (written to credits.txt and, for CC BY, shown on screen).
    public var license: MusicLicense? = nil
    /// Show the credit on screen at the end (nil = the app setting; on by default for CC BY).
    public var showCredit: Bool? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case path, volume, fadeIn, fadeOut, offset, duck, bpm, beatOffset, beatsPerBar, generate, track, title, artist, license, showCredit }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = MusicSpec()
        path = try c.decodeIfPresent(String.self, forKey: .path); volume = try c.v(.volume, z.volume)
        fadeIn = try c.v(.fadeIn, z.fadeIn); fadeOut = try c.v(.fadeOut, z.fadeOut); offset = try c.v(.offset, z.offset)
        duck = try c.v(.duck, z.duck); bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        beatOffset = try c.decodeIfPresent(Double.self, forKey: .beatOffset); beatsPerBar = try c.v(.beatsPerBar, z.beatsPerBar)
        generate = try c.decodeIfPresent(MusicGenSpec.self, forKey: .generate)
        track = try c.decodeIfPresent(String.self, forKey: .track); title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist); license = try c.decodeIfPresent(MusicLicense.self, forKey: .license)
        showCredit = try c.decodeIfPresent(Bool.self, forKey: .showCredit)
    }

    /// Output-time beat grid for this track (music starts at output 0, `offset` seconds into the file).
    public var grid: BeatGrid? {
        guard let bpm, bpm > 20 else { return nil }
        return BeatGrid(bpm: bpm, firstBeat: (beatOffset ?? 0) - offset, beatsPerBar: beatsPerBar)
    }
}

public struct MusicLicense: Codable, Equatable {
    /// "CC BY 4.0", "Epidemic Sound subscription", "Generated (Pretty Studio)", ...
    public var name: String
    public var url: String? = nil
    /// The exact credit line to publish (nil when none is required).
    public var credit: String? = nil
    public var requiresCredit: Bool = false
    /// incompetech | licensed | generated | file
    public var source: String = "file"
    /// Caveats agents must pass on ("verify the license covers paid ads", ...).
    public var notes: String? = nil
    public init(name: String, url: String? = nil, credit: String? = nil, requiresCredit: Bool = false, source: String = "file", notes: String? = nil) {
        self.name = name; self.url = url; self.credit = credit; self.requiresCredit = requiresCredit; self.source = source; self.notes = notes
    }
    enum CodingKeys: String, CodingKey { case name, url, credit, requiresCredit, source, notes }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.v(.name, "unknown"); url = try c.decodeIfPresent(String.self, forKey: .url)
        credit = try c.decodeIfPresent(String.self, forKey: .credit); requiresCredit = try c.v(.requiresCredit, false)
        source = try c.v(.source, "file"); notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

public struct WordTime: Codable, Equatable {
    public var w: String
    /// Seconds from the start of the clip.
    public var t: Double
    public init(w: String, t: Double) { self.w = w; self.t = t }
}

public struct VoiceClip: Codable, Equatable {
    public var path: String
    /// Output time in seconds.
    public var at: Double = 0
    public var volume: Double = 1
    /// What is said (drives captions) and when each word starts.
    public var text: String? = nil
    public var duration: Double? = nil
    public var words: [WordTime]? = nil
    /// output (default) | source — source-time clips stay attached to the content through edits.
    public var time: String? = nil
    public init(path: String, at: Double, volume: Double = 1, text: String? = nil, duration: Double? = nil, words: [WordTime]? = nil, time: String? = nil) {
        self.path = path; self.at = at; self.volume = volume; self.text = text; self.duration = duration; self.words = words; self.time = time
    }
    enum CodingKeys: String, CodingKey { case path, at, volume, text, duration, words, time }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); at = try c.v(.at, 0); volume = try c.v(.volume, 1)
        text = try c.decodeIfPresent(String.self, forKey: .text); duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        words = try c.decodeIfPresent([WordTime].self, forKey: .words)
        time = try c.decodeIfPresent(String.self, forKey: .time)
    }
}

public struct VoiceSpec: Codable, Equatable {
    /// elevenlabs | openai. nil = the provider chosen in Pretty Studio's setup.
    /// There is no on-device voice: narration is studio-grade or absent.
    public var provider: String? = nil
    /// Voice id or name (ElevenLabs voice_id / name; OpenAI: marin, cedar, coral, ...). nil = setup default.
    public var voice: String? = nil
    /// eleven_v4 (default) · eleven_multilingual_v2 · gpt-4o-mini-tts
    public var model: String? = nil
    /// Delivery speed (1 = natural; 1.05-1.1 suits ads).
    public var speed: Double? = nil
    /// ElevenLabs expressiveness (0-1) and stability (0-1).
    public var style: Double? = nil
    public var stability: Double? = nil
    /// OpenAI delivery direction ("Warm, upbeat product narrator").
    public var instructions: String? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case provider, voice, model, speed, style, stability, instructions, name, rate }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        // Older projects: {name, rate, pitch} for system voices.
        if voice == nil, let n = try c.decodeIfPresent(String.self, forKey: .name), n != "auto", !n.isEmpty, provider != nil { voice = n }
        model = try c.decodeIfPresent(String.self, forKey: .model)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        if speed == nil, let r = try c.decodeIfPresent(Double.self, forKey: .rate), r != 1 { speed = r }
        style = try c.decodeIfPresent(Double.self, forKey: .style)
        stability = try c.decodeIfPresent(Double.self, forKey: .stability)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(provider, forKey: .provider); try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(model, forKey: .model); try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(style, forKey: .style); try c.encodeIfPresent(stability, forKey: .stability)
        try c.encodeIfPresent(instructions, forKey: .instructions)
    }
}

public struct AudioSpec: Codable, Equatable {
    /// What the soundtrack carries: auto | none | music | voiceover | both.
    /// "auto" picks per platform (see `AudioPlan.resolve`); agents should set it deliberately.
    public var mode: String = "auto"
    public var voice = VoiceSpec()
    /// Include system audio recorded with the screen.
    public var system: Bool = true
    public var systemVolume: Double = 1
    /// Include microphone audio.
    public var mic: Bool = true
    public var micVolume: Double = 1
    public var music = MusicSpec()
    public var voiceover: [VoiceClip] = []
    /// Subtle click sound on every mouse click / tap.
    public var clickSounds: Bool = false
    public var clickVolume: Double = 0.5
    /// Loudness-normalize the final mix to -14 LUFS (social standard).
    public var normalize: Bool = true
    /// Sound design: whooshes on transitions, impacts on reveals (OUTPUT time).
    public var sfx: [SfxClip] = []
    public var sfxVolume: Double = 1
    public init() {}
    enum CodingKeys: String, CodingKey { case mode, voice, system, systemVolume, mic, micVolume, music, voiceover, clickSounds, clickVolume, normalize, sfx, sfxVolume }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = AudioSpec()
        mode = try c.v(.mode, z.mode); voice = try c.v(.voice, z.voice)
        system = try c.v(.system, z.system); systemVolume = try c.v(.systemVolume, z.systemVolume)
        mic = try c.v(.mic, z.mic); micVolume = try c.v(.micVolume, z.micVolume); music = try c.v(.music, z.music)
        voiceover = try c.v(.voiceover, z.voiceover); clickSounds = try c.v(.clickSounds, z.clickSounds)
        clickVolume = try c.v(.clickVolume, z.clickVolume); normalize = try c.v(.normalize, z.normalize)
        sfx = try c.v(.sfx, z.sfx); sfxVolume = try c.v(.sfxVolume, z.sfxVolume)
    }
}

public struct SfxClip: Codable, Equatable {
    public var path: String
    /// Output time the sound starts.
    public var at: Double
    public var volume: Double = 0.5
    /// whoosh | impact | shimmer | tap | riser (informational)
    public var kind: String? = nil
    public init(path: String, at: Double, volume: Double = 0.5, kind: String? = nil) { self.path = path; self.at = at; self.volume = volume; self.kind = kind }
    enum CodingKeys: String, CodingKey { case path, at, volume, kind }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); at = try c.v(.at, 0); volume = try c.v(.volume, 0.5)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }
}

// MARK: - Export

public struct ExportSpec: Codable, Equatable {
    /// Named preset (see `pretty presets`). Explicit fields below override it.
    public var preset: String? = nil
    /// 720p | 1080p | 1440p | 4k | original — applies to the output's shorter side.
    public var resolution: String? = nil
    public var width: Int? = nil
    public var height: Int? = nil
    public var fps: Int? = nil
    /// mp4 | mov | gif | webm | png (still)
    public var format: String? = nil
    /// h264 | hevc | prores
    public var codec: String? = nil
    /// low | medium | high | max
    public var quality: String? = nil
    public var audio: Bool? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case preset, resolution, width, height, fps, format, codec, quality, audio }
}

// MARK: - Brand

public struct BrandSpec: Codable, Equatable {
    public var name: String? = nil
    /// Brand colors, most important first; "brand:N" anywhere in the project resolves here.
    public var colors: [String] = []
    /// Font file or installed font name for text overlays and scenes.
    public var font: String? = nil
    public var logo: String? = nil
    /// App icon (square image) for lockups.
    public var icon: String? = nil
    /// The product's own one-line promise (from its site/App Store page), for end cards.
    public var tagline: String? = nil
    /// Where to get it: "deltabinder.com", "Download on the App Store".
    public var cta: String? = nil
    public var url: String? = nil
    public init() {}
    enum CodingKeys: String, CodingKey { case name, colors, font, logo, icon, tagline, cta, url }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        colors = try c.v(.colors, [])
        font = try c.decodeIfPresent(String.self, forKey: .font)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        cta = try c.decodeIfPresent(String.self, forKey: .cta)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

/// A 3D device shot: the recording's screen on a real 3D device (phone or tablet), animated by a
/// camera template. A component of a video — it replaces the flat device for its duration.
public struct DeviceShot: Codable, Equatable {
    public var start: Double
    public var duration: Double
    /// hero | orbit | rise | tilt | spin | float | flat | dolly | closeup | duo | slide | turntable
    public var move: String = "hero"
    /// Device finish (default: frame.color): black | natural | silver | white | blue | desert | gold
    public var finish: String? = nil
    /// Glossy floor reflection under the device (Apple-stage look).
    public var reflection: Bool = false
    /// closeup: the point of the screen to move in on (normalized 0-1).
    public var focus: NPoint? = nil
    /// duo: the second device shows the recording this many seconds later (or earlier, negative).
    public var offset: Double? = nil
    public init(start: Double, duration: Double, move: String = "hero") { self.start = start; self.duration = duration; self.move = move }
    enum CodingKeys: String, CodingKey { case start, duration, move, finish, reflection, focus, offset }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.v(.start, 0); duration = try c.v(.duration, 3); move = try c.v(.move, "hero")
        finish = try c.decodeIfPresent(String.self, forKey: .finish); reflection = try c.v(.reflection, false)
        focus = try c.decodeIfPresent(NPoint.self, forKey: .focus); offset = try c.decodeIfPresent(Double.self, forKey: .offset)
    }
    public var end: Double { start + duration }
}

/// A move of the device in 3D space (output time). Entrances (rise, tilt) play over their first
/// second; holds (push, drift, orbit, float) span the whole segment.
public struct DeviceMove: Codable, Equatable {
    public var start: Double
    public var end: Double
    /// rise | tilt | orbit | push | drift | float
    public var type: String
    public var amount: Double = 1
    public init(start: Double, end: Double, type: String, amount: Double = 1) { self.start = start; self.end = end; self.type = type; self.amount = amount }
    enum CodingKeys: String, CodingKey { case start, end, type, amount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.v(.start, 0); end = try c.v(.end, 1); type = try c.v(.type, "push"); amount = try c.v(.amount, 1)
    }
}

/// A full-screen kinetic-type moment: no device, just the words, on the brand.
public struct TextScene: Codable, Equatable {
    /// Output time and length (seconds).
    public var start: Double = 0
    public var duration: Double = 2.5
    /// statement | punch | stack | reveal | type | count | lockup
    public var style: String = "statement"
    public var text: String? = nil
    /// stack/reveal lines (otherwise `text` split on "\n").
    public var lines: [String]? = nil
    /// Supporting line (lockup tagline, count label, statement kicker).
    public var sub: String? = nil
    /// Words to set in the accent color ("Price", "instantly").
    public var accent: [String] = []
    /// Swipe a highlighter behind accent words.
    public var marker: Bool = false
    /// When each word (statement/punch/type) or line (stack/reveal) lands, seconds from `start`.
    /// The planner fills these from narration word timings or the music's beats.
    public var times: [Double]? = nil
    /// keynote | studio | glow | paper | cinema | brand | dark | light | content (the recording, blurred)
    /// | clip:<video path> (e.g. AI B-roll) | a gradient preset | "#RRGGBB"
    public var background: String = "keynote"
    public var color: String? = nil
    public var accentColor: String? = nil
    /// center | left
    public var align: String = "center"
    /// count: the number to land on, with optional prefix/suffix ("$", "+", "k").
    public var value: Double? = nil
    public var prefix: String? = nil
    public var suffix: String? = nil
    /// lockup: icon (default brand.icon), name (default brand.name), CTA pill (default brand.cta).
    public var icon: String? = nil
    public var cta: String? = nil
    /// auto | dissolve | lift | zoom | fade | slide | cut
    public var transition: String = "auto"
    public var transitionDuration: Double = 0.4
    /// Text size multiplier, font override (a name, a .ttf path, "serif", "mono", "rounded"), weight override.
    public var size: Double = 1
    public var font: String? = nil
    public var weight: String? = nil
    /// Words set in the quieter secondary color (Apple-style two-tone: "Your cards. *All together.*").
    public var secondary: [String] = []
    /// statement: reveal by lines (default) or words.
    public var reveal: String? = nil
    /// Seconds into a clip background where this scene starts (clip:<path> backgrounds).
    public var clipStart: Double = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case start, duration, style, text, lines, sub, accent, marker, times, background, color, accentColor, align, value, prefix, suffix, icon, cta, transition, transitionDuration, size, font, weight, secondary, reveal, clipStart }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = TextScene()
        start = try c.v(.start, z.start); duration = try c.v(.duration, z.duration); style = try c.v(.style, z.style)
        text = try c.decodeIfPresent(String.self, forKey: .text); lines = try c.decodeIfPresent([String].self, forKey: .lines)
        sub = try c.decodeIfPresent(String.self, forKey: .sub); accent = try c.v(.accent, z.accent); marker = try c.v(.marker, z.marker)
        times = try c.decodeIfPresent([Double].self, forKey: .times); background = try c.v(.background, z.background)
        color = try c.decodeIfPresent(String.self, forKey: .color); accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        align = try c.v(.align, z.align); value = try c.decodeIfPresent(Double.self, forKey: .value)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix); suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        icon = try c.decodeIfPresent(String.self, forKey: .icon); cta = try c.decodeIfPresent(String.self, forKey: .cta)
        transition = try c.v(.transition, z.transition); transitionDuration = try c.v(.transitionDuration, z.transitionDuration)
        size = try c.v(.size, z.size); font = try c.decodeIfPresent(String.self, forKey: .font); weight = try c.decodeIfPresent(String.self, forKey: .weight)
        secondary = try c.v(.secondary, z.secondary); reveal = try c.decodeIfPresent(String.self, forKey: .reveal)
        clipStart = try c.v(.clipStart, z.clipStart)
    }
    public var end: Double { start + duration }
    public var allLines: [String] { lines ?? (text ?? "").components(separatedBy: "\n").filter { !$0.isEmpty } }
}

// MARK: - Geometry primitives

public struct NPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct NRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ def: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? def()
    }
}
