import SwiftUI

enum VideoQuality: String, CaseIterable, Identifiable {
    case auto, q2160 = "2160", q1440 = "1440", q1080 = "1080", q720 = "720", q480 = "480", q360 = "360"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatisch"
        case .q2160: return "2160p (4K)"
        case .q1440: return "1440p (2K)"
        default: return rawValue + "p"
        }
    }

    /// Maximum resolution passed to AVPlayerItem (zero = unlimited).
    var maxSize: CGSize {
        switch self {
        case .auto: return .zero
        case .q2160: return CGSize(width: 3840, height: 2160)
        case .q1440: return CGSize(width: 2560, height: 1440)
        case .q1080: return CGSize(width: 1920, height: 1080)
        case .q720: return CGSize(width: 1280, height: 720)
        case .q480: return CGSize(width: 854, height: 480)
        case .q360: return CGSize(width: 640, height: 360)
        }
    }
}

/// Which audio track to play when YouTube offers AI-dubbed translations.
enum AudioPreference: String, CaseIterable, Identifiable {
    case original, german = "de", system

    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Originalton"
        case .german: return "Deutsche Übersetzung"
        case .system: return "Wie YouTube (automatisch)"
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case red, pink, purple, blue, teal, mint, orange

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .blue: return .blue
        case .teal: return .teal
        case .mint: return .mint
        case .orange: return .orange
        }
    }
    var label: String {
        switch self {
        case .red: return "Rot"
        case .pink: return "Pink"
        case .purple: return "Lila"
        case .blue: return "Blau"
        case .teal: return "Türkis"
        case .mint: return "Mint"
        case .orange: return "Orange"
        }
    }
}

