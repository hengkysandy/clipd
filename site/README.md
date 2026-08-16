# The Clipd landing page

Static, no build step, no dependencies. Cloudflare Pages serves this directory
exactly as it is at <https://clipd.hengkysandy.com>.

## Deploying

```sh
wrangler pages deploy site --project-name clipd --branch main
```

The Pages project is `clipd`, the fallback URL is `clipd-8jk.pages.dev`, and
`clipd.hengkysandy.com` is a proxied CNAME to it.

## Rules this page keeps

- **No external requests at all.** No CDN, no web fonts, no analytics, no
  tracking pixels. A page whose argument is "nothing phones home" must not
  phone home. That is also why `_headers` can set
  `default-src 'self'; connect-src 'none'` and the page still works.
- **No inline styles or scripts**, so the strict Content-Security-Policy in
  `_headers` needs no `unsafe-inline`. Type stacks are the macOS system faces,
  which every visitor already has, since the app is macOS only.
- **Nothing is hidden until JavaScript runs.** An earlier draft revealed each
  section with an IntersectionObserver. A render at an unusual viewport showed
  a whole section blank, because the observer never fired for it. Animation is
  now CSS, and `script.js` only handles the copy buttons and the masthead
  hairline. Block the script and the page still reads.
- **Nothing on the page is invented.** No download counts, no testimonials, no
  star badges, no comparison table. Every claim is checkable in the repository,
  including the ones in "What you should know", which are the reasons somebody
  might decide not to install it.

## Regenerating the social card

`og.png` is rendered from `_og.html` and `og.css`, which exist only for that.
Neither is linked from the site.

```sh
python3 -m http.server 8791 --directory site
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --window-size=1200,630 \
  --screenshot=site/og.png http://127.0.0.1:8791/_og.html
```

## Screenshots

`site/images/` is copied from `docs/images/`, which is produced by a throwaway
instance of the app. See `ClipdMac/DemoMode.swift`. Every item on screen is
invented sample content, so nothing that was really copied is ever published.
