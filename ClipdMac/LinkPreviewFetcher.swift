import Foundation
import ImageIO
import UniformTypeIdentifiers
import ClipdCore

/// Fetches the picture and title a page advertises for sharing.
///
/// This is the only code in Clipd that talks to a machine the user does not
/// own, which is why it is one small file with every limit visible in it:
///
/// - it runs only when the user switches it on, and the switch starts off
/// - `previewRefusal` gets the first word, and a refusal never reaches the
///   network at all
/// - the session is ephemeral and sends no cookies, so a fetch cannot carry the
///   user's logged in identity to the site
/// - the body is cut off at 256 KB and the picture at 2 MB, because a preview
///   is not worth an unbounded download
/// - a redirect is re-checked against the same rules, so a public URL cannot
///   bounce the fetch onto localhost
/// - nothing from the page is ever executed. It is parsed as a string.
enum LinkPreviewFetcher {
    struct Outcome: Sendable {
        let title: String?
        let image: Data?
        /// Why the card looks the way it does. Stored, shown in the log, and
        /// deliberately free of the URL itself.
        let status: String
    }

    private static let htmlLimit = 256 * 1024
    private static let imageLimit = 2 * 1024 * 1024
    /// Twice the card's body width, so the picture is sharp on a retina screen
    /// and still a fraction of the original.
    private static let thumbnailPixels = 512

    /// An honest user agent.
    ///
    /// Rejected: pretending to be Safari, which would get metadata out of a few
    /// more sites. A site owner reading their log deserves to know what asked,
    /// and a clipboard manager quietly wearing a browser's name is exactly the
    /// behaviour this app exists to not have.
    private static let userAgent = "Clipd/0.8 (+https://clipd.hengkysandy.com)"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static func fetch(_ address: String) async -> Outcome {
        if let refusal = previewRefusal(for: address) {
            return Outcome(title: nil, image: nil, status: "refused:\(refusal.rawValue)")
        }
        guard let url = URL(string: address) else {
            return Outcome(title: nil, image: nil, status: "refused:notWebAddress")
        }

        // A site with a published oEmbed endpoint is asked that instead of
        // being read. See oEmbedEndpoint for the measurement behind it.
        var metadata: PreviewMetadata
        if let endpoint = oEmbedEndpoint(for: address), let endpointURL = URL(string: endpoint) {
            metadata = (try? await loadOEmbed(from: endpointURL))
                ?? PreviewMetadata(title: nil, imageURL: nil)
        } else {
            metadata = PreviewMetadata(title: nil, imageURL: nil)
        }

        // The page itself, when oEmbed was not available or gave nothing.
        if metadata.isEmpty {
            do {
                metadata = parsePreview(html: try await loadHTML(from: url))
            } catch {
                return Outcome(title: nil, image: nil, status: "failed:transport")
            }
        }
        guard !metadata.isEmpty else {
            return Outcome(title: nil, image: nil, status: "ok:nothingToShow")
        }

        var thumbnail: Data?
        if let imageAddress = resolvedImageURL(metadata.imageURL, pageURL: address),
           previewRefusal(for: imageAddress) == nil,
           let imageURL = URL(string: imageAddress) {
            thumbnail = try? await loadThumbnail(from: imageURL)
        }
        return Outcome(title: metadata.title, image: thumbnail,
                       status: thumbnail == nil ? "ok:titleOnly" : "ok")
    }

    // MARK: - Network

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // No referrer, and no identity of any kind beyond the user agent.
        request.httpShouldHandleCookies = false
        return request
    }

    /// Asks a site's oEmbed endpoint instead of reading its page.
    ///
    /// Capped like everything else. A reply is a few hundred bytes; anything
    /// larger than 32 KB is not an oEmbed reply and is not worth reading.
    private static func loadOEmbed(from url: URL) async throws -> PreviewMetadata {
        let guardDelegate = RedirectGuard()
        let (stream, response) = try await session.bytes(
            for: request(url, accept: "application/json"), delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { throw PreviewError.badStatus }
        var buffer = Data()
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count > 32 * 1024 { throw PreviewError.tooBig }
        }
        return parseOEmbed(buffer)
    }

    /// Reads at most `htmlLimit` bytes, then stops.
    ///
    /// A byte stream rather than `data(for:)` so the cap is real. `data(for:)`
    /// would pull a 40 MB page into memory before anyone could object, and the
    /// four attributes we want are in the first few kilobytes of the head.
    private static func loadHTML(from url: URL) async throws -> String {
        let guardDelegate = RedirectGuard()
        let (stream, response) = try await session.bytes(
            for: request(url, accept: "text/html,application/xhtml+xml"),
            delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PreviewError.badStatus
        }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        // Two ways to stop: the head ends, or the cap is reached.
        //
        // Everything worth reading is in the head, and stopping there is what
        // makes the usual case cheap: measured, GitHub closes its head at 30 KB
        // of a 336 KB page, so this reads a tenth of it and hangs up.
        //
        // Compared against the last six bytes rather than searching the whole
        // buffer, which would re-scan everything already read on every single
        // byte and turn a 256 KB page into 32 billion comparisons.
        let terminator = Array("</head".utf8)
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= terminator.count,
               buffer.suffix(terminator.count).map({ $0 | 0x20 }) == terminator { break }
            if buffer.count >= htmlLimit { break }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Downloads the picture and re-encodes it small.
    ///
    /// The original is often a 1.5 MB share card. Storing that per link would
    /// bloat the database for a 226 point wide thumbnail nobody zooms into, so
    /// what is kept is a JPEG no wider than `thumbnailPixels`.
    private static func loadThumbnail(from url: URL) async throws -> Data {
        let guardDelegate = RedirectGuard()
        let (stream, response) = try await session.bytes(
            for: request(url, accept: "image/*"), delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { throw PreviewError.badStatus }
        // The declared length is a hint, not a promise, so the loop below still
        // counts. This only avoids starting a download we know is too big.
        if http.expectedContentLength > Int64(imageLimit) { throw PreviewError.tooBig }
        var buffer = Data()
        for try await byte in stream {
            buffer.append(byte)
            if buffer.count > imageLimit { throw PreviewError.tooBig }
        }
        guard let shrunk = downscale(buffer) else { throw PreviewError.notAnImage }
        return shrunk
    }

    /// ImageIO rather than NSImage, because this runs off the main thread and
    /// because it never has to build a full sized bitmap of a huge picture: the
    /// thumbnail options do the scaling during decode.
    private static func downscale(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    enum PreviewError: Error { case badStatus, tooBig, notAnImage }
}

/// Re-checks every redirect against the same rules as the first URL.
///
/// Without this, a public link that redirects to http://localhost/admin would
/// have the app fetch the user's own machine on someone else's instruction.
/// Returning nil cancels the redirect and ends the task.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url?.absoluteString, previewRefusal(for: url) == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
