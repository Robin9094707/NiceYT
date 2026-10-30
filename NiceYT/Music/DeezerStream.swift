import AVFoundation
import CommonCrypto
import CryptoKit
import Foundation

/// Deezer's "BF_CBC_STRIPE" cipher: the file is split into 2048-byte chunks and every
/// third full chunk (index 0, 3, 6 …) is Blowfish-CBC encrypted with a per-track key and a
/// fixed IV. Each chunk can be decrypted on its own, so seeking works without reading
/// the whole file.
final class DeezerDecryptor {
    static let chunkSize = 2048
    private static let secret = Array("g4el58wc0zvf9na1".utf8)
    private static let iv: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]

    private let key: [UInt8]

    init(trackId: String) {
        let hex = Array(Insecure.MD5.hash(data: Data(trackId.utf8)).map { String(format: "%02x", $0) }.joined().utf8)
        key = (0..<16).map { hex[$0] ^ hex[$0 + 16] ^ Self.secret[$0] }
    }

    static func isEncrypted(chunkIndex: Int64) -> Bool { chunkIndex % 3 == 0 }

    /// Decrypts one full chunk in place.
    func decryptChunk(_ chunk: inout Data) {
        guard chunk.count == Self.chunkSize else { return }
        var out = [UInt8](repeating: 0, count: Self.chunkSize)
        var moved = 0
        let status = chunk.withUnsafeBytes { input in
            key.withUnsafeBytes { k in
                Self.iv.withUnsafeBytes { iv in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmBlowfish), 0,
                            k.baseAddress, key.count, iv.baseAddress,
                            input.baseAddress, Self.chunkSize, &out, Self.chunkSize, &moved)
                }
            }
        }
        if status == CCCryptorStatus(kCCSuccess), moved == Self.chunkSize { chunk = Data(out) }
    }

    /// Decrypts `data`, whose first byte sits at the chunk-aligned file offset `offset`.
    /// Returns the bytes of all complete chunks and leaves an incomplete tail in `data`.
    func process(_ data: inout Data, at offset: inout Int64, final: Bool) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var start = data.startIndex
        while data.endIndex - start >= Self.chunkSize {
            var chunk = Data(data[start..<start + Self.chunkSize])
            if Self.isEncrypted(chunkIndex: offset / Int64(Self.chunkSize)) { decryptChunk(&chunk) }
            out.append(chunk)
            start += Self.chunkSize
            offset += Int64(Self.chunkSize)
        }
        if final, start < data.endIndex {
            // The last, shorter chunk of the file is never encrypted.
            out.append(data[start...])
            offset += Int64(data.endIndex - start)
            start = data.endIndex
        }
        data = Data(data[start...])
        return out
    }
}

/// Feeds AVPlayer with decrypted audio straight from Deezer's CDN: requests arrive through
/// a custom URL scheme, are widened to chunk boundaries, fetched with HTTP ranges and
/// decrypted while they stream in.
final class DeezerStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "nicedz"

    let queue = DispatchQueue(label: "niceplay.deezer.stream")
    private let source: URL
    private let quality: DZQuality
    private let decryptor: DeezerDecryptor
    private var totalLength: Int64?
    private var session: URLSession!
    private var jobs: [Int: Job] = [:]

    private final class Job {
        let request: AVAssetResourceLoadingRequest
        var position: Int64
        var buffer = Data()
        let end: Int64?
        var task: URLSessionDataTask?

        init(request: AVAssetResourceLoadingRequest, position: Int64, end: Int64?) {
            self.request = request
            self.position = position
            self.end = end
        }
    }

    init(source: URL, trackId: String, quality: DZQuality) {
        self.source = source
        self.quality = quality
        decryptor = DeezerDecryptor(trackId: trackId)
        super.init()
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: operations)
    }

    /// URL to hand to AVURLAsset (the extension tells AVFoundation the container).
    static func assetURL(trackId: String, quality: DZQuality) -> URL {
        URL(string: "\(scheme)://track/\(trackId).\(quality.fileExtension)")!
    }

    /// Ends all transfers (the session keeps its delegate alive until then).
    func invalidate() {
        queue.async {
            self.jobs.values.forEach { $0.task?.cancel() }
            self.jobs.removeAll()
            self.session.invalidateAndCancel()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let chunk = Int64(DeezerDecryptor.chunkSize)
        var offset: Int64 = 0
        var end: Int64?
        if let data = loadingRequest.dataRequest {
            offset = data.requestedOffset
            if !data.requestsAllDataToEndOfResource {
                end = offset + Int64(data.requestedLength)
            }
        }
        let alignedStart = (offset / chunk) * chunk
        var alignedEnd = end.map { (($0 + chunk - 1) / chunk) * chunk }
        if let total = totalLength, let e = alignedEnd { alignedEnd = min(e, total) }

        var req = URLRequest(url: source, timeoutInterval: 30)
        req.setValue(Deezer.userAgent, forHTTPHeaderField: "User-Agent")
        if let alignedEnd {
            req.setValue("bytes=\(alignedStart)-\(alignedEnd - 1)", forHTTPHeaderField: "Range")
        } else {
            req.setValue("bytes=\(alignedStart)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: req)
        let job = Job(request: loadingRequest, position: alignedStart, end: end)
        job.task = task
        jobs[task.taskIdentifier] = job
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, job) in jobs where job.request === loadingRequest {
            job.task?.cancel()
            jobs[id] = nil
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = jobs[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            job.request.finishLoading(with: NSError(domain: "NicePlay.Deezer", code: http.statusCode,
                                                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            jobs[dataTask.taskIdentifier] = nil
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 {
            // Range ignored: the body starts at the beginning of the file.
            job.position = 0
            if totalLength == nil, http.expectedContentLength > 0 { totalLength = http.expectedContentLength }
        } else if let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            totalLength = total
        }
        if let info = job.request.contentInformationRequest {
            info.contentType = quality.contentType
            info.contentLength = totalLength ?? 0
            info.isByteRangeAccessSupported = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = jobs[dataTask.taskIdentifier] else { return }
        job.buffer.append(data)
        var position = job.position
        let start = position
        let plain = decryptor.process(&job.buffer, at: &position, final: false)
        job.position = position
        deliver(plain, from: start, to: job)
        if let end = job.end, let current = job.request.dataRequest?.currentOffset, current >= end {
            job.request.finishLoading()
            jobs[dataTask.taskIdentifier] = nil
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs[task.taskIdentifier] else { return }
        jobs[task.taskIdentifier] = nil
        if let error {
            if (error as NSError).code != NSURLErrorCancelled { job.request.finishLoading(with: error) }
            return
        }
        var position = job.position
        let start = position
        let plain = decryptor.process(&job.buffer, at: &position, final: true)
        deliver(plain, from: start, to: job)
        job.request.finishLoading()
    }

    /// Hands AVPlayer the part of `plain` (starting at file offset `from`) it asked for.
    private func deliver(_ plain: Data, from: Int64, to job: Job) {
        guard !plain.isEmpty, let dataRequest = job.request.dataRequest else { return }
        let wantedFrom = dataRequest.currentOffset
        let wantedTo = job.end ?? Int64.max
        let chunkEnd = from + Int64(plain.count)
        let lower = max(from, wantedFrom)
        let upper = min(chunkEnd, wantedTo)
        guard upper > lower else { return }
        let a = plain.startIndex + Int(lower - from)
        let b = plain.startIndex + Int(upper - from)
        dataRequest.respond(with: plain.subdata(in: a..<b))
    }
}
