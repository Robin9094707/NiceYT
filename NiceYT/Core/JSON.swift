import Foundation

/// Lightweight dynamic JSON wrapper used to walk InnerTube responses, whose
/// shapes change often. Every access is optional-safe.
struct JSON: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) {
        raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return JSON(nil) }
        return JSON(a[index])
    }

    /// Dotted path access, e.g. `at("a.b.0.c")`.
    func at(_ path: String) -> JSON {
        path.split(separator: ".").reduce(self) { j, part in
            if let i = Int(part) { return j[i] }
            return j[String(part)]
        }
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }

    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" }
        return nil
    }

    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }

    var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// Text from `simpleText`, `runs`, `content` or a plain string.
    var text: String? {
        if let s = raw as? String { return s }
        if let s = self["simpleText"].string { return s }
        if let runs = raw.flatMap({ ($0 as? [String: Any])?["runs"] as? [Any] }) {
            let joined = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let s = self["content"].string { return s }
        return nil
    }

    /// Best (largest) thumbnail from a `thumbnails` or `sources` array.
    var thumbURL: URL? {
        var list = self["thumbnails"].array
        if list.isEmpty { list = self["sources"].array }
        if list.isEmpty { list = self["image"]["sources"].array }
        guard var s = list.last?["url"].string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// All values for `key` anywhere below this node (pre-order, arrays in order).
    func findAll(_ key: String, limit: Int = .max) -> [JSON] {
        var out: [JSON] = []
        func walk(_ any: Any?) {
            if out.count >= limit { return }
            if let d = any as? [String: Any] {
                for k in d.keys.sorted() {
                    let v = d[k]
                    if k == key { out.append(JSON(v)); if out.count >= limit { return } }
                    walk(v)
                }
            } else if let a = any as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(raw)
        return out
    }

    func findFirst(_ key: String) -> JSON {
        findAll(key, limit: 1).first ?? JSON(nil)
    }
}
