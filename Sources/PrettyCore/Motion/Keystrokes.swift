import Foundation

/// What the keystroke overlay shows over time (in SOURCE time).
public struct KeystrokeItem {
    public var start: Double
    public var end: Double
    /// Keycaps for shortcuts (["⌘", "⇧", "K"]), or a single typed-text cap that grows.
    public var caps: [String]
    /// For typed text: (time, text so far) so the text grows as keys are pressed.
    public var typing: [(Double, String)] = []
    public var isTyping: Bool { !typing.isEmpty }

    public func caps(at s: Double) -> [String] {
        guard isTyping else { return caps }
        var cur = typing.first?.1 ?? ""
        for (t, txt) in typing { if t <= s { cur = txt } else { break } }
        return [cur]
    }
}

public enum Keystrokes {
    static let modOrder = ["ctrl", "opt", "shift", "cmd", "fn"]
    static let modSymbol = ["ctrl": "⌃", "opt": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "meta": "⌘", "fn": "fn"]
    static let keySymbol: [String: String] = [
        "return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦",
        "escape": "esc", "esc": "esc", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
        "pageup": "⇞", "pagedown": "⇟", "capslock": "⇪",
    ]

    public static func symbol(for key: String) -> String {
        let k = key.lowercased()
        if let s = keySymbol[k] { return s }
        if k.hasPrefix("f"), Int(k.dropFirst()) != nil { return key.uppercased() }
        return key.count == 1 ? key.uppercased() : key.capitalized
    }

    public static func items(events: InputEvents, spec: KeystrokeSpec) -> [KeystrokeItem] {
        guard spec.show else { return [] }
        var out: [KeystrokeItem] = []
        let keys = events.keys.sorted { $0.t < $1.t }
        var typingRun: KeystrokeItem? = nil
        func flushTyping() { if let r = typingRun { out.append(r); typingRun = nil } }

        for k in keys {
            let mods = modOrder.filter { m in k.mods.contains { $0 == m || (m == "opt" && $0 == "alt") || (m == "cmd" && $0 == "meta") } }
            if k.isShortcut || (spec.mode == "all" && keySymbol[k.key.lowercased()] != nil && k.key.lowercased() != "space") {
                if !k.isShortcut && spec.mode != "all" { continue }
                flushTyping()
                let caps = mods.compactMap { modSymbol[$0] } + [symbol(for: k.key)]
                if var last = out.last, last.end > k.t { last.end = k.t; out[out.count - 1] = last }
                out.append(KeystrokeItem(start: k.t, end: k.t + spec.hold, caps: caps))
            } else if spec.mode == "all" {
                let ch: String
                if k.key.count == 1 { ch = mods.contains("shift") ? k.key.uppercased() : k.key }
                else if k.key.lowercased() == "space" { ch = " " }
                else { continue }
                if var run = typingRun, k.t - run.end + spec.hold < 1.2 {
                    let text = String(((run.typing.last?.1 ?? "") + ch).suffix(28))
                    run.typing.append((k.t, text)); run.end = k.t + spec.hold
                    typingRun = run
                } else {
                    flushTyping()
                    if var last = out.last, last.end > k.t { last.end = k.t; out[out.count - 1] = last }
                    typingRun = KeystrokeItem(start: k.t, end: k.t + spec.hold, caps: [], typing: [(k.t, ch)])
                }
            }
        }
        flushTyping()
        return out.sorted { $0.start < $1.start }
    }
}
