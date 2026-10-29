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
    private var sigCache: [String: String] = [:]
    private var sts: Int?

    /// Returns a mapping unsolved → solved for all given n challenges (missing entries failed).
    func solve(_ challenges: [String]) async -> [String: String] {
        await solve(n: challenges, sig: []).n
    }

    func solve(n: [String], sig: [String]) async -> (n: [String: String], sig: [String: String]) {
        let wantedN = Array(Set(n)).filter { cache[$0] == nil }
        let wantedSig = Array(Set(sig)).filter { sigCache[$0] == nil }
        if !wantedN.isEmpty || !wantedSig.isEmpty {
            await solveUncached(n: wantedN, sig: wantedSig)
        }
        var outN: [String: String] = [:]
        var outSig: [String: String] = [:]
        for c in n { if let v = cache[c] { outN[c] = v } }
        for c in sig { if let v = sigCache[c] { outSig[c] = v } }
        return (outN, outSig)
    }

    /// Loads and preprocesses the player ahead of time (called at app start), so the
    /// first video doesn't have to wait for it.
    func prewarm() async {
        guard preprocessed == nil else { return }
        await solveUncached(n: [], sig: [])
    }

    /// `signatureTimestamp` of the current player, required by clients that use signatures.
    func signatureTimestamp() async -> Int? {
        if let sts { return sts }
        if await loadCachedPlayer(), let sts { return sts }
        _ = await loadPlayerJS() // stores sts as a side effect
        return sts
    }

    private var playerJS: String?
    private var playerLoad: Task<String?, Never>?

    private func solveUncached(n: [String], sig: [String]) async {
        guard let ctx = makeContext() else {
            DebugLog.log("[n] Solver-Skripte fehlen im Bundle")
            return
        }
        if preprocessed == nil { _ = await loadCachedPlayer() }
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }
        var request: [String: Any] = ["requests": requests]
        let usedCache: Bool
        if let preprocessed {
            request["type"] = "preprocessed"
            request["preprocessed_player"] = preprocessed
            usedCache = true
        } else {
            var loaded = playerJS
            if loaded == nil { loaded = await loadPlayerJS() }
            guard let js = loaded else {
                DebugLog.log("[n] Player-JS konnte nicht geladen werden")
                return
            }
            // Another call may have finished preprocessing while we were waiting.
            if preprocessed != nil {
                await solveUncached(n: n, sig: sig)
                return
            }
            request["type"] = "player"
            request["player"] = js
            request["output_preprocessed"] = true
            usedCache = false
        }
        let start = Date()
        ctx.setObject(request, forKeyedSubscript: "__niceRequest" as NSString)
        let result = ctx.evaluateScript("JSON.stringify(jsc(__niceRequest))")
        ctx.setObject(nil, forKeyedSubscript: "__niceRequest" as NSString)
        guard let text = result?.toString(), let data = text.data(using: .utf8) else {
            DebugLog.log("[n] Solver lieferte nichts: \(ctx.exception?.toString() ?? "-")")
            if usedCache { discardCachedPlayer() }
            return
        }
        let j = JSON(data: data)
        if let pre = j["preprocessed_player"].string {
            preprocessed = pre
            playerJS = nil
            storeCachedPlayer(pre)
        }
        guard j["type"].string == "result" else {
            DebugLog.log("[n] Solver-Fehler: \(j["error"].string ?? String(text.prefix(200)))")
            discardCachedPlayer()
            return
        }
        var failures = 0
        for (i, response) in j["responses"].array.enumerated() {
            guard response["type"].string == "result" else {
                failures += 1
                DebugLog.log("[n] Challenge-Fehler: \(String(response["error"].string?.prefix(200) ?? "?"))")
                continue
            }
            let type = (requests.indices.contains(i) ? requests[i]["type"] as? String : nil) ?? "n"
            let list = type == "sig" ? sig : n
            for c in list {
                guard let solved = response["data"][c].string, !solved.isEmpty else { continue }
                if type == "sig" { sigCache[c] = solved } else if solved != c { cache[c] = solved }
            }
        }
        // A cached player that can no longer solve anything is outdated.
        if usedCache, failures > 0, failures == requests.count { discardCachedPlayer() }
        if !requests.isEmpty {
            DebugLog.log("[n] gelöst: n \(n.filter { cache[$0] != nil }.count)/\(n.count), sig \(sig.filter { sigCache[$0] != nil }.count)/\(sig.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms (Player \(playerId ?? "?"))")
        } else {
            DebugLog.log("[n] Player \(playerId ?? "?") vorbereitet in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
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

    // MARK: Player id & cache

    private var playerIdLookupDone = false

    private func resolvePlayerId() async -> String? {
        if let playerId { return playerId }
        if playerIdLookupDone { return nil }
        var req = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!, timeoutInterval: 10)
        req.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await InnerTube.shared.session.data(for: req), let text = String(data: data, encoding: .utf8) {
            let cleaned = text.replacingOccurrences(of: "\\/", with: "/")
            if let r = cleaned.range(of: #"/s/player/[0-9a-f]{8}"#, options: .regularExpression) {
                playerId = String(cleaned[r].suffix(8))
            }
        }
        // Without an answer we fall back to the last known player.
        if playerId == nil { playerId = UserDefaults.standard.string(forKey: "solverPlayerId") }
        playerIdLookupDone = playerId != nil
        return playerId
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static func cacheFile(_ pid: String) -> URL {
        cacheDirectory.appendingPathComponent("player-\(pid).pre.js")
    }

    /// Uses the preprocessed player stored by an earlier app start, if it is still current.
    private func loadCachedPlayer() async -> Bool {
        if preprocessed != nil { return true }
        guard let pid = await resolvePlayerId(), preprocessed == nil,
              let text = try? String(contentsOf: Self.cacheFile(pid), encoding: .utf8), !text.isEmpty else {
            return preprocessed != nil
        }
        preprocessed = text
        if sts == nil {
            let stored = UserDefaults.standard.integer(forKey: "solverSts-\(pid)")
            if stored > 0 { sts = stored }
        }
        DebugLog.log("[n] Player \(pid) aus dem Cache")
        return true
    }

    private func storeCachedPlayer(_ text: String) {
        guard let pid = playerId else { return }
        let defaults = UserDefaults.standard
        // Remove the previous player's files.
        if let old = defaults.string(forKey: "solverPlayerId"), old != pid {
            try? FileManager.default.removeItem(at: Self.cacheFile(old))
            defaults.removeObject(forKey: "solverSts-\(old)")
        }
        try? text.write(to: Self.cacheFile(pid), atomically: true, encoding: .utf8)
        defaults.set(pid, forKey: "solverPlayerId")
        if let sts { defaults.set(sts, forKey: "solverSts-\(pid)") }
    }

    private func discardCachedPlayer() {
        preprocessed = nil
        guard let pid = playerId else { return }
        try? FileManager.default.removeItem(at: Self.cacheFile(pid))
    }

    private func loadPlayerJS() async -> String? {
        if let playerJS { return playerJS }
        if let playerLoad { return await playerLoad.value }
        let task = Task { await self.downloadPlayerJS() }
        playerLoad = task
        let js = await task.value
        playerLoad = nil
        return js
    }

    private func downloadPlayerJS() async -> String? {
        let session = InnerTube.shared.session
        guard let pid = await resolvePlayerId(),
              let url = URL(string: "https://www.youtube.com/s/player/\(pid)/player_es6.vflset/en_US/base.js") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let js = String(data: data, encoding: .utf8) else { return nil }
        if let r = js.range(of: #"(?:signatureTimestamp|sts)\s*:\s*[0-9]{5}"#, options: .regularExpression) {
            sts = Int(js[r].filter(\.isNumber).suffix(5))
            if let sts { UserDefaults.standard.set(sts, forKey: "solverSts-\(pid)") }
        }
        playerJS = js
        DebugLog.log("[n] Player \(pid) geladen (\(data.count / 1024) KB, sts \(sts.map(String.init) ?? "?"))")
        return js
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
