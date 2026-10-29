import Foundation

/// Extracts app models from InnerTube JSON. Works by walking the tree and recognising
/// renderers by name, so it survives most layout reshuffles on YouTube's side.
enum Parser {
    /// Containers that never hold content we want (ads, chrome, promos).
    private static let skipKeys: Set<String> = [
        "frameworkUpdates", "responseContext", "topbar", "desktopTopbar", "engagementPanels",
        "overlay", "thumbnailOverlays", "menu", "menuRenderer", "endScreen", "playerOverlays",
        "adSlotRenderer", "promotedVideoRenderer", "compactPromotedVideoRenderer", "searchPyvRenderer",
        "inFeedAdLayoutRenderer", "promotedSparklesWebRenderer", "promotedSparklesTextSearchRenderer",
        "statementBannerRenderer", "brandVideoShelfRenderer", "brandVideoSingletonRenderer",
        "mealbarPromoRenderer", "bannerPromoRenderer", "primetimePromoRenderer", "adPlacements",
        "playerAds", "adBreakHeartbeatParams", "movieOfferModuleRenderer", "feedNudgeRenderer",
        "sidebar", "microformat", "onTap", "rendererContext", "navigationEndpoint", "command"
    ]

    // MARK: Feed items

    static func items(in root: JSON) -> [FeedItem] {
        var out: [FeedItem] = []
        var seen = Set<String>()
        func walk(_ any: Any?) {
            if let d = any as? [String: Any] {
                for key in d.keys.sorted() {
                    if skipKeys.contains(key) { continue }
                    let value = JSON(d[key])
                    if let item = parse(key: key, value) {
                        if seen.insert(item.id).inserted { out.append(item) }
                        continue
                    }
                    if recognised.contains(key) { continue }
                    walk(d[key])
                }
            } else if let a = any as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root.raw)
        return out
    }

