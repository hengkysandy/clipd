import Foundation

/// What a link card shows where a text card shows its character count.
///
/// A character count on a link is useless: nobody wants to know that a URL is
/// 47 characters long. The address is the one piece of information that tells
/// you whether this is the link you meant, so that is what the footer carries.
///
/// The scheme goes because every link here is http or https by definition (see
/// `HistoryItem.detectKind`), so it is 8 characters of nothing. `www.` goes for
/// the same reason. The trailing slash goes because "github.com/" and
/// "github.com" are the same place and the slash only costs width.
///
/// Truncation is deliberately NOT done here. The label knows how many points it
/// has and truncates to fit; a character limit in this function would either
/// cut a short address that would have fitted or leave a long one clipping.
public func shortLinkLabel(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
        text = String(text.dropFirst(scheme.count))
        break
    }
    if text.lowercased().hasPrefix("www.") {
        text = String(text.dropFirst(4))
    }
    // Only a bare trailing slash, and only when something is left in front of
    // it. Stripping it from "example.com/path/" would change which page it is.
    if text.hasSuffix("/"), !text.dropLast().contains("/"), text.count > 1 {
        text = String(text.dropLast())
    }
    return text
}

/// Why a URL will not be fetched for a preview.
///
/// A reason, not a bool. When a card shows no picture the only question worth
/// answering is "why not", and a false cannot answer it.
public enum PreviewRefusal: String, Equatable, Sendable {
    case notWebAddress
    case hasCredentials
    case privateHost
    case looksSingleUse
}

/// Hosts that are on this machine or on the local network.
///
/// Fetching one of these would make the app probe the user's own network from
/// inside their own machine, which is a scan, not a preview.
private func isPrivateHost(_ host: String) -> Bool {
    let h = host.lowercased()
    if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }
    if h == "0.0.0.0" || h.hasPrefix("127.") || h.hasPrefix("10.") { return true }
    if h.hasPrefix("192.168.") || h.hasPrefix("169.254.") { return true }
    // 172.16.0.0/12 is 172.16 through 172.31, so the second octet decides.
    let parts = h.split(separator: ".")
    if parts.count == 4, parts[0] == "172", let second = Int(parts[1]),
       (16...31).contains(second) { return true }
    return false
}

/// Query and path words that mean "this link is a key, not a page".
///
/// A GET on a magic login link, a password reset, an invite or a signed
/// download can spend it. The link then fails for the person who copied it, and
/// the app that broke it never said anything. That failure is invisible and
/// unrecoverable, so the test is deliberately wide: refusing to preview a page
/// that would have been fine costs a thumbnail, which is nothing.
private let singleUseMarkers = [
    "token", "access_token", "id_token", "code=", "otp", "magic",
    "reset", "verify", "confirm", "invite", "activate", "unsubscribe",
    "signature", "x-amz-signature", "sig=", "key=", "secret", "password",
    "oauth", "auth=", "/auth/", "session", "ticket", "nonce", "expires",
]
// Deliberately NOT here: a bare "auth". It matches "author", which is an
// ordinary word in ordinary paths, and refusing every page with an author in
// its URL would make the feature look broken rather than careful.

/// Whether this URL may be fetched, and if not, why not.
public func previewRefusal(for raw: String) -> PreviewRefusal? {
    guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else { return .notWebAddress }
    // user:password@host. Fetching it would send those credentials.
    if url.user != nil || url.password != nil { return .hasCredentials }
    if isPrivateHost(host) { return .privateHost }
    let rest = (url.path + "?" + (url.query ?? "")).lowercased()
    if singleUseMarkers.contains(where: { rest.contains($0) }) { return .looksSingleUse }
    return nil
}

/// What a page says about itself.
public struct PreviewMetadata: Equatable, Sendable {
    public let title: String?
    public let imageURL: String?

    public init(title: String?, imageURL: String?) {
        self.title = title
        self.imageURL = imageURL
    }

    public var isEmpty: Bool { title == nil && imageURL == nil }
}

/// The handful of HTML entities that actually turn up inside a title.
///
/// Not a general entity decoder. A title is one line of prose, and the five
/// escapes below cover what real pages put in one. `&amp;` is last on purpose:
/// decoding it first would turn "&amp;lt;" into "<" instead of "&lt;".
private func decodeEntities(_ text: String) -> String {
    var out = text
    for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
                                ("&amp;", "&")] {
        out = out.replacingOccurrences(of: entity, with: character)
    }
    return out
}

