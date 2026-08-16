# The Clipd landing page

Static, no build step, no dependencies. Cloudflare Pages serves this directory
exactly as it is at <https://clipd.hengkysandy.com>.

```sh
wrangler pages deploy site --project-name clipd --branch main
```

The Pages project is `clipd`, the fallback URL is `clipd-8jk.pages.dev`, and
`clipd.hengkysandy.com` is a proxied CNAME to it.

## The hero is the product, not a picture of it

The most characteristic moment in a clipboard manager is pressing a key and
having your past appear. A screenshot cannot show that, so the hero is a
working miniature: an editor, a docked panel, real cards. Click one, press
<kbd>1</kbd> to <kbd>6</kbd>, or press the app's own <kbd>⌘⇧V</kbd> and the page
answers it. The text types itself in and then the syntax colours arrive, which
is also the order the real app works in: it takes the text first and works out
the language from it afterwards.

The whole demo is in the markup. With `app.js` blocked, the hero still shows a
selected card and a pasted snippet, because nothing on this page is allowed to
depend on JavaScript to become visible.

## Rules this page keeps

- **No external requests at all.** No CDN, no web fonts from anyone else, no
  analytics, no tracking pixels. IBM Plex is self-hosted in `fonts/`, latin
  subsets only, about 116 KB. A page whose argument is "nothing phones home"
  must not phone home, and that is what lets `_headers` say
  `default-src 'self'; connect-src 'none'` with the page still working.
- **No inline styles or scripts**, so the strict Content-Security-Policy needs
  no `unsafe-inline`. Verified by loading the page with the real policy as a
  meta tag and reading the console.
- **Nothing is hidden until JavaScript runs.** An earlier draft revealed each
  section with an IntersectionObserver. A render at a tall viewport showed one
  section completely blank, because the observer never fired for it. Reveals
  are now CSS scroll-driven animations behind `@supports`, so the absence of
  the feature means "visible", never "invisible".
- **Nothing on the page is invented.** No download counts, no testimonials, no
  star badges, no comparison table. Every claim is checkable in the repository,
  including the ones under "What you should know", which are the reasons
  somebody might decide not to install it.

## Caching, and the trap in it

`app.css` and `app.js` carry no content hash in their names, and **Cloudflare
Pages puts `max-age=14400` on static assets whether or not `_headers` asks for
something shorter.** An earlier `_headers` also tried to target them with
`/*.css`, which Pages ignores, because a wildcard only matches at the end of a
path.

The result was a deploy that went out with new markup and a four hour old
stylesheet. The page rendered almost unstyled, and nothing in the deploy log
said anything was wrong. It was caught by fetching the live CSS and grepping it
for a rule that should have been there.

If a deploy ever looks stale, check it the same way:

```sh
curl -sI https://clipd.hengkysandy.com/app.css | grep -i 'cache-control\|cf-cache'
curl -s  https://clipd.hengkysandy.com/app.css | grep -c 'some-new-rule'
```

The fix that always works is to rename the file, since a new path has no cached
entry. Purging the cache through the API needs a token with Cache Purge, which
the personal token does not have.

## Regenerating the social card

`og.png` is rendered from `_og.html` and `og.css`, which exist only for that and
are not linked from the site.

```sh
python3 -m http.server 8791 --directory site
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --window-size=1200,630 \
  --screenshot=site/og.png http://127.0.0.1:8791/_og.html
```

## Screenshots

`site/images/` is copied from `docs/images/`, produced by a throwaway instance
of the app. See `ClipdMac/DemoMode.swift`. Every item on screen is invented
sample content, so nothing that was really copied is ever published.
