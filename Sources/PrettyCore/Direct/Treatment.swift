import Foundation

/// A creative direction: one coherent look, motion vocabulary and sound for a whole video.
/// Treatments keep ads modern and restrained, and picking a different one (plus seeded variation
/// inside it) keeps consecutive generations from looking alike.
public struct Treatment {
    public var name: String
    public var summary: String
    /// Device backdrop (`BackgroundSpec.type = "stage"`, preset = this).
    public var stage: String
    /// Scene backgrounds to alternate between (Kinetic background names).
    public var sceneBackgrounds: [String]
    /// Device frame finish and theme.
    public var frameColor: String
    public var frameTheme: String
    public var shadow: Double
    /// Type: alignment choices, primary weight, how statements reveal.
    public var aligns: [String]
    public var weight: String
    public var reveal: String // lines | words
    /// Use a serif display face (New York) instead of the brand font for scenes.
    public var serif: Bool
    /// Transitions between scenes and the device.
    public var transitions: [String]
    /// Device moves for device beats (first entry is the entrance).
    public var entrances: [String]
    public var holds: [String]
    /// Music direction for composed scores.
    public var musicStyles: [String]
    public var musicAvoid: [String]
    public var bpm: ClosedRange<Double>
    /// Catalog moods when a real track is searched instead of composed.
    public var catalogMood: String
    /// Sound design character.
    public var sfx: String
    /// 3D shot camera templates that suit this treatment, and whether the stage has a glossy floor.
    public var shotMoves: [String] = ["hero"]
    public var reflection: Bool = false

