import Foundation
import CryptoKit

/// Generative video for B-roll: the human, emotional and atmospheric shots a screen recording can't
/// give you (hands sliding a card into a binder, a quiet desk at night, light across glass).
/// Providers: Google Veo (Gemini API), OpenAI Sora 2, fal.ai (Kling, Veo, Seedance… with one key).
/// The app's UI is never generated — models can't render a real interface faithfully; product shots
/// always come from the recording.
public enum VideoAI {
    public static let providers = ["veo", "sora", "fal"]
    static let keyFor = ["veo": "gemini", "sora": "openai", "fal": "fal"]

    public struct Request {
        public var prompt: String
        public var provider: String
        public var model: String? = nil
        public var seconds: Int = 6
        /// 9:16 | 16:9 | 1:1
        public var aspect: String = "9:16"
        public var image: URL? = nil
        public var negative: String? = nil
        public init(prompt: String, provider: String) { self.prompt = prompt; self.provider = provider }
    }

    public struct Clip: Codable {
        public var file: String
        public var provider: String
        public var model: String
        public var prompt: String
        public var seconds: Double
        public var created: String
    }

    static var geminiBase: URL { HTTP.base("PRETTY_GEMINI_BASE", "https://generativelanguage.googleapis.com") }
    static var openAIBase: URL { HTTP.base("PRETTY_OPENAI_BASE", "https://api.openai.com") }
    static var falBase: URL { HTTP.base("PRETTY_FAL_BASE", "https://queue.fal.run") }

    /// Providers with a key on this Mac, best first.
    public static func available() -> [String] { providers.filter { Secrets.get(keyFor[$0]!) != nil } }

    public static func defaultModel(_ p: String) -> String {
        switch p {
        case "veo": return "veo-3.1-generate-preview"
        case "sora": return "sora-2"
        default: return "fal-ai/kling-video/v2.5-turbo/pro/text-to-video"
        }
    }

    /// The house style every prompt gets: cinematic, premium, and free of text/logos/UI.
    public static func styled(_ prompt: String, treatment: Treatment?) -> (String, String) {
        let look: String
        switch treatment?.name {
        case "studio": look = "bright soft studio light, clean seamless backdrop, crisp, premium commercial"
        case "editorial": look = "warm natural window light, film-like texture, intimate editorial photography"
        case "cinematic": look = "cinematic low-key lighting, anamorphic, shallow depth of field, slow dolly, film grade"
        case "glow": look = "moody dark set with soft colored light, glossy reflections, shallow depth of field"
        default: look = "cinematic, soft key light against a dark background, shallow depth of field, slow camera move, premium commercial"
        }
        return ("\(prompt). \(look). No text, no captions, no logos, no on-screen UI.",
                "text, captions, subtitles, watermark, logo, app interface, phone screen UI, distorted hands, extra fingers, warped faces, low quality")
    }