private func attribute(_ name: String, in tag: String) -> String? {
    // Both quote styles, because plenty of real pages use single quotes.
    for quote in ["\"", "'"] {
        let pattern = "\(name)\\s*=\\s*\(quote)([^\(quote)]*)\(quote)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { continue }
        return String(tag[range])
    }
    return nil
}

/// Reads the title and picture a page advertises for sharing.
///
/// A hand rolled reader rather than a HTML parser, and deliberately so. The
/// whole job is four attributes out of the head, the input is already capped at
/// the first slice of the document, and adding a parser dependency to read four
/// strings would be the larger risk of the two.
///
/// Nothing here executes anything from the page. It is string matching over
/// bytes that never reach a web view.
public func parsePreview(html: String) -> PreviewMetadata {
    var byKey: [String: String] = [:]
    if let metaRegex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>",
                                                options: .caseInsensitive) {
        let full = NSRange(html.startIndex..., in: html)
        for match in metaRegex.matches(in: html, range: full) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            // property is the Open Graph spelling, name is the Twitter one.
            // Pages use both, sometimes on the same tag.
            let key = attribute("property", in: tag) ?? attribute("name", in: tag)
            guard let key, let content = attribute("content", in: tag),
                  !content.isEmpty else { continue }
            let lowered = key.lowercased()
            // First wins. A page that repeats og:image lists its best one
            // first, and later ones are usually per-section fallbacks.
            if byKey[lowered] == nil { byKey[lowered] = content }
        }
    }

    var title = byKey["og:title"] ?? byKey["twitter:title"]
    if title == nil,
       let regex = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>",
                                            options: .caseInsensitive),
       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
       let range = Range(match.range(at: 1), in: html) {
        title = String(html[range])
    }

    let image = byKey["og:image"] ?? byKey["og:image:url"] ?? byKey["twitter:image"]
        ?? byKey["twitter:image:src"]

    let cleanTitle = title.map {
        decodeEntities($0.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "\n", with: " ")
    }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }

    return PreviewMetadata(title: cleanTitle,
                           imageURL: image.map { decodeEntities($0.trimmingCharacters(in: .whitespaces)) })
}

/// Turns whatever the page said into an absolute http(s) URL, or nothing.
///
/// Pages give relative paths, protocol relative paths, and occasionally a
/// data: URI. The first two resolve against the page; the third is refused,
/// because the point of resolving here is that exactly one kind of thing
/// reaches the network layer.
public func resolvedImageURL(_ candidate: String?, pageURL: String) -> String? {
    guard let candidate, !candidate.isEmpty, let base = URL(string: pageURL) else { return nil }
    var text = candidate
    if text.hasPrefix("//") { text = (base.scheme ?? "https") + ":" + text }
    guard let resolved = URL(string: text, relativeTo: base)?.absoluteURL,
          let scheme = resolved.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return nil }
    return resolved.absoluteString
}

/// The oEmbed endpoint for a site whose own page is not worth reading, or nil.
///
/// One provider, and it earns its special case with a measurement. YouTube puts
/// its og:image 674 KB into a 1.3 MB page, which is 25 times further in than any
/// other site tested (GitHub 27 KB, X 5 KB, Instagram 7 KB). Reading far enough
/// to find it means downloading most of a megabyte to collect four attributes.
/// The oEmbed reply carries the same title and picture in about 500 bytes.
///
/// This is not a new disclosure: asking YouTube about a YouTube link tells
/// YouTube exactly what fetching the page would have told it.
public func oEmbedEndpoint(for address: String) -> String? {
    guard let url = URL(string: address), let host = url.host?.lowercased() else { return nil }
    // Suffix matching on the host, never a substring of the whole address.
    // "notyoutube.com" and "youtube.com.evil.test" must not match, and they
    // would if this looked for "youtube.com" anywhere in the string.
    let isYouTube = host == "youtu.be" || host == "youtube.com"
        || host.hasSuffix(".youtube.com")
    guard isYouTube else { return nil }
    guard let escaped = address.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics) else { return nil }
    return "https://www.youtube.com/oembed?format=json&url=\(escaped)"
}

/// The two fields of an oEmbed reply that a card can show.
private struct OEmbedReply: Decodable {
    let title: String?
    let thumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case thumbnailURL = "thumbnail_url"
    }
}

/// Reads an oEmbed reply. Returns empty metadata if it is not one.
public func parseOEmbed(_ data: Data) -> PreviewMetadata {
    guard let reply = try? JSONDecoder().decode(OEmbedReply.self, from: data) else {
        return PreviewMetadata(title: nil, imageURL: nil)
    }
    let title = reply.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return PreviewMetadata(title: (title?.isEmpty ?? true) ? nil : String(title!.prefix(200)),
                           imageURL: reply.thumbnailURL)
}