    public static let all: [Treatment] = [
        Treatment(name: "keynote", summary: "Black stage, soft spotlight, white type with gray continuation — Apple keynote calm",
                  stage: "keynote", sceneBackgrounds: ["keynote", "glow"], frameColor: "black", frameTheme: "dark", shadow: 0.85,
                  aligns: ["center"], weight: "semibold", reveal: "lines", serif: false,
                  transitions: ["dissolve", "dissolve", "lift"], entrances: ["rise", "tilt"], holds: ["push", "drift"],
                  musicStyles: ["cinematic minimal electronic", "warm analog synth pads", "soft felt piano motif", "gentle pulsing bass",
                                "steady modern drums entering later", "uplifting, confident, premium", "polished mix, wide stereo"],
                  musicAvoid: ["vocals", "singing", "ukulele", "whistling", "kazoo", "comedic", "cheesy", "corporate stock music", "glockenspiel"],
                  bpm: 92...108, catalogMood: "cinematic", sfx: "airy cinematic whoosh, soft sub impact, glassy shimmer", shotMoves: ["hero", "rise", "dolly", "closeup"], reflection: true),
        Treatment(name: "studio", summary: "Light seamless studio, crisp dark type, product-page clarity",
                  stage: "studio", sceneBackgrounds: ["studio", "paper"], frameColor: "natural", frameTheme: "light", shadow: 0.6,
                  aligns: ["center", "left"], weight: "semibold", reveal: "lines", serif: false,
                  transitions: ["dissolve", "lift", "cut"], entrances: ["tilt", "rise"], holds: ["drift", "push"],
                  musicStyles: ["clean modern electronic", "bright plucked synths", "light crisp percussion", "airy, optimistic, restrained",
                                "minimal and precise", "polished mix"],
                  musicAvoid: ["vocals", "ukulele", "whistling", "comedic", "cheesy", "corporate stock music", "heavy drops"],
                  bpm: 100...118, catalogMood: "corporate", sfx: "clean soft whoosh, light click, subtle tick", shotMoves: ["tilt", "flat", "slide", "duo"], reflection: false),
        Treatment(name: "glow", summary: "Near-black stage with the brand's color glowing behind the device — vivid, emotional",
                  stage: "glow", sceneBackgrounds: ["glow", "keynote"], frameColor: "black", frameTheme: "dark", shadow: 0.8,
                  aligns: ["center"], weight: "bold", reveal: "words", serif: false,
                  transitions: ["dissolve", "zoom", "lift"], entrances: ["rise", "orbit"], holds: ["push", "drift"],
                  musicStyles: ["atmospheric electronic", "deep sub pulse", "shimmering arpeggios", "emotional build with a satisfying lift",
                                "modern cinematic sound design", "wide, glossy mix"],
                  musicAvoid: ["vocals", "ukulele", "whistling", "comedic", "cheesy", "corporate stock music", "dubstep"],
                  bpm: 96...116, catalogMood: "cinematic", sfx: "deep whoosh, bright shimmer riser, warm boom", shotMoves: ["orbit", "turntable", "duo", "hero"], reflection: true),
        Treatment(name: "editorial", summary: "Warm paper, large left-aligned type, generous space — magazine restraint",
                  stage: "paper", sceneBackgrounds: ["paper", "studio"], frameColor: "silver", frameTheme: "light", shadow: 0.5,
                  aligns: ["left"], weight: "bold", reveal: "lines", serif: true,
                  transitions: ["cut", "dissolve", "lift"], entrances: ["tilt", "rise"], holds: ["drift"],
                  musicStyles: ["minimal piano", "soft strings", "intimate and warm", "subtle tape texture", "slow build, tender resolve",
                                "clean acoustic production"],
                  musicAvoid: ["vocals", "ukulele", "whistling", "comedic", "cheesy", "edm", "trap drums"],
                  bpm: 80...96, catalogMood: "minimal", sfx: "paper swish, soft felt thump, gentle chime", shotMoves: ["flat", "tilt", "slide"], reflection: false),
        Treatment(name: "cinematic", summary: "Deep graded dark, slow push-ins, serif titles — film-trailer emotion",
                  stage: "cinema", sceneBackgrounds: ["cinema", "content"], frameColor: "black", frameTheme: "dark", shadow: 0.9,
                  aligns: ["center"], weight: "regular", reveal: "words", serif: true,
                  transitions: ["dissolve", "dissolve", "cut"], entrances: ["rise", "orbit"], holds: ["push"],
                  musicStyles: ["cinematic score", "swelling strings", "felt piano", "deep low percussion hits", "emotional, building to a powerful resolve",
                                "trailer-grade production, no cliches"],
                  musicAvoid: ["vocals", "ukulele", "whistling", "comedic", "cheesy", "corporate stock music", "edm drop"],
                  bpm: 84...100, catalogMood: "dramatic", sfx: "cinematic whoosh, low boom, reverse swell", shotMoves: ["rise", "dolly", "closeup", "orbit"], reflection: false),
    ]

    public static func named(_ n: String) -> Treatment? { all.first { $0.name == n.lowercased() } }

    /// Deterministic per-video choice that avoids the last treatments used for this project.
    public static func pick(seed: UInt64, avoid: [String]) -> Treatment {
        var rng = SeedRNG(seed: seed)
        let fresh = all.filter { !avoid.suffix(2).contains($0.name) }
        let pool = fresh.isEmpty ? all : fresh
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    /// Seeded choice from a vocabulary.
    public func choose<T>(_ xs: [T], _ rng: inout SeedRNG) -> T { xs[Int(rng.next() % UInt64(max(1, xs.count)))] }
}

public struct SeedRNG {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// What earlier videos for a project looked and sounded like, so the next one doesn't repeat them.
public struct History: Codable {
    public struct Entry: Codable {
        public var date: String
        public var name: String
        public var treatment: String
        public var music: String?
        public var styles: [String]
    }
    public var entries: [Entry] = []
    public init() {}

    public static func load(_ u: URL?) -> History {
        guard let u, let d = try? Data(contentsOf: u), let h = try? JSONDecoder().decode(History.self, from: d) else { return History() }
        return h
    }
    public func save(_ u: URL?) {
        guard let u else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? prettyJSON(self).write(to: u)
    }
    public var recentTreatments: [String] { entries.suffix(4).map(\.treatment) }
    public var recentMusic: [String] { entries.suffix(6).compactMap(\.music) }
}
