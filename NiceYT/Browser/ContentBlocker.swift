import WebKit

/// Built-in ad and tracker blocker: a compiled WebKit content rule list (blocked hosts
/// plus hidden ad containers), with per-site exceptions.
@MainActor
enum ContentBlocker {
    private static let identifier = "NovaAdBlock"
    private static var cache: (key: String, list: WKContentRuleList)?

    /// Third-party hosts that only serve ads, ad auctions or tracking.
    static let hosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "adservice.google.de",
        "pagead2.googlesyndication.com", "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "2mdn.net", "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "smartadserver.com", "teads.tv", "yieldlab.net", "adform.net", "adition.com", "adtech.de",
        "adsafeprotected.com", "moatads.com", "doubleverify.com", "scorecardresearch.com", "quantserve.com",
        "chartbeat.com", "hotjar.com", "mouseflow.com", "crazyegg.com", "bat.bing.com", "ads.yahoo.com",
        "adtechus.com", "media.net", "revcontent.com", "mgid.com", "zemanta.com", "propellerads.com",
        "popads.net", "popcash.net", "adsterra.com", "exoclick.com", "juicyads.com", "trafficjunky.net",
        "hilltopads.net", "adcash.com", "clickadu.com", "onclickads.net", "admaven.com", "a-ads.com",
        "33across.com", "sharethrough.com", "triplelift.com", "indexww.com", "sovrn.com", "lijit.com",
        "contextweb.com", "bidswitch.net", "adroll.com", "rlcdn.com", "bluekai.com", "demdex.net",
        "everesttech.net", "krxd.net", "exelator.com", "tapad.com", "agkn.com", "mathtag.com", "turn.com",
        "serving-sys.com", "flashtalking.com", "innovid.com", "springserve.com", "spotxchange.com",
        "smaato.net", "inmobi.com", "applovin.com", "unityads.unity3d.com", "ads.tiktok.com", "analytics.tiktok.com",
        "ads-api.tiktok.com", "an.facebook.com", "ads.linkedin.com", "ads.pinterest.com", "ads-twitter.com",
        "static.ads-twitter.com", "ads.reddit.com", "adnz.co", "stroeerdigitalgroup.de",
        "ioam.de", "xiti.com", "yieldlove.com", "adup-tech.com", "plista.com", "ligatus.com", "nativendo.de",
        "id5-sync.com", "liadm.com", "permutive.com", "prebid.org", "cdn.confiant-integrations.net"
    ]

    /// Common ad containers that stay empty (or show placeholders) once their content is blocked.
    static let hiddenSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^=\"div-gpt-ad\"]", "[id^=\"google_ads_iframe\"]", "[id^=\"taboola-\"]",
        ".trc_related_container", ".OUTBRAIN", "[data-google-query-id]", "[data-ad-slot]", ".ad-slot", ".ad-banner",
        ".adBanner", ".advertisement", "[aria-label=\"Advertisement\"]", "[aria-label=\"Anzeige\"]", ".sponsored-ad",
        "amp-ad", "amp-embed[type=\"taboola\"]", ".mgbox", ".plista_widget"
    ]

    static func ruleList(exceptions: Set<String>) async -> WKContentRuleList? {
        let key = exceptions.sorted().joined(separator: ",")
        if let cache, cache.key == key { return cache.list }
        guard let json = rules(exceptions: exceptions) else { return nil }
        do {
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json) else { return nil }
            cache = (key, list)
            return list
        } catch {
            DebugLog.log("Werbeblocker: \(error.localizedDescription)")
            return nil
        }
    }

    private static func rules(exceptions: Set<String>) -> String? {
        var rules: [[String: Any]] = []
        for host in hosts {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            let trigger: [String: Any] = ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]]
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        let hide: [String: Any] = ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]
        rules.append(["trigger": ["url-filter": ".*"], "action": hide])
        let domains = exceptions.map { "*" + $0.lowercased() }
        if !domains.isEmpty {
            let trigger: [String: Any] = ["url-filter": ".*", "if-domain": domains]
            rules.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The site a page belongs to, as used for exceptions ("m.facebook.com" → "facebook.com").
    static func site(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let twoLevel = ["co.uk", "com.au", "co.jp", "com.br", "co.at"]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        return (twoLevel.contains(lastTwo) ? parts.suffix(3) : parts.suffix(2)).joined(separator: ".")
    }
}