    public static func generate(_ r: Request, to dir: URL) throws -> Clip {
        guard providers.contains(r.provider) else { throw fail("video provider must be one of \(providers.joined(separator: ", "))") }
        guard let key = Secrets.get(keyFor[r.provider]!) else {
            throw fail("no \(r.provider) key — add it in Pretty Studio → Settings → Video, or `pretty keys set \(keyFor[r.provider]!)`")
        }
        let model = r.model ?? defaultModel(r.provider)
        let base = r.provider == "veo" ? geminiBase : r.provider == "sora" ? openAIBase : falBase
        let h = SHA256.hash(data: Data([r.provider, model, r.prompt, r.negative ?? "", String(r.seconds), r.aspect, r.image?.path ?? "", base.absoluteString].joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(20)
        let cacheDir = Paths.cache.appendingPathComponent("broll")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(h).mp4")
        if !FileManager.default.fileExists(atPath: cached.path) {
            Log.info("generating a \(r.seconds)s \(r.aspect) clip with \(r.provider) (\(model)) — this takes a minute or two…")
            switch r.provider {
            case "veo": try veo(r, model: model, key: key, to: cached)
            case "sora": try sora(r, model: model, key: key, to: cached)
            default: try fal(r, model: model, key: key, to: cached)
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("broll-\(h).mp4")
        if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: cached, to: dst) }
        let f = ISO8601DateFormatter()
        let clip = Clip(file: dst.path, provider: r.provider, model: model, prompt: r.prompt, seconds: (try? AssetInfo.load(dst).duration) ?? Double(r.seconds), created: f.string(from: Date()))
        try? prettyJSON(clip).write(to: dst.deletingPathExtension().appendingPathExtension("json"))
        return clip
    }

    static func poll(_ deadline: TimeInterval = 600, every: TimeInterval = 5, _ check: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if try check() { return }
            Thread.sleep(forTimeInterval: every)
        }
        throw fail("video generation timed out")
    }

    // MARK: Google Veo (Gemini API)

    static func veo(_ r: Request, model: String, key: String, to out: URL) throws {
        var instance: [String: Any] = ["prompt": r.prompt]
        if let img = r.image, let d = try? Data(contentsOf: img) {
            instance["image"] = ["bytesBase64Encoded": d.base64EncodedString(), "mimeType": img.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"]
        }
        var params: [String: Any] = ["aspectRatio": r.aspect == "1:1" ? "9:16" : r.aspect, "durationSeconds": [4, 6, 8].min { abs($0 - r.seconds) < abs($1 - r.seconds) }!]
        if let n = r.negative { params["negativePrompt"] = n }
        let start = try HTTP.json(geminiBase.appendingPathComponent("v1beta/models/\(model):predictLongRunning"), headers: ["x-goog-api-key": key],
                                  body: ["instances": [instance], "parameters": params], timeout: 60)
        guard start.ok, let name = start.json()?["name"] as? String else { throw fail("Veo (\(start.status)): \(start.errorMessage)") }
        var uri: String? = nil
        try poll {
            let s = try HTTP.request(geminiBase.appendingPathComponent("v1beta/\(name)"), headers: ["x-goog-api-key": key], timeout: 30)
            guard s.ok, let j = s.json() else { throw fail("Veo status (\(s.status)): \(s.errorMessage)") }
            if let e = j["error"] as? [String: Any] { throw fail("Veo: \(e["message"] as? String ?? "failed")") }
            guard (j["done"] as? Bool) == true else { return false }
            let resp = j["response"] as? [String: Any]
            let samples = ((resp?["generateVideoResponse"] as? [String: Any])?["generatedSamples"] as? [[String: Any]]) ?? []
            uri = (samples.first?["video"] as? [String: Any])?["uri"] as? String
            if uri == nil { throw fail("Veo finished without a video (it may have been filtered — rephrase the prompt)") }
            return true
        }
        guard let u = URL(string: uri!) else { throw fail("Veo returned a bad video URL") }
        // The key only ever goes to the Gemini API host; anything else is fetched without it.
        try HTTP.download(u, to: out, headers: HTTP.sameHost(u, geminiBase) ? ["x-goog-api-key": key] : [:])
    }

    // MARK: OpenAI Sora 2

    static func sora(_ r: Request, model: String, key: String, to out: URL) throws {
        let size = r.aspect == "16:9" ? "1280x720" : "720x1280"
        let secs = [4, 8, 12].min { abs($0 - r.seconds) < abs($1 - r.seconds) }!
        let fields: [(String, String)] = [("model", model), ("prompt", r.prompt), ("seconds", String(secs)), ("size", size)]
        let resp: HTTP.Response
        if let img = r.image, let d = try? Data(contentsOf: img) {
            resp = try HTTP.multipart(openAIBase.appendingPathComponent("v1/videos"), headers: ["Authorization": "Bearer \(key)"], fields: fields,
                                      file: (name: "input_reference", filename: img.lastPathComponent, mime: img.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg", data: d))
        } else {
            resp = try HTTP.json(openAIBase.appendingPathComponent("v1/videos"), headers: ["Authorization": "Bearer \(key)"],
                                 body: ["model": model, "prompt": r.prompt, "seconds": String(secs), "size": size], timeout: 60)
        }
        guard resp.ok, let id = resp.json()?["id"] as? String else { throw fail("Sora (\(resp.status)): \(resp.errorMessage)") }
        try poll {
            let s = try HTTP.request(openAIBase.appendingPathComponent("v1/videos/\(id)"), headers: ["Authorization": "Bearer \(key)"], timeout: 30)
            guard s.ok, let j = s.json() else { throw fail("Sora status (\(s.status)): \(s.errorMessage)") }
            switch j["status"] as? String {
            case "completed": return true
            case "failed": throw fail("Sora: \(((j["error"] as? [String: Any])?["message"] as? String) ?? "generation failed")")
            default: return false
            }
        }
        try HTTP.download(openAIBase.appendingPathComponent("v1/videos/\(id)/content"), to: out, headers: ["Authorization": "Bearer \(key)"])
    }

    // MARK: fal.ai (queue API)

    static func fal(_ r: Request, model: String, key: String, to out: URL) throws {
        var body: [String: Any] = ["prompt": r.prompt, "aspect_ratio": r.aspect, "duration": String(r.seconds <= 5 ? 5 : 10)]
        if let n = r.negative { body["negative_prompt"] = n }
        if let img = r.image, let d = try? Data(contentsOf: img) {
            body["image_url"] = "data:image/\(img.pathExtension.lowercased() == "png" ? "png" : "jpeg");base64,\(d.base64EncodedString())"
        }
        let start = try HTTP.json(falBase.appendingPathComponent(model), headers: ["Authorization": "Key \(key)"], body: body, timeout: 60)
        guard start.ok, let j = start.json(), let statusURL = (j["status_url"] as? String).flatMap(URL.init(string:)),
              let responseURL = (j["response_url"] as? String).flatMap(URL.init(string:)) else { throw fail("fal (\(start.status)): \(start.errorMessage)") }
        // These come back from the API; the key is only sent to fal's own queue host.
        guard HTTP.sameHost(statusURL, falBase), HTTP.sameHost(responseURL, falBase) else { throw fail("fal returned URLs on an unexpected host — not sending the key there") }
        try poll {
            let s = try HTTP.request(statusURL, headers: ["Authorization": "Key \(key)"], timeout: 30)
            guard s.ok || s.status == 202, let sj = s.json() else { throw fail("fal status (\(s.status)): \(s.errorMessage)") }
            if (sj["status"] as? String) == "COMPLETED" { return true }
            if let e = sj["error"] as? String { throw fail("fal: \(e)") }
            return false
        }
        let res = try HTTP.request(responseURL, headers: ["Authorization": "Key \(key)"], timeout: 60)
        guard res.ok, let rj = res.json(), let vurl = ((rj["video"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
            throw fail("fal returned no video (\(res.status)): \(res.errorMessage)")
        }
        try HTTP.download(vurl, to: out)
    }

    // MARK: Keys

    public static func test(account: String, key: String) throws -> String {
        switch account {
        case "gemini":
            let r = try HTTP.request(geminiBase.appendingPathComponent("v1beta/models"), headers: ["x-goog-api-key": Secrets.sanitize(key)], timeout: 20)
            guard r.ok else { throw fail("Google rejected the key (\(r.status)): \(r.errorMessage)") }
            let models = ((r.json()?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return models.contains { $0.contains("veo") } ? "Gemini key works (Veo available)" : "Gemini key works (Veo not listed for this key/region)"
        case "fal":
            let k = Secrets.sanitize(key)
            guard k.contains(":") || k.count > 20 else { throw fail("that doesn't look like a fal key (id:secret)") }
            return "fal key saved (checked on first use)"
        default:
            return try Narrator.test(provider: account, key: key)
        }
    }
}
