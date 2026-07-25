# bich.service

A progressive web app for finding small local gatherings. Photograph a flyer,
the app reads it and fills in the event.

Live at **[bich.app](https://bich.app)**, served by GitHub Pages from the root
of this repository.

---

## Layout

```
.
├── index.html              the entire app: markup, styles, logic
├── config.js               public addresses and keys — no secrets
├── sw.js                   service worker
├── manifest.webmanifest    PWA manifest
├── 404.html                rewrites /e/<id> share links back into the app
├── CNAME                   bich.app
├── apple-touch-icon.png    Safari looks here by default
├── icons/                  app icons, referenced as /icons/… by the manifest
├── worker/                 Cloudflare Worker — Gemini + R2
├── docs/                   schema spec and the code review
└── archive/                dead code, kept for reference. Not loaded.
```

Everything the browser loads has to stay at the repository root: GitHub Pages
serves from `/` (or `/docs`, nothing else), the service worker needs root scope
to control the whole origin, and `manifest.webmanifest` declares `"scope": "/"`.
Moving `index.html` into a subfolder would take the site offline.

`worker/`, `docs/` and `archive/` are never fetched by the browser, so they can
live wherever is tidiest.

### About `archive/`

`store.js`, `photo-pipeline.js` and `themes.css` are **not loaded by anything**.
Each is duplicated inline inside `index.html`, and the copies have drifted —
`photo-pipeline.js` in particular is an older version of the photo pipeline with
bugs the inline copy has already fixed.

They are parked in `archive/` so nobody edits them expecting the app to change.
See `docs/BUGS.md` §1. Either delete them or wire them up; do not leave both.

---

## Running it

The frontend is static. Any static server works:

```bash
python3 -m http.server 8000
```

`config.js` points at production. To run against something else, edit it — it is
the only place addresses live.

## Deploying the worker

```bash
cd worker
wrangler r2 bucket create bich-covers
wrangler secret put GEMINI_API_KEY
wrangler deploy
```

`wrangler.toml` provisions `api.bich.app` as a custom domain. Do not add an
`api` DNS record by hand; Cloudflare creates it on deploy and a manual one
conflicts.

### Secrets

`GEMINI_API_KEY` is the only secret, and it lives only in Cloudflare, set with
`wrangler secret put`. Never in a file, never in this repo.

The Supabase **anon** key in `config.js` is public by design — row level
security is what protects the data, not the key. The **service role** key is not
used anywhere in this system and must never be added.

---

## Releasing

Three version strings need bumping together, which is one more than there should
be (see `docs/BUGS.md` §30):

- `index.html` → `<meta name="app-version">`
- `config.js` → `version`
- `sw.js` → `CACHE_VERSION`

The service worker is network-first for HTML and `config.js`, so a bumped
`CACHE_VERSION` is what actually clears old assets from phones.

---

## Known issues

`docs/BUGS.md` — 40 findings from a full review, ordered by impact. The three at
the top break things today.

## Not in this repo, and should be

The database schema and its row level security policies. Comments throughout the
code refer to "schema part 4" and "spec 7.2"; neither exists here. RLS is the
only thing protecting the data behind a public anon key, and right now it lives
solely as state inside a hosted Supabase project. Export it to `docs/schema.sql`.