/// App preferences, persisted in UserDefaults. Readable from any thread through the static accessors.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var quality: VideoQuality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var sponsorBlock: Bool { didSet { d.set(sponsorBlock, forKey: "sponsorBlock") } }
    @Published var dislikes: Bool { didSet { d.set(dislikes, forKey: "dislikes") } }
    @Published var backgroundPlay: Bool { didSet { d.set(backgroundPlay, forKey: "backgroundPlay") } }
    @Published var autoPiP: Bool { didSet { d.set(autoPiP, forKey: "autoPiP") } }
    @Published var autoplayNext: Bool { didSet { d.set(autoplayNext, forKey: "autoplayNext") } }
    @Published var captions: Bool { didSet { d.set(captions, forKey: "captions") } }
    @Published var hideShorts: Bool { didSet { d.set(hideShorts, forKey: "hideShorts") } }
    @Published var doubleTapSeek: Bool { didSet { d.set(doubleTapSeek, forKey: "doubleTapSeek") } }
    @Published var seekInterval: Int { didSet { d.set(seekInterval, forKey: "seekInterval") } }
    @Published var swipeFullscreen: Bool { didSet { d.set(swipeFullscreen, forKey: "swipeFullscreen") } }
    @Published var swipeVolume: Bool { didSet { d.set(swipeVolume, forKey: "swipeVolume") } }
    @Published var resumePlayback: Bool { didSet { d.set(resumePlayback, forKey: "resumePlayback") } }
    @Published var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    @Published var audioPreference: AudioPreference { didSet { d.set(audioPreference.rawValue, forKey: "audioPreference") } }
    @Published var language: String { didSet { d.set(language, forKey: "hl") } }
    @Published var region: String { didSet { d.set(region, forKey: "gl") } }
    @Published var sponsorCategories: Set<String> {
        didSet { d.set(Array(sponsorCategories), forKey: "sponsorCategories") }
    }

    struct SponsorCategory: Identifiable {
        let id: String
        let label: String
    }

    static let allSponsorCategories: [SponsorCategory] = [
        .init(id: "sponsor", label: "Sponsoren"),
        .init(id: "selfpromo", label: "Eigenwerbung"),
        .init(id: "interaction", label: "Abo-/Like-Erinnerungen"),
        .init(id: "intro", label: "Intro"),
        .init(id: "outro", label: "Abspann"),
        .init(id: "preview", label: "Vorschau/Rückblick"),
        .init(id: "music_offtopic", label: "Nicht-Musik-Abschnitte"),
        .init(id: "filler", label: "Füller")
    ]

    private init() {
        d.register(defaults: [
            "quality": VideoQuality.auto.rawValue,
            "sponsorBlock": true,
            "dislikes": true,
            "backgroundPlay": true,
            "autoPiP": true,
            "autoplayNext": true,
            "captions": false,
            "hideShorts": false,
            "doubleTapSeek": true,
            "seekInterval": 10,
            "swipeFullscreen": true,
            "swipeVolume": false,
            "resumePlayback": true,
            "accent": AccentChoice.red.rawValue,
            "audioPreference": AudioPreference.original.rawValue,
            // The app is German, so YouTube content (dates, view counts, comment sorting …)
            // is requested in German as well; it can be changed in the settings.
            "hl": "de",
            "gl": Self.defaultRegion,
            "sponsorCategories": ["sponsor", "selfpromo", "interaction"]
        ])
        quality = VideoQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .auto
        sponsorBlock = d.bool(forKey: "sponsorBlock")
        dislikes = d.bool(forKey: "dislikes")
        backgroundPlay = d.bool(forKey: "backgroundPlay")
        autoPiP = d.bool(forKey: "autoPiP")
        autoplayNext = d.bool(forKey: "autoplayNext")
        captions = d.bool(forKey: "captions")
        hideShorts = d.bool(forKey: "hideShorts")
        doubleTapSeek = d.bool(forKey: "doubleTapSeek")
        seekInterval = d.integer(forKey: "seekInterval")
        swipeFullscreen = d.bool(forKey: "swipeFullscreen")
        swipeVolume = d.bool(forKey: "swipeVolume")
        resumePlayback = d.bool(forKey: "resumePlayback")
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .red
        audioPreference = AudioPreference(rawValue: d.string(forKey: "audioPreference") ?? "") ?? .original
        language = d.string(forKey: "hl") ?? "de"
        region = d.string(forKey: "gl") ?? "DE"
        sponsorCategories = Set(d.stringArray(forKey: "sponsorCategories") ?? [])
    }

    private static var defaultRegion: String {
        let region = Locale.current.region?.identifier ?? "DE"
        return ["DE", "AT", "CH", "LI", "LU"].contains(region) ? region : "DE"
    }

    struct Option: Hashable, Identifiable {
        let code: String
        let name: String
        var id: String { code }
        init(_ code: String, _ name: String) { self.code = code; self.name = name }
    }

    static let languages: [Option] = [
        .init("de", "Deutsch"), .init("en", "Englisch"), .init("fr", "Französisch"), .init("es", "Spanisch"),
        .init("it", "Italienisch"), .init("nl", "Niederländisch"), .init("pl", "Polnisch"), .init("tr", "Türkisch")
    ]

    static let regions: [Option] = [
        .init("DE", "Deutschland"), .init("AT", "Österreich"), .init("CH", "Schweiz"), .init("LU", "Luxemburg"),
        .init("US", "USA"), .init("GB", "Vereinigtes Königreich"), .init("FR", "Frankreich"), .init("IT", "Italien"),
        .init("ES", "Spanien"), .init("NL", "Niederlande"), .init("PL", "Polen"), .init("TR", "Türkei")
    ]

    static var hl: String { UserDefaults.standard.string(forKey: "hl") ?? "de" }
    /// Thread-safe read of the audio preference (used while resolving streams).
    static var audioPreferenceValue: AudioPreference {
        AudioPreference(rawValue: UserDefaults.standard.string(forKey: "audioPreference") ?? "") ?? .original
    }
    static var gl: String { UserDefaults.standard.string(forKey: "gl") ?? "DE" }
}
