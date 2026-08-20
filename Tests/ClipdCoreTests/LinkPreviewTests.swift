import Testing
import Foundation
@testable import ClipdCore

@Test("The scheme is dropped, because every link card has one")
func dropsTheScheme() {
    #expect(shortLinkLabel("https://github.com/hengkysandy/clipd")
            == "github.com/hengkysandy/clipd")
    #expect(shortLinkLabel("http://example.com/a") == "example.com/a")
}

@Test("An uppercase scheme is still a scheme")
func dropsAnUppercaseScheme() {
    #expect(shortLinkLabel("HTTPS://Example.com/A") == "Example.com/A")
}

@Test("www is dropped, the rest of the host is not")
func dropsWWWOnly() {
    #expect(shortLinkLabel("https://www.bilibili.tv/en/video/48003") == "bilibili.tv/en/video/48003")
    // The guard is a prefix check, so a host that merely starts with those
    // letters must survive intact.
    #expect(shortLinkLabel("https://wwwe.example.com") == "wwwe.example.com")
}

@Test("A bare trailing slash goes, a path's trailing slash stays")
func trailingSlash() {
    #expect(shortLinkLabel("https://github.com/") == "github.com")
    // Dropping this one would name a different page, so it stays.
    #expect(shortLinkLabel("https://github.com/hengkysandy/") == "github.com/hengkysandy/")
}

@Test("The path, query and fragment are kept in full")
func keepsEverythingElse() {
    let url = "https://www.youtube.com/watch?v=abc123&t=90s#top"
    #expect(shortLinkLabel(url) == "youtube.com/watch?v=abc123&t=90s#top")
}

@Test("Truncation is the label's job, not this function's")
func doesNotTruncate() {
    let long = "https://example.com/" + String(repeating: "a", count: 500)
    #expect(shortLinkLabel(long).count == 500 + "example.com/".count)
}

// MARK: - What may be fetched

@Test("An ordinary page is fetchable")
func ordinaryPageIsAllowed() {
    #expect(previewRefusal(for: "https://github.com/hengkysandy/clipd") == nil)
    #expect(previewRefusal(for: "https://en.wikipedia.org/wiki/Clipboard_(computing)") == nil)
    // "author" must survive, or half the web is refused.
    #expect(previewRefusal(for: "https://example.com/author/hengky") == nil)
}

@Test("A one time link is never fetched, because fetching it can spend it")
func refusesSingleUseLinks() {
    // The real one, off this machine's own clipboard.
    #expect(previewRefusal(for: "https://claude.com/oai/oauth/authorize?code=true&client_id=abc")
            == .looksSingleUse)
    #expect(previewRefusal(for: "https://app.example.com/reset?t=xyz") == .looksSingleUse)
    #expect(previewRefusal(for: "https://mail.example.com/verify/9f2c") == .looksSingleUse)
    #expect(previewRefusal(for: "https://bucket.r2.dev/f.pdf?X-Amz-Signature=deadbeef")
            == .looksSingleUse)
    #expect(previewRefusal(for: "https://example.com/i/abc?token=123") == .looksSingleUse)
}

@Test("Nothing on this machine or this LAN is fetched")
func refusesPrivateHosts() {
    #expect(previewRefusal(for: "http://localhost:8080/admin") == .privateHost)
    #expect(previewRefusal(for: "http://127.0.0.1/") == .privateHost)
    #expect(previewRefusal(for: "http://192.168.1.10/status") == .privateHost)
    #expect(previewRefusal(for: "http://172.20.0.4/") == .privateHost)
    #expect(previewRefusal(for: "http://nas.local/photos") == .privateHost)
    // 172.32 is public, so it must NOT be caught by the /12 rule.
    #expect(previewRefusal(for: "http://172.32.0.4/") == nil)
}

@Test("Credentials in the URL stop the fetch")
func refusesCredentials() {
    #expect(previewRefusal(for: "https://user:pass@example.com/") == .hasCredentials)
}

@Test("Anything that is not a web address is refused")
func refusesNonWeb() {
    #expect(previewRefusal(for: "ftp://example.com/file") == .notWebAddress)
    #expect(previewRefusal(for: "file:///Users/me/secret.txt") == .notWebAddress)
    #expect(previewRefusal(for: "not a url at all") == .notWebAddress)
}

// MARK: - Reading the page

private let realish = """
<!doctype html><html><head>
<meta charset="utf-8">
<title>Fallback title &amp; more</title>
<meta property="og:title" content="Murder Game (2026) Sub Indo">
<meta property="og:image" content="https://cdn.example.com/a.jpg">
<meta property="og:image" content="https://cdn.example.com/second.jpg">
<meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
</head><body>...</body></html>
"""

