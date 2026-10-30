import Foundation

/// Writes title, artist, album, track number, year, ISRC and the cover into downloaded
/// files, so they look right in other apps (Files, WhatsApp, DJ apps, car radios …).
enum AudioTagger {
    struct Tags {
        var title: String
        var artist: String
        var albumArtist: String
        var album: String
        var trackNumber: Int?
        var discNumber: Int?
        var year: String?
        var date: String?
        var isrc: String?
        var cover: Data?

        init(_ track: DZTrack, cover: Data?) {
            title = track.fullTitle
            artist = track.artistLine
            albumArtist = track.artist
            album = track.album
            trackNumber = track.trackNumber
            discNumber = track.discNumber
            year = track.year
            date = track.releaseDate
            isrc = track.isrc
            self.cover = cover
        }
    }

    static func tag(_ data: Data, quality: DZQuality, tags: Tags) -> Data {
        quality == .flac ? flac(data, tags: tags) ?? data : mp3(data, tags: tags)
    }

    // MARK: ID3v2.3 (MP3)

    static func mp3(_ input: Data, tags: Tags) -> Data {
        var audio = input
        // Drop an existing ID3v2 tag.
        if audio.count > 10, audio.prefix(3) == Data("ID3".utf8) {
            let b = Array(audio[audio.startIndex + 6..<audio.startIndex + 10])
            let size = Int(b[0]) << 21 | Int(b[1]) << 14 | Int(b[2]) << 7 | Int(b[3])
            let footer = (audio[audio.startIndex + 5] & 0x10) != 0 ? 10 : 0
            let skip = 10 + size + footer
            if skip < audio.count { audio = Data(audio[(audio.startIndex + skip)...]) }
        }

        var frames = Data()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            var body = Data([0x01, 0xFF, 0xFE]) // UTF-16 with BOM (little endian)
            for unit in value.utf16 { body.append(UInt8(unit & 0xFF)); body.append(UInt8(unit >> 8)) }
            frame(id, body)
        }
        func frame(_ id: String, _ body: Data) {
            frames.append(Data(id.utf8))
            frames.append(bigEndian32(UInt32(body.count)))
            frames.append(contentsOf: [0, 0])
            frames.append(body)
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TPE2", tags.albumArtist)
        text("TALB", tags.album)
        text("TRCK", tags.trackNumber.map(String.init))
        text("TPOS", tags.discNumber.map(String.init))
        text("TYER", tags.year)
        text("TSRC", tags.isrc)
        if let cover = tags.cover {
            var body = Data([0x00])
            body.append(Data("image/jpeg".utf8)); body.append(0)
            body.append(0x03) // front cover
            body.append(0)    // empty description
            body.append(cover)
            frame("APIC", body)
        }
        var out = Data("ID3".utf8)
        out.append(contentsOf: [0x03, 0x00, 0x00])
        out.append(syncSafe(frames.count))
        out.append(frames)
        out.append(audio)
        return out
    }

    // MARK: FLAC (Vorbis comment + picture block)

    static func flac(_ input: Data, tags: Tags) -> Data? {
        let bytes = [UInt8](input)
        guard bytes.count > 8, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] else { return nil } // "fLaC"
        var blocks: [(type: UInt8, body: ArraySlice<UInt8>)] = []
        var pos = 4
        var last = false
        while !last, pos + 4 <= bytes.count {
            let header = bytes[pos]
            last = header & 0x80 != 0
            let type = header & 0x7F
            let length = Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            let start = pos + 4
            guard start + length <= bytes.count else { return nil }
            // Keep STREAMINFO, SEEKTABLE, APPLICATION, CUESHEET; replace comments, pictures, padding.
            if type != 1 && type != 4 && type != 6 { blocks.append((type, bytes[start..<start + length])) }
            pos = start + length
        }
        guard blocks.first?.type == 0 else { return nil }

        var comment = Data()
        let vendor = Data("NicePlay".utf8)
        comment.append(littleEndian32(UInt32(vendor.count))); comment.append(vendor)
        var fields: [String] = ["TITLE=\(tags.title)", "ARTIST=\(tags.artist)", "ALBUMARTIST=\(tags.albumArtist)", "ALBUM=\(tags.album)"]
        if let n = tags.trackNumber { fields.append("TRACKNUMBER=\(n)") }
        if let n = tags.discNumber { fields.append("DISCNUMBER=\(n)") }
        if let d = tags.date ?? tags.year { fields.append("DATE=\(d)") }
        if let i = tags.isrc, !i.isEmpty { fields.append("ISRC=\(i)") }
        comment.append(littleEndian32(UInt32(fields.count)))
        for f in fields {
            let d = Data(f.utf8)
            comment.append(littleEndian32(UInt32(d.count))); comment.append(d)
        }

        var newBlocks: [(UInt8, Data)] = blocks.map { ($0.type, Data($0.body)) }
        newBlocks.append((4, comment))
        if let cover = tags.cover {
            var pic = Data()
            pic.append(bigEndian32(3))
            let mime = Data("image/jpeg".utf8)
            pic.append(bigEndian32(UInt32(mime.count))); pic.append(mime)
            pic.append(bigEndian32(0))
            pic.append(bigEndian32(0)); pic.append(bigEndian32(0)); pic.append(bigEndian32(0)); pic.append(bigEndian32(0))
            pic.append(bigEndian32(UInt32(cover.count))); pic.append(cover)
            newBlocks.append((6, pic))
        }

        var out = Data("fLaC".utf8)
        for (i, block) in newBlocks.enumerated() {
            let isLast = i == newBlocks.count - 1
            out.append((isLast ? 0x80 : 0) | block.0)
            let n = block.1.count
            out.append(contentsOf: [UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(block.1)
        }
        out.append(contentsOf: bytes[pos...])
        return out
    }

    // MARK: Helpers

    private static func bigEndian32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    private static func littleEndian32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    private static func syncSafe(_ v: Int) -> Data {
        Data([UInt8(v >> 21 & 0x7F), UInt8(v >> 14 & 0x7F), UInt8(v >> 7 & 0x7F), UInt8(v & 0x7F)])
    }
}
