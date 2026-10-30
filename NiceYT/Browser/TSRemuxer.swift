import AVFoundation
import CoreMedia

/// Turns MPEG-TS files (H.264 or HEVC video, AAC audio – what HLS streams and TV
/// recordings use) into MP4 without re-encoding, so iOS can play and share them.
enum TSRemuxer {
    enum RemuxError: LocalizedError {
        case notTransportStream
        case noStreams
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .notTransportStream: return "Das ist keine MPEG-TS-Datei."
            case .noStreams: return "In der Datei wurde kein H.264-, HEVC- oder AAC-Inhalt gefunden."
            case .writer(let message): return "Umwandeln fehlgeschlagen: \(message)"
            }
        }
    }

    /// Converts `input` (.ts) into `output` (.mp4). `progress` gets 0…1.
    static func remux(_ input: URL, to output: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: input.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        try? FileManager.default.removeItem(at: output)
        let demuxer = Demuxer()
        let sink = try Sink(output: output, source: demuxer)
        var read: Int64 = 0
        var carry = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 188 * 8192), !chunk.isEmpty else { break }
            read += Int64(chunk.count)
            var data = carry
            data.append(chunk)
            var offset = 0
            if read == Int64(chunk.count) {
                // Find the first sync byte (some files start with garbage).
                guard let start = data.firstIndex(of: 0x47) else { throw RemuxError.notTransportStream }
                offset = start - data.startIndex
            }
            let bytes = [UInt8](data)
            while offset + 188 <= bytes.count {
                if bytes[offset] != 0x47 {
                    // Lost sync: look for the next packet start.
                    offset += 1
                    continue
                }
                demuxer.packet(bytes, offset)
                offset += 188
            }
            carry = Data(bytes[offset...])
            try await sink.consume(demuxer.takeSamples())
            if size > 0 { progress?(min(0.99, Double(read) / Double(size))) }
        }
        demuxer.flush()
        try await sink.consume(demuxer.takeSamples(), final: true)
        try await sink.finish()
        progress?(1)
    }

    // MARK: - Samples

    fileprivate struct Sample {
        enum Kind { case video, audio }
        let kind: Kind
        var data: Data
        var pts: Int64
        var dts: Int64
        var keyframe: Bool
        /// Audio: sizes of the AAC frames in `data`.
        var frames: [Int] = []
    }

    // MARK: - Demuxer

    fileprivate final class Demuxer {
        enum Codec { case h264, hevc }

        private var pmtPID: Int?
        private(set) var videoPID: Int?
        private(set) var audioPID: Int?
        private(set) var codec: Codec = .h264
        private var buffers: [Int: [UInt8]] = [:]
        private var samples: [Sample] = []

        // Parameter sets for the video format.
        private(set) var vps: [UInt8]?
        private(set) var sps: [UInt8]?
        private(set) var pps: [UInt8]?
        // AAC configuration from the first ADTS header.
        private(set) var audioConfig: (objectType: Int, sampleRateIndex: Int, channels: Int)?

        private var lastVideo: Int64?
        private var lastAudio: Int64?
        private var wrapVideo: Int64 = 0
        private var wrapAudio: Int64 = 0

        static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

        var audioSampleRate: Int {
            guard let c = audioConfig, c.sampleRateIndex < Self.sampleRates.count else { return 44100 }
            return Self.sampleRates[c.sampleRateIndex]
        }

        func packet(_ b: [UInt8], _ o: Int) {
            let start = (b[o + 1] & 0x40) != 0
            let pid = (Int(b[o + 1] & 0x1F) << 8) | Int(b[o + 2])
            let adaptation = (b[o + 3] >> 4) & 0x3
            var p = o + 4
            if adaptation == 2 || adaptation == 3 { p += 1 + Int(b[o + 4]) }
            guard adaptation == 1 || adaptation == 3, p < o + 188 else { return }
            let payload = b[p..<(o + 188)]
            if pid == 0 {
                if start { parsePAT(Array(payload)) }
            } else if pid == pmtPID {
                if start { parsePMT(Array(payload)) }
            } else if pid == videoPID || pid == audioPID {
                if start, let previous = buffers[pid], !previous.isEmpty { pes(previous, pid: pid) }
                if start { buffers[pid] = Array(payload) } else if buffers[pid] != nil { buffers[pid]!.append(contentsOf: payload) }
            }
        }

        func flush() {
            for (pid, data) in buffers where !data.isEmpty { pes(data, pid: pid) }
            buffers = [:]
        }

        func takeSamples() -> [Sample] {
            defer { samples = [] }
            return samples
        }

        private func parsePAT(_ p: [UInt8]) {
            guard !p.isEmpty else { return }
            let s = 1 + Int(p[0])
            guard s + 8 <= p.count else { return }
            let length = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
            var i = s + 8
            let end = min(p.count, s + 3 + length - 4)
            while i + 4 <= end {
                let program = (Int(p[i]) << 8) | Int(p[i + 1])
                let pid = (Int(p[i + 2] & 0x1F) << 8) | Int(p[i + 3])
                if program != 0 {
                    pmtPID = pid
                    return
                }
                i += 4
            }
        }

        private func parsePMT(_ p: [UInt8]) {
            guard !p.isEmpty else { return }
            let s = 1 + Int(p[0])
            guard s + 12 <= p.count, p[s] == 0x02 else { return }
            let length = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
            let infoLength = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
            var i = s + 12 + infoLength
            let end = min(p.count, s + 3 + length - 4)
            while i + 5 <= end {
                let type = p[i]
                let pid = (Int(p[i + 1] & 0x1F) << 8) | Int(p[i + 2])
                let esLength = (Int(p[i + 3] & 0x0F) << 8) | Int(p[i + 4])
                switch type {
                case 0x1B where videoPID == nil:
                    videoPID = pid
                    codec = .h264
                case 0x24 where videoPID == nil:
                    videoPID = pid
                    codec = .hevc
                case 0x0F where audioPID == nil:
                    audioPID = pid
                default:
                    break
                }
                i += 5 + esLength
            }
        }

        private static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
            var t = Int64((b[i] >> 1) & 0x07) << 30
            t |= Int64(b[i + 1]) << 22
            t |= Int64(b[i + 2] >> 1) << 15
            t |= Int64(b[i + 3]) << 7
            t |= Int64(b[i + 4] >> 1)
            return t
        }

        /// 33-bit timestamps wrap after ~26 hours; keep them increasing.
        private func unwrap(_ t: Int64, video: Bool) -> Int64 {
            let wrap: Int64 = 1 << 33
            var offset = video ? wrapVideo : wrapAudio
            let last = video ? lastVideo : lastAudio
            if let last, t + offset < last - (wrap / 2) { offset += wrap }
            if video { wrapVideo = offset; lastVideo = t + offset } else { wrapAudio = offset; lastAudio = t + offset }
            return t + offset
        }

        private func pes(_ b: [UInt8], pid: Int) {
            guard b.count > 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
            let flags = b[7] >> 6
            let headerLength = Int(b[8])
            let start = 9 + headerLength
            guard start < b.count, flags & 0x2 != 0, b.count >= 14 else { return }
            let isVideo = pid == videoPID
            let pts = unwrap(Self.timestamp(b, 9), video: isVideo)
            var dts = pts
            if flags == 3, b.count >= 19 {
                let raw = Self.timestamp(b, 14)
                dts = raw + (isVideo ? wrapVideo : wrapAudio)
                if dts > pts { dts -= 1 << 33 }
            }
            let payload = Array(b[start...])
            if isVideo { video(payload, pts: pts, dts: dts) } else { audio(payload, pts: pts) }
        }

        // MARK: Video

        private func video(_ payload: [UInt8], pts: Int64, dts: Int64) {
            var out = Data()
            var keyframe = false
            for nal in Self.nalUnits(payload) where !nal.isEmpty {
                switch codec {
                case .h264:
                    let type = nal[0] & 0x1F
                    if type == 7 { sps = sps ?? nal; continue }
                    if type == 8 { pps = pps ?? nal; continue }
                    if type == 9 { continue }
                    if type == 5 { keyframe = true }
                case .hevc:
                    let type = (nal[0] >> 1) & 0x3F
                    if type == 32 { vps = vps ?? nal; continue }
                    if type == 33 { sps = sps ?? nal; continue }
                    if type == 34 { pps = pps ?? nal; continue }
                    if type == 35 { continue }
                    if (16...21).contains(type) { keyframe = true }
                }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
                out.append(contentsOf: nal)
            }
            guard !out.isEmpty else { return }
            samples.append(Sample(kind: .video, data: out, pts: pts, dts: dts, keyframe: keyframe))
        }

        /// Splits an Annex-B byte stream at its start codes.
        static func nalUnits(_ b: [UInt8]) -> [[UInt8]] {
            var units: [[UInt8]] = []
            var i = 0
            var start = -1
            let n = b.count
            while i + 2 < n {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        if end > start, b[end - 1] == 0 { end -= 1 }
                        units.append(Array(b[start..<end]))
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0, start < n { units.append(Array(b[start..<n])) }
            return units
        }

        // MARK: Audio

        private func audio(_ payload: [UInt8], pts: Int64) {
            var i = 0
            var data = Data()
            var frames: [Int] = []
            while i + 7 <= payload.count {
                guard payload[i] == 0xFF, payload[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
                let protectionAbsent = payload[i + 1] & 0x01 == 1
                let objectType = Int(payload[i + 2] >> 6) + 1
                let rateIndex = Int((payload[i + 2] >> 2) & 0x0F)
                let channels = Int((payload[i + 2] & 0x01) << 2) | Int(payload[i + 3] >> 6)
                let frameLength = (Int(payload[i + 3] & 0x03) << 11) | (Int(payload[i + 4]) << 3) | Int(payload[i + 5] >> 5)
                let header = protectionAbsent ? 7 : 9
                guard frameLength > header, i + frameLength <= payload.count else { break }
                if audioConfig == nil { audioConfig = (objectType, rateIndex, max(1, channels)) }
                data.append(contentsOf: payload[(i + header)..<(i + frameLength)])
                frames.append(frameLength - header)
                i += frameLength
            }
            guard !frames.isEmpty else { return }
            samples.append(Sample(kind: .audio, data: data, pts: pts, dts: pts, keyframe: true, frames: frames))
        }
    }

    // MARK: - Writer

    /// Feeds the samples into an AVAssetWriter (pass-through, no re-encoding).
    fileprivate final class Sink {
        private let writer: AVAssetWriter
        private var videoInput: AVAssetWriterInput?
        private var audioInput: AVAssetWriterInput?
        private var videoFormat: CMFormatDescription?
        private var audioFormat: CMFormatDescription?
        private var started = false
        private var pending: [Sample] = []
        private var base: Int64?
        private var heldVideo: Sample?
        private var sawVideo = false
        private var sawAudio = false
        private var sampleRate = 44100
        private let source: Demuxer

        init(output: URL, source: Demuxer) throws {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            self.source = source
        }

        func consume(_ samples: [Sample], final: Bool = false) async throws {
            pending.append(contentsOf: samples)
            for s in samples {
                if s.kind == .video { sawVideo = true } else { sawAudio = true }
            }
            if !started {
                guard final || readyToStart else { return }
                try begin()
            }
            let batch = pending
            pending = []
            for s in batch { try await write(s) }
            if final, let held = heldVideo {
                heldVideo = nil
                try await append(held, duration: CMTime(value: 3000, timescale: 90000))
            }
        }

        private var readyToStart: Bool {
            // Wait until both streams delivered something, or enough data piled up.
            (sawVideo && sawAudio) || pending.count > 400
        }

        private func begin() throws {
            let d = source
            if sawVideo, let format = try makeVideoFormat(d) {
                videoFormat = format
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) { writer.add(input); videoInput = input }
            }
            if sawAudio, let format = try makeAudioFormat(d) {
                audioFormat = format
                sampleRate = d.audioSampleRate
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) { writer.add(input); audioInput = input }
            }
            guard videoInput != nil || audioInput != nil else { throw RemuxError.noStreams }
            pending.removeAll { ($0.kind == .video && videoInput == nil) || ($0.kind == .audio && audioInput == nil) }
            base = pending.map { $0.kind == .video ? $0.dts : $0.pts }.min() ?? 0
            guard writer.startWriting() else { throw RemuxError.writer(writer.error?.localizedDescription ?? "Start") }
            writer.startSession(atSourceTime: .zero)
            started = true
        }

        private func makeVideoFormat(_ d: Demuxer) throws -> CMFormatDescription? {
            guard let sps = d.sps, let pps = d.pps else { return nil }
            var sets = [sps, pps]
            if d.codec == .hevc {
                guard let vps = d.vps else { return nil }
                sets = [vps, sps, pps]
            }
            let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
                p.initialize(from: set, count: set.count)
                return p
            }
            defer { pointers.enumerated().forEach { $0.element.deallocate() } }
            let constPointers = pointers.map { UnsafePointer($0) }
            let sizes = sets.map(\.count)
            var format: CMFormatDescription?
            let status: OSStatus = constPointers.withUnsafeBufferPointer { ptrs in
                sizes.withUnsafeBufferPointer { lens in
                    if d.codec == .hevc {
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: lens.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                    }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: lens.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard status == noErr else { throw RemuxError.writer("Videoformat (\(status))") }
            return format
        }

        private func makeAudioFormat(_ d: Demuxer) throws -> CMFormatDescription? {
            guard let c = d.audioConfig else { return nil }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(d.audioSampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(c.objectType),
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(c.channels),
                mBitsPerChannel: 0, mReserved: 0)
            // AudioSpecificConfig: object type, sample rate index, channel configuration.
            let config = UInt16(c.objectType << 11 | c.sampleRateIndex << 7 | c.channels << 3)
            var cookie: [UInt8] = [UInt8(config >> 8), UInt8(config & 0xFF)]
            var format: CMFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
                magicCookie: &cookie, extensions: nil, formatDescriptionOut: &format)
            guard status == noErr else { throw RemuxError.writer("Tonformat (\(status))") }
            return format
        }

        private func write(_ s: Sample) async throws {
            if s.kind == .audio {
                try await append(s, duration: .invalid)
                return
            }
            // Video durations come from the next frame's decode time.
            if let held = heldVideo {
                let delta = max(1, s.dts - held.dts)
                try await append(held, duration: CMTime(value: delta, timescale: 90000))
            }
            heldVideo = s
        }

        private func append(_ s: Sample, duration: CMTime) async throws {
            let isVideo = s.kind == .video
            guard let input = isVideo ? videoInput : audioInput, let format = isVideo ? videoFormat : audioFormat,
                  let base else { return }
            let block = try Self.blockBuffer(s.data)
            var sample: CMSampleBuffer?
            if isVideo {
                var timing = CMSampleTimingInfo(duration: duration,
                                                presentationTimeStamp: CMTime(value: s.pts - base, timescale: 90000),
                                                decodeTimeStamp: CMTime(value: s.dts - base, timescale: 90000))
                var size = s.data.count
                let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                       sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                       sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
                guard status == noErr, let sample else { return }
                if !s.keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
                   CFArrayGetCount(attachments) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
            } else {
                var offset: Int64 = 0
                let descriptions = s.frames.map { size -> AudioStreamPacketDescription in
                    defer { offset += Int64(size) }
                    return AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
                }
                let start = (s.pts - base) * Int64(sampleRate) / 90000
                let status = descriptions.withUnsafeBufferPointer { ptr in
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: s.frames.count,
                        presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)),
                        packetDescriptions: ptr.baseAddress, sampleBufferOut: &sample)
                }
                guard status == noErr else { return }
            }
            guard let sample else { return }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw RemuxError.writer(writer.error?.localizedDescription ?? "Schreiben") }
                try await Task.sleep(for: .milliseconds(5))
            }
            if !input.append(sample), writer.status == .failed {
                throw RemuxError.writer(writer.error?.localizedDescription ?? "Schreiben")
            }
        }

        private static func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block)
            guard status == noErr, let block else { throw RemuxError.writer("Speicher") }
            status = data.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
            }
            guard status == noErr else { throw RemuxError.writer("Speicher") }
            return block
        }

        func finish() async throws {
            guard started else { throw RemuxError.noStreams }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw RemuxError.writer(writer.error?.localizedDescription ?? "Abschluss")
            }
        }
    }
}