@Test("Open Graph wins, and the first image wins")
func readsOpenGraph() {
    let meta = parsePreview(html: realish)
    #expect(meta.title == "Murder Game (2026) Sub Indo")
    #expect(meta.imageURL == "https://cdn.example.com/a.jpg")
}

@Test("The title tag is the fallback, entities and all")
func fallsBackToTitleTag() {
    let html = "<html><head><title>Fallback title &amp; more</title></head></html>"
    #expect(parsePreview(html: html).title == "Fallback title & more")
    #expect(parsePreview(html: html).imageURL == nil)
}

@Test("Single quotes and a reversed attribute order still parse")
func handlesUglyMarkup() {
    let html = "<meta content='https://x.test/i.png' property='og:image'/>"
    #expect(parsePreview(html: html).imageURL == "https://x.test/i.png")
}

@Test("Twitter tags are read when Open Graph is missing")
func readsTwitterTags() {
    let html = "<meta name=\"twitter:image\" content=\"https://x.test/t.png\">"
    #expect(parsePreview(html: html).imageURL == "https://x.test/t.png")
}

@Test("A page that says nothing about itself yields nothing")
func emptyPage() {
    #expect(parsePreview(html: "<html><body>hello</body></html>").isEmpty)
}

@Test("A relative image resolves against the page it came from")
func resolvesRelativeImages() {
    let page = "https://example.com/blog/post"
    #expect(resolvedImageURL("/img/a.png", pageURL: page) == "https://example.com/img/a.png")
    #expect(resolvedImageURL("//cdn.example.com/b.png", pageURL: page)
            == "https://cdn.example.com/b.png")
    #expect(resolvedImageURL("https://cdn.example.com/c.png", pageURL: page)
            == "https://cdn.example.com/c.png")
}

@Test("Only http and https ever reach the network layer")
func refusesOtherImageSchemes() {
    #expect(resolvedImageURL("data:image/png;base64,AAAA", pageURL: "https://example.com") == nil)
    #expect(resolvedImageURL("file:///etc/passwd", pageURL: "https://example.com") == nil)
    #expect(resolvedImageURL(nil, pageURL: "https://example.com") == nil)
}

// MARK: - oEmbed, for the one site that buries its metadata

@Test("Every shape of YouTube link gets the oEmbed endpoint")
func youTubeUsesOEmbed() throws {
    for address in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    "https://youtube.com/watch?v=dQw4w9WgXcQ",
                    "https://youtu.be/dQw4w9WgXcQ",
                    "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
                    "https://www.youtube.com/shorts/5qap5aO4i9A"] {
        let endpoint = try #require(oEmbedEndpoint(for: address),
                                    "no endpoint for \(address)")
        #expect(endpoint.hasPrefix("https://www.youtube.com/oembed?format=json&url="))
        // The link must arrive as one escaped parameter, not as extra query
        // parameters of our own request.
        #expect(!endpoint.dropFirst(47).contains("&"))
    }
}

@Test("A host that merely looks like YouTube is not YouTube")
func doesNotMatchLookalikeHosts() {
    #expect(oEmbedEndpoint(for: "https://notyoutube.com/watch?v=x") == nil)
    #expect(oEmbedEndpoint(for: "https://youtube.com.evil.test/watch?v=x") == nil)
    #expect(oEmbedEndpoint(for: "https://github.com/hengkysandy/clipd") == nil)
}

@Test("An oEmbed reply gives up its title and picture")
func readsAnOEmbedReply() {
    let json = """
    {"title":"Rick Astley - Never Gonna Give You Up","author_name":"Rick Astley",
     "thumbnail_url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
     "thumbnail_width":480}
    """
    let meta = parseOEmbed(Data(json.utf8))
    #expect(meta.title == "Rick Astley - Never Gonna Give You Up")
    #expect(meta.imageURL == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
}

@Test("Anything that is not an oEmbed reply yields nothing rather than throwing")
func survivesRubbishFromTheEndpoint() {
    #expect(parseOEmbed(Data("<html>not json</html>".utf8)).isEmpty)
    #expect(parseOEmbed(Data()).isEmpty)
    // Valid JSON, wrong shape. Both fields are optional, so this decodes to an
    // empty reply rather than failing, and empty is the right answer.
    #expect(parseOEmbed(Data("{\"error\":\"not found\"}".utf8)).isEmpty)
}
