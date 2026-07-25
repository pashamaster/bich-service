# worker

The Cloudflare Worker behind `api.bich.app`. It holds the two things the browser
must never see: the Gemini API key, and write access to the R2 image bucket.

It holds **no** Supabase credentials. Event rows go straight from the browser to
Supabase with the publishable anon key, and the database's own row policies
decide what is allowed. That keeps the service role key out of every system.

## Routes

| method | path | does |
|---|---|---|
| POST | `/extract-event` | image (base64) → structured event records via Gemini |
| POST | `/upload` | multipart `full` + `thumb` → stored in R2, returns URLs |
| GET | `/img/<key>` | serves a stored image |

`/events` is **not** a route, despite `index.html` posting to it on every
publish. See `docs/BUGS.md` §3.

## Deploy

```bash
wrangler r2 bucket create bich-covers
wrangler secret put GEMINI_API_KEY
wrangler deploy
```

## Configuration

Vars live in `wrangler.toml`; the key lives in an encrypted secret.

| name | kind | notes |
|---|---|---|
| `GEMINI_API_KEY` | secret | `wrangler secret put` only |
| `GEMINI_MODEL` | var | `gemini-3.5-flash-lite` |
| `ALLOWED_ORIGINS` | var | comma separated. CORS only — not access control |
| `PUBLIC_IMG_BASE` | var | R2 custom domain, so images skip the worker |
| `BICH_INVITE_CODES` | var | comma separated. **Empty means open** |
| `DAILY_CAP` | var | approximate. See `docs/BUGS.md` §22 |
| `BICH_KV` | binding | optional quota counter, commented out by default |

## Before this handles real traffic

`BICH_INVITE_CODES` is empty, so `/upload` currently accepts anonymous uploads
from anyone who knows the URL. `ALLOWED_ORIGINS` does not prevent this — CORS is
enforced by browsers, and `curl` ignores it. See `docs/BUGS.md` §17–21.
