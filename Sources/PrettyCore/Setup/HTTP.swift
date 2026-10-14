import Foundation

/// Minimal synchronous HTTP for the CLI (agents run one request at a time; the app calls these
/// from background tasks). Never logs headers or bodies — they can carry API keys.
public enum HTTP {
    public struct Response {
        public var status: Int
        public var data: Data
        public var headers: [String: String]
        public var ok: Bool { (200..<300).contains(status) }
        public var text: String { String(decoding: data, as: UTF8.self) }
        public func json() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        /// A short, key-free error message from a JSON error body.
        public var errorMessage: String {
            if let j = json() {
                if let d = j["detail"] as? [String: Any], let m = d["message"] as? String { return m }
                if let d = j["detail"] as? String { return d }
                if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
                if let m = j["message"] as? String { return m }
            }
            return String(text.prefix(300))
        }
    }

    /// Headers that carry credentials. They're never forwarded across a redirect to another host.
    static let credentialHeaders = ["authorization", "xi-api-key", "x-goog-api-key", "api-key", "x-api-key"]

    /// Strips credentials when a server redirects to a different host (a signed download URL, say).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var r = request
            if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() || request.url?.scheme != "https" {
                for h in r.allHTTPHeaderFields?.keys.map({ $0 }) ?? [] where credentialHeaders.contains(h.lowercased()) {
                    r.setValue(nil, forHTTPHeaderField: h)
                }
            }
            completionHandler(r)
        }
    }

    /// Ephemeral: nothing (responses, cookies) is cached to disk.
    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    /// An API base URL, overridable for tests (`PRETTY_*_BASE`) — but only with https or a loopback
    /// mock, so a stray environment variable can't send a real key over plain http to another machine.
    public static func base(_ env: String, _ fallback: String) -> URL {
        if let v = ProcessInfo.processInfo.environment[env], let u = URL(string: v), let host = u.host?.lowercased() {
            if u.scheme == "https" || ["127.0.0.1", "localhost", "::1"].contains(host) { return u }
            Log.warn("ignoring \(env)=\(v): only https or a local mock (127.0.0.1) is allowed")
        }
        return URL(string: fallback)!
    }

    /// True when `url` is on the same host as `base` — the only place an API key may be sent.
    public static func sameHost(_ url: URL, _ base: URL) -> Bool {
        url.host?.lowercased() == base.host?.lowercased() && url.scheme == base.scheme
    }

    public static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 90) throws -> Response {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: r) { d, resp, e in
            box.data = d; box.resp = resp as? HTTPURLResponse; box.error = e
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let e = box.error { throw fail("network error talking to \(url.host ?? "server"): \(e.localizedDescription)") }
        guard let resp = box.resp else { throw fail("no response from \(url.host ?? "server")") }
        var hs: [String: String] = [:]
        for (k, v) in resp.allHeaderFields { hs[String(describing: k).lowercased()] = String(describing: v) }
        return Response(status: resp.statusCode, data: box.data ?? Data(), headers: hs)
    }

    public static func json(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: [String: Any], timeout: TimeInterval = 90) throws -> Response {
        var h = headers
        h["Content-Type"] = "application/json"
        return try request(url, method: method, headers: h, body: try JSONSerialization.data(withJSONObject: body), timeout: timeout)
    }

    /// multipart/form-data upload.
    public static func multipart(_ url: URL, headers: [String: String] = [:], fields: [(String, String)], file: (name: String, filename: String, mime: String, data: Data), timeout: TimeInterval = 120) throws -> Response {
        let boundary = "pretty-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mime)\r\n\r\n")
        body.append(file.data)
        add("\r\n--\(boundary)--\r\n")
        var h = headers
        h["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        return try request(url, method: "POST", headers: h, body: body, timeout: timeout)
    }

    /// Download to a file (atomic: written next to the target, then moved).
    public static func download(_ url: URL, to dst: URL, headers: [String: String] = [:], timeout: TimeInterval = 300) throws {
        let r = try request(url, headers: headers, timeout: timeout)
        guard r.ok, !r.data.isEmpty else { throw fail("download failed (\(r.status)): \(url.absoluteString)") }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).part")
        try r.data.write(to: tmp)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var resp: HTTPURLResponse?
        var error: Error?
    }
}

/// Where Pretty Studio keeps things that aren't projects.
public enum Paths {
    public static let masterStorage = "/Volumes/Master Storage"
    static var ssdMounted: Bool { FileManager.default.fileExists(atPath: masterStorage + "/Projects") }

    /// Re-creatable caches (synthesized narration, catalogs): SSD when mounted, else ~/Library/Caches.
    public static var cache: URL {
        let u = ssdMounted ? URL(fileURLWithPath: "\(masterStorage)/Dev.noindex/pretty-studio/cache")
                           : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pretty Studio")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Downloaded music (kept — renders reference it): SSD Library/Music when mounted.
    public static var musicLibrary: URL {
        let u = ssdMounted ? URL(fileURLWithPath: "\(masterStorage)/Library/Music")
                           : FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Pretty Studio")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
