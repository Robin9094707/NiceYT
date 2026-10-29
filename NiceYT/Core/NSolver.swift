import Foundation
import JavaScriptCore

/// Solves YouTube's "n" throttling challenge with yt-dlp's EJS solver (bundled,
/// Unlicense/MIT/ISC) running in JavaScriptCore. Without solving it, googlevideo
/// answers stream segments of web clients with HTTP 403.
actor NSolver {
    static let shared = NSolver()

    private var context: JSContext?
    private var playerId: String?
    private var preprocessed: String?
    private var cache: [String: String] = [:]

    /// Returns a mapping unsolved → solved for all given challenges (missing entries failed).
    func solve(_ challenges: [String]) async -> [String: String] {
        let wanted = Array(Set(challenges)).filter { cache[$0] == nil }
        if !wanted.isEmpty {
            await solveUncached(wanted)
        }
        var out: [String: String] = [:]
        for c in challenges { if let s = cache[c] { out[c] = s } }
        return out
    }

    private func solveUncached(_ challenges: [String]) async {
        guard let ctx = makeContext() else {
            DebugLog.log("[n] Solver-Skripte fehlen im Bundle")
            return
        }
        let start = Date()
        var request: [String: Any] = ["requests": [["type": "n", "challenges": challenges]]]
        if let preprocessed {
            request["type"] = "preprocessed"
            request["preprocessed_player"] = preprocessed
        } else {
            guard let js = await loadPlayerJS() else {
                DebugLog.log("[n] Player-JS konnte nicht geladen werden")
                return
            }
            request["type"] = "player"
            request["player"] = js
            request["output_preprocessed"] = true
        }
        ctx.setObject(request, forKeyedSubscript: "__niceRequest" as NSString)
        let result = ctx.evaluateScript("JSON.stringify(jsc(__niceRequest))")
        ctx.setObject(nil, forKeyedSubscript: "__niceRequest" as NSString)
        guard let text = result?.toString(), let data = text.data(using: .utf8) else {
            DebugLog.log("[n] Solver lieferte nichts: \(ctx.exception?.toString() ?? "-")")
            return
        }
        let j = JSON(data: data)
        if let pre = j["preprocessed_player"].string { preprocessed = pre }
        guard j["type"].string == "result" else {
            DebugLog.log("[n] Solver-Fehler: \(j["error"].string ?? text.prefix(200).description)")
            preprocessed = nil
            return
        }
        for response in j["responses"].array {
            guard response["type"].string == "result" else {
                DebugLog.log("[n] Challenge-Fehler: \(response["error"].string?.prefix(200) ?? "?")")
                continue
            }
            for c in challenges {
                if let solved = response["data"][c].string, !solved.isEmpty, solved != c {
                    cache[c] = solved
                }
            }
        }
        DebugLog.log("[n] \(cache.count) gelöst in \(Int(Date().timeIntervalSince(start) * 1000)) ms (Player \(playerId ?? "?"))")
    }

    private func makeContext() -> JSContext? {
        if let context { return context }
        func resource(_ name: String) -> URL? {
            Bundle.main.url(forResource: name, withExtension: "js")
                ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Solver")
        }
        guard let libURL = resource("yt.solver.lib.min"),
              let coreURL = resource("yt.solver.core.min"),
              let lib = try? String(contentsOf: libURL, encoding: .utf8),
              let core = try? String(contentsOf: coreURL, encoding: .utf8),
              let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, exception in
            DebugLog.log("[n] JS-Ausnahme: \(exception?.toString() ?? "?")")
        }
        ctx.evaluateScript(lib)
        ctx.evaluateScript("var meriyah = lib.meriyah; var astring = lib.astring;")
        ctx.evaluateScript(core)
        guard ctx.objectForKeyedSubscript("jsc")?.isObject == true else {
            DebugLog.log("[n] jsc nicht definiert")
            return nil
        }
        context = ctx
        return ctx
    }

    private func loadPlayerJS() async -> String? {
        let session = InnerTube.shared.session
        if playerId == nil {
            var req = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
            req.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await session.data(for: req), let text = String(data: data, encoding: .utf8) {
                let cleaned = text.replacingOccurrences(of: "\\/", with: "/")
                if let r = cleaned.range(of: #"/s/player/[0-9a-f]{8}"#, options: .regularExpression) {
                    playerId = String(cleaned[r].suffix(8))
                }
            }
        }
        guard let pid = playerId,
              let url = URL(string: "https://www.youtube.com/s/player/\(pid)/player_es6.vflset/en_US/base.js") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        DebugLog.log("[n] Player \(pid) geladen (\(data.count / 1024) KB)")
        return String(data: data, encoding: .utf8)
    }

    /// Finds `/n/<value>/` path segments and `n=<value>` query parameters.
    static func challenges(in text: String) -> [String] {
        var found = Set<String>()
        for pattern in [#"/n/([A-Za-z0-9_-]{6,})/"#, #"[?&]n=([A-Za-z0-9_-]{6,})"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return Array(found)
    }

    static func apply(_ map: [String: String], to text: String) -> String {
        var out = text
        for (from, to) in map {
            out = out.replacingOccurrences(of: "/n/\(from)/", with: "/n/\(to)/")
            out = out.replacingOccurrences(of: "n=\(from)", with: "n=\(to)")
        }
        return out
    }
}
