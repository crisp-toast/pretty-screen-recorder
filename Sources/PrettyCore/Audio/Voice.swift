import Foundation

/// Word-timing utilities shared by narration (see `Narrator`) and imported voiceover files.
/// (There is no on-device speech synthesis: system voices aren't good enough for product videos.)
public enum Voice {
    /// Spread words over a clip by character weight (for imported voiceover files).
    public static func estimateWords(_ text: String, duration: Double, leadIn: Double = 0.05) -> [WordTime] {
        let ws = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let weights = ws.map { Double(max(2, $0.count)) + ($0.last.map { ",.;:!?".contains($0) } == true ? 3 : 0) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var t = leadIn, out: [WordTime] = []
        let span = max(0.1, duration - leadIn - 0.1)
        for (w, wt) in zip(ws, weights) { out.append(WordTime(w: w, t: round3(t))); t += span * wt / total }
        return out
    }

    /// Find a word's start time: "saved", "saved#2" (second occurrence), case/punctuation-insensitive.
    public static func time(of query: String, in words: [WordTime]) -> Double? {
        var q = query.lowercased(), nth = 1
        if let h = q.firstIndex(of: "#"), let n = Int(q[q.index(after: h)...]) { nth = n; q = String(q[..<h]) }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let target = norm(q)
        var seen = 0
        for w in words where norm(w.w) == target || norm(w.w).hasPrefix(target) && target.count >= 4 {
            seen += 1
            if seen == nth { return w.t }
        }
        return nil
    }
}
