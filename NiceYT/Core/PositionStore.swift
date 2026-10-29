import Foundation

/// Remembers where each video was left off (local, like YouTube's red progress bar).
enum PositionStore {
    private static let key = "playbackPositions"

    private static var all: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func save(_ id: String, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        var dict = all
        if position < 5 || position > duration - 15 {
            dict[id] = nil
        } else {
            dict[id] = [position, duration, Date().timeIntervalSince1970]
        }
        if dict.count > 400 {
            let oldest = dict.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(dict.count - 400)
            for (k, _) in oldest { dict[k] = nil }
        }
        all = dict
    }

    static func position(_ id: String) -> Double? {
        all[id]?.first
    }

    static func progress(_ id: String) -> Double? {
        guard let v = all[id], v.count >= 2, v[1] > 0 else { return nil }
        return min(1, v[0] / v[1])
    }

    static func remove(_ id: String) {
        var dict = all
        dict[id] = nil
        all = dict
    }
}