    private static let recognised: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "videoWithContextRenderer", "playlistPanelVideoRenderer", "reelItemRenderer",
        "shortsLockupViewModel", "lockupViewModel", "channelRenderer", "gridChannelRenderer",
        "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer", "endScreenVideoRenderer"
    ]

    static func parse(key: String, _ j: JSON) -> FeedItem? {
        switch key {
        case "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
             "videoWithContextRenderer", "playlistPanelVideoRenderer":
            return videoRenderer(j).map { $0.isShort ? .short($0) : .video($0) }
        case "reelItemRenderer":
            guard let id = j["videoId"].string else { return nil }
            var v = Video(id: id, title: j["headline"].text ?? "")
            v.views = j["viewCountText"].text
            v.thumbnail = j["thumbnail"].thumbURL
            v.isShort = true
            return .short(v)
        case "shortsLockupViewModel":
            guard let id = j.findFirst("reelWatchEndpoint")["videoId"].string
                    ?? j["entityId"].string?.components(separatedBy: "-").last else { return nil }
            var v = Video(id: id, title: j.at("overlayMetadata.primaryText.content").string ?? "")
            v.views = j.at("overlayMetadata.secondaryText.content").string
            v.thumbnail = j.at("thumbnailViewModel.thumbnailViewModel.image").thumbURL
                ?? j.at("thumbnail").thumbURL
            v.isShort = true
            return .short(v)
        case "lockupViewModel":
            return lockup(j)
        case "channelRenderer", "gridChannelRenderer":
            guard let id = j["channelId"].string else { return nil }
            var c = Channel(id: id, name: j["title"].text ?? "")
            c.avatar = j["thumbnail"].thumbURL
            let sub = j["subscriberCountText"].text
            let videos = j["videoCountText"].text
            // Search results put the handle in subscriberCountText and the subscriber count in videoCountText.
            if let sub, sub.hasPrefix("@") {
                c.handle = sub
                c.subscribers = videos
            } else {
                c.subscribers = sub ?? videos
            }
            return .channel(c)
        case "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer":
            guard let id = j["playlistId"].string else { return nil }
            var p = Playlist(id: id, title: j["title"].text ?? "")
            p.thumbnail = j["thumbnails"][0].thumbURL ?? j["thumbnail"].thumbURL
                ?? j["thumbnailRenderer"].findFirst("thumbnail").thumbURL
            p.videoCount = j["videoCountText"].text ?? j["videoCount"].string.map { "\($0) Videos" }
            p.channelName = j["shortBylineText"].text ?? j["longBylineText"].text
            p.firstVideoId = j.findFirst("watchEndpoint")["videoId"].string
            return .playlist(p)
        default:
            return nil
        }
    }

    static func videoRenderer(_ j: JSON) -> Video? {
        guard let id = j["videoId"].string else { return nil }
        var v = Video(id: id, title: j["title"].text ?? j["headline"].text ?? "")
        let owner = j["ownerText"].exists ? j["ownerText"] : (j["shortBylineText"].exists ? j["shortBylineText"] : j["longBylineText"])
        v.channelName = owner.text
        v.channelId = owner.findFirst("browseEndpoint")["browseId"].string
        v.channelAvatar = j.at("channelThumbnailSupportedRenderers.channelThumbnailWithLinkRenderer.thumbnail").thumbURL
            ?? j["channelThumbnail"].thumbURL
        v.thumbnail = j["thumbnail"].thumbURL
        let overlayTime = j["thumbnailOverlays"].findFirst("thumbnailOverlayTimeStatusRenderer")
        v.duration = j["lengthText"].text ?? overlayTime["text"].text
        v.views = j["shortViewCountText"].text ?? j["viewCountText"].text
        v.published = j["publishedTimeText"].text
        let infoRuns = j["videoInfo"]["runs"].array.compactMap { $0["text"].string }
        if infoRuns.count >= 3 {
            v.views = infoRuns[0]
            v.published = infoRuns[2]
        }
        let style = overlayTime["style"].string ?? ""
        v.isLive = style == "LIVE" || j["badges"].findAll("metadataBadgeRenderer").contains {
            ($0["style"].string ?? "").contains("LIVE")
        }
        v.isShort = style == "SHORTS" || j.findFirst("reelWatchEndpoint").exists
        return v
    }

    static func lockup(_ j: JSON) -> FeedItem? {
        guard let id = j["contentId"].string else { return nil }
        let type = j["contentType"].string ?? ""
        let meta = j.at("metadata.lockupMetadataViewModel")
        let title = meta["title"].text ?? ""
        let rows: [[String]] = meta.at("metadata.contentMetadataViewModel.metadataRows").array.map { row in
            row["metadataParts"].array.compactMap { $0["text"].text }
        }.filter { !$0.isEmpty }
        let avatar = meta.at("image.decoratedAvatarViewModel.avatar.avatarViewModel.image").thumbURL
            ?? meta["image"].findFirst("avatarViewModel")["image"].thumbURL
        let channelId = meta.findAll("browseEndpoint").compactMap { $0["browseId"].string }.first { $0.hasPrefix("UC") }
        let badges = j["contentImage"].findAll("thumbnailBadgeViewModel")
        let badgeText = badges.first?["text"].string
        let isLive = badges.contains { ($0["badgeStyle"].string ?? "").contains("LIVE") }

        switch type {
        case "LOCKUP_CONTENT_TYPE_VIDEO":
            var v = Video(id: id, title: title)
            v.thumbnail = j.at("contentImage.thumbnailViewModel.image").thumbURL
            v.channelAvatar = avatar
            v.channelId = channelId
            v.duration = isLive ? nil : badgeText
            v.isLive = isLive
            if rows.count >= 2 {
                v.channelName = rows[0].first
                let last = rows[rows.count - 1]
                v.views = last.first
                v.published = last.count > 1 ? last[1] : nil
            } else if let r = rows.first {
                v.views = r.first
                v.published = r.count > 1 ? r[1] : nil
            }
            return .video(v)
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_PODCAST":
            var p = Playlist(id: id, title: title)
            p.thumbnail = j["contentImage"].findFirst("thumbnailViewModel")["image"].thumbURL
            p.videoCount = badgeText
            p.channelName = rows.first?.first
            p.firstVideoId = j.findFirst("watchEndpoint")["videoId"].string
            return .playlist(p)
        default:
            return nil
        }
    }

    // MARK: Continuations

    /// Returns the shallowest continuation token, which is the one that extends the main list.
    static func continuation(in root: JSON) -> String? {
        var best: (depth: Int, token: String)?
        func consider(_ token: String?, _ depth: Int) {
            guard let token else { return }
            if best == nil || depth < best!.depth { best = (depth, token) }
        }
        func walk(_ any: Any?, _ depth: Int) {
            if let d = any as? [String: Any] {
                if let cir = d["continuationItemRenderer"] {
                    let j = JSON(cir)
                    consider(j.at("continuationEndpoint.continuationCommand.token").string
                             ?? j.at("button.buttonRenderer.command.continuationCommand.token").string, depth)
                }
                if let ncd = d["nextContinuationData"] {
                    consider(JSON(ncd)["continuation"].string, depth)
                }
                for (k, v) in d where k != "continuationItemRenderer" && k != "frameworkUpdates" && k != "engagementPanels" {
                    walk(v, depth + 1)
                }
            } else if let a = any as? [Any] {
                for v in a { walk(v, depth + 1) }
            }
        }
        walk(root.raw, 0)
        return best?.token
    }

    static func feed(_ root: JSON) -> FeedPage {
        FeedPage(items: items(in: root), continuation: continuation(in: root))
    }

    // MARK: Watch page

    static func watch(_ j: JSON) -> WatchDetails {
        var d = WatchDetails()
        let results = j.at("contents.twoColumnWatchNextResults.results.results.contents")
        let primary = results.findFirst("videoPrimaryInfoRenderer")
        let secondary = results.findFirst("videoSecondaryInfoRenderer")
        d.title = primary["title"].text ?? ""
        d.views = primary.at("viewCount.videoViewCountRenderer.viewCount").text
            ?? primary.at("viewCount.videoViewCountRenderer.shortViewCount").text
        d.date = primary["relativeDateText"].text ?? primary["dateText"].text

        let owner = secondary.at("owner.videoOwnerRenderer")
        if let cid = owner.findFirst("browseEndpoint")["browseId"].string {
            var c = Channel(id: cid, name: owner["title"].text ?? "")
            c.avatar = owner["thumbnail"].thumbURL
            c.subscribers = owner["subscriberCountText"].text
            d.channel = c
        }
        d.description = secondary.at("attributedDescription.content").string
            ?? secondary["description"].text ?? ""

        let like = primary.findFirst("likeButtonViewModel")
        d.likeText = like.findFirst("buttonViewModel")["title"].string
        d.likeStatus = j.findFirst("likeStatusEntity")["likeStatus"].string ?? like.findFirst("likeStatus").string

        if let sub = j.findFirst("subscribeButtonRenderer")["subscribed"].bool {
            d.isSubscribed = sub
        } else if let sub = j["frameworkUpdates"].findFirst("subscriptionStateEntity")["subscribed"].bool {
            d.isSubscribed = sub
        }

        for section in results.array {
            let isr = section["itemSectionRenderer"]
            if isr["sectionIdentifier"].string == "comment-item-section" {
                d.commentsToken = isr.findFirst("continuationCommand")["token"].string
            }
            if let header = isr.findFirst("commentsEntryPointHeaderRenderer").raw {
                let h = JSON(header)
                d.commentCount = h["commentCount"].text
                if let teaser = h.findFirst("commentsEntryPointTeaserRenderer").raw {
                    let t = JSON(teaser)
                    d.commentPreview = Comment(id: "teaser", author: "",
                                               authorAvatar: t["teaserAvatar"].thumbURL,
                                               text: t["teaserContent"].text ?? "")
                }
            }
        }
        if d.commentCount == nil {
            for panel in j["engagementPanels"].array {
                let p = panel["engagementPanelSectionListRenderer"]
                if (p["panelIdentifier"].string ?? "").contains("comments") {
                    d.commentCount = p.at("header.engagementPanelTitleHeaderRenderer.contextualInfo").text
                    if d.commentsToken == nil {
                        d.commentsToken = p["content"].findFirst("continuationCommand")["token"].string
                    }
                }
            }
        }

        let secondaryResults = j.at("contents.twoColumnWatchNextResults.secondaryResults")
        d.related = items(in: secondaryResults)
        d.relatedContinuation = continuation(in: secondaryResults)
        return d
    }

    // MARK: Comments

    static func comments(_ j: JSON) -> CommentPage {
        var page = CommentPage()
        var entities: [String: JSON] = [:]
        for m in j.at("frameworkUpdates.entityBatchUpdate.mutations").array {
            let payload = m["payload"]["commentEntityPayload"]
            guard payload.exists else { continue }
            if let key = payload["key"].string ?? m["entityKey"].string { entities[key] = payload }
            if let cid = payload.at("properties.commentId").string { entities["id:" + cid] = payload }
        }

        var root = JSON(nil)
        for name in ["onResponseReceivedEndpoints", "onResponseReceivedActions", "onResponseReceivedCommands"] where j[name].exists {
            root = j[name]
        }

        func make(_ vm: JSON, repliesToken: String?) -> Comment? {
            let key = vm["commentKey"].string ?? ""
            let id = vm["commentId"].string ?? key
            guard let e = entities[key] ?? entities["id:" + id] else { return nil }
            let props = e["properties"]
            let author = e["author"]
            let toolbar = e["toolbar"]
            var c = Comment(id: props["commentId"].string ?? id,
                            author: author["displayName"].string ?? "",
                            authorAvatar: author["avatarThumbnailUrl"].string.flatMap(URL.init(string:)),
                            authorChannelId: author["channelId"].string,
                            text: props.at("content.content").string ?? "")
            c.published = props["publishedTime"].string
            c.likes = toolbar["likeCountNotliked"].string
            if c.likes == "0" || c.likes == "" { c.likes = nil }
            c.replyCount = Int((toolbar["replyCount"].string ?? "").filter(\.isNumber)) ?? 0
            c.repliesToken = repliesToken
            c.isCreator = author["isCreator"].bool ?? false
            return c
        }

        func walk(_ any: Any?) {
            if let d = any as? [String: Any] {
                if let thread = d["commentThreadRenderer"] {
                    let t = JSON(thread)
                    let vm = t.at("commentViewModel.commentViewModel")
                    let token = t.at("replies.commentRepliesRenderer").findFirst("continuationCommand")["token"].string
                    if let c = make(vm, repliesToken: token) { page.comments.append(c) }
                    return
                }
                if let vm = d["commentViewModel"] {
                    if let c = make(JSON(vm), repliesToken: nil) { page.comments.append(c) }
                    return
                }
                for k in d.keys.sorted() { walk(d[k]) }
            } else if let a = any as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(root.raw)

        // The main list continuation sits at the end of the outermost item array.
        var token: String?
        for action in root.array {
            let list = action.findFirst("continuationItems")
            if let last = list.array.last, last["continuationItemRenderer"].exists {
                let cir = last["continuationItemRenderer"]
                token = cir.at("continuationEndpoint.continuationCommand.token").string
                    ?? cir.at("button.buttonRenderer.command.continuationCommand.token").string
            }
        }
        page.continuation = token

        let header = root.findFirst("commentsHeaderRenderer")
        page.countText = header["countText"].text
        page.sortOptions = header.findFirst("sortFilterSubMenuRenderer")["subMenuItems"].array.compactMap { item -> (title: String, token: String)? in
            guard let title = item["title"].string,
                  let token = item.findFirst("continuationCommand")["token"].string else { return nil }
            return (title, token)
        }
        return page
    }

    // MARK: Channel

    static func channel(_ j: JSON, id: String) -> ChannelPage {
        let meta = j.at("metadata.channelMetadataRenderer")
        var c = Channel(id: meta["externalId"].string ?? id, name: meta["title"].string ?? "")
        c.avatar = meta["avatar"].thumbURL
        var page = ChannelPage(channel: c)
        page.description = meta["description"].string

        let header = j["header"]
        let phvm = header.findFirst("pageHeaderViewModel")
        if phvm.exists {
            if let t = phvm.at("title.dynamicTextViewModel.text.content").string { page.channel.name = t }
            if let a = phvm["image"].findFirst("avatarViewModel")["image"].thumbURL { page.channel.avatar = a }
            page.banner = phvm["banner"].findFirst("imageBannerViewModel")["image"].thumbURL
            let parts = phvm.at("metadata.contentMetadataViewModel.metadataRows").array
                .flatMap { $0["metadataParts"].array.compactMap { $0["text"].text } }
            page.channel.handle = parts.first { $0.hasPrefix("@") }
            let rest = parts.filter { !$0.hasPrefix("@") }
            page.channel.subscribers = rest.first
            page.videoCount = rest.count > 1 ? rest[1] : nil
        } else {
            let c4 = header.findFirst("c4TabbedHeaderRenderer")
            if let t = c4["title"].string { page.channel.name = t }
            if let a = c4["avatar"].thumbURL { page.channel.avatar = a }
            page.banner = c4["banner"].thumbURL
            page.channel.subscribers = c4["subscriberCountText"].text
            page.channel.handle = c4["channelHandleText"].text
        }

        if let sub = j.findFirst("subscribeButtonRenderer")["subscribed"].bool {
            page.isSubscribed = sub
        } else if let sub = j["frameworkUpdates"].findFirst("subscriptionStateEntity")["subscribed"].bool {
            page.isSubscribed = sub
        }

        let tabs = j.at("contents.twoColumnBrowseResultsRenderer.tabs").array
        var selectedContent = JSON(nil)
        for t in tabs {
            let tr = t["tabRenderer"].exists ? t["tabRenderer"] : t["expandableTabRenderer"]
            guard let title = tr["title"].string else { continue }
            let selected = tr["selected"].bool ?? false
            page.tabs.append(.init(title: title, params: tr.at("endpoint.browseEndpoint.params").string, selected: selected))
            if selected { selectedContent = tr["content"] }
        }
        page.feed = feed(selectedContent.exists ? selectedContent : j["contents"])
        return page
    }

    // MARK: Playlist

    static func playlist(_ j: JSON) -> PlaylistPage {
        let header = j["header"]
        let phvm = header.findFirst("pageHeaderViewModel")
        var title = phvm.at("title.dynamicTextViewModel.text.content").string
            ?? header.findFirst("playlistHeaderRenderer")["title"].text
            ?? j.at("metadata.playlistMetadataRenderer.title").string ?? "Playlist"
        if title.isEmpty { title = "Playlist" }
        let parts = phvm["metadata"].findAll("metadataParts").flatMap { $0.array.compactMap { $0["text"].text } }
        var page = PlaylistPage(title: title)
        page.subtitle = parts.isEmpty ? header.findFirst("playlistHeaderRenderer")["numVideosText"].text : parts.joined(separator: " · ")
        page.thumbnail = phvm["heroImage"].findFirst("image").thumbURL
        page.feed = feed(j["contents"])
        if page.thumbnail == nil { page.thumbnail = page.feed.items.first?.video?.bestThumbnail }
        return page
    }

    // MARK: Player

    static func stream(_ j: JSON, videoId: String) throws -> StreamInfo {
        let status = j.at("playabilityStatus.status").string ?? ""
        guard status == "OK" else {
            let reason = j.at("playabilityStatus.reason").string
                ?? j.at("playabilityStatus.errorScreen").findFirst("reason").text
                ?? "Dieses Video kann nicht abgespielt werden (\(status))."
            throw YTError.unplayable(reason)
        }
        guard let hls = j.at("streamingData.hlsManifestUrl").string, let url = URL(string: hls) else {
            throw YTError.unplayable("Kein Stream verfügbar.")
        }
        let vd = j["videoDetails"]
        let captions = j.at("captions.playerCaptionsTracklistRenderer.captionTracks").array.compactMap { t -> CaptionTrack? in
            guard let base = t["baseUrl"].string, let u = URL(string: base) else { return nil }
            return CaptionTrack(name: t["name"].text ?? t["languageCode"].string ?? "?",
                                languageCode: t["languageCode"].string ?? "",
                                url: u,
                                isAuto: t["kind"].string == "asr")
        }
        return StreamInfo(videoId: videoId,
                          hlsURL: url,
                          title: vd["title"].string ?? "",
                          author: vd["author"].string ?? "",
                          channelId: vd["channelId"].string,
                          viewCount: vd["viewCount"].string,
                          lengthSeconds: vd["lengthSeconds"].int ?? 0,
                          description: vd["shortDescription"].string ?? "",
                          isLive: vd["isLive"].bool ?? false,
                          captions: captions)
    }

    // MARK: Subscriptions list

    static func channels(_ j: JSON) -> [Channel] {
        items(in: j).compactMap {
            if case .channel(let c) = $0 { return c }
            return nil
        }
    }

    static func guideSubscriptions(_ j: JSON) -> [Channel] {
        let section = j.findFirst("guideSubscriptionsSectionRenderer")
        return section.findAll("guideEntryRenderer").compactMap { e in
            guard let id = e.findFirst("browseEndpoint")["browseId"].string, id.hasPrefix("UC") else { return nil }
            var c = Channel(id: id, name: e["formattedTitle"].text ?? "")
            c.avatar = e["thumbnail"].thumbURL
            return c
        }
    }

    static func account(_ j: JSON) -> AccountInfo? {
        let h = j.findFirst("activeAccountHeaderRenderer")
        guard let name = h["accountName"].text else { return nil }
        return AccountInfo(name: name, handle: h["channelHandle"].text, avatar: h["accountPhoto"].thumbURL)
    }
}
