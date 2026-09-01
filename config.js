/* ══════════════════════════════════════════════════════════════════
   bich.service — public configuration
   The one place to change addresses and keys.

   EVERYTHING IN THIS FILE IS PUBLIC. It is downloaded by every
   visitor's browser, so treat it as a signpost, not a safe. That is
   fine, because nothing here is a secret:

     · the Supabase anon key is DESIGNED to be public. It is your
       street address, not your credit card. Row level security is
       the lock. Anyone can read live events and insert rows that
       pass the checks in schema part 4, and nothing else.
     · the worker URL is just a URL.

   NEVER put these here:
     · the Supabase service_role key  (bypasses every row policy)
     · the Gemini API key             (spends your money)
   Both live only in Cloudflare, set with `wrangler secret put`.
   ══════════════════════════════════════════════════════════════════ */

window.BICH_CONFIG = {

  /* Supabase → Project Settings → Data API
     url: no trailing slash. anonKey: the publishable one, starts eyJ */
  supabase: {
    url:     'https://omwurzkxapktduzppbim.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9td3Vyemt4YXBrdGR1enBwYmltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1NTUyMDMsImV4cCI6MjEwMTEzMTIwM30.w4VJNgbcNNDZqL9TAtfByduwwYBZfI4mpEmwANyLCxA'
  },

  /* The Cloudflare worker. Holds the Gemini key and writes to R2.
     Leave blank to run without photo reading or cover uploads. */
  worker: {
    url: 'https://api.bich.app'
  },

  /* Share links, per spec: bich.app/e/xxxx with a short opaque id, so
     a URL never hints at how many events exist. */
  share: {
    base: 'https://bich.app/'
  },

  /* Passkeys bind permanently to this domain. It must be the apex:
     a credential enrolled on a subdomain or a github.io address is
     orphaned the day you move. */
  passkey: {
    rpId: 'bich.app',
    rpName: 'bich.service'
  },

  /* Core vs magic. Core never calls a model: with this false the
     magic button does not render and no photo is ever sent anywhere
     but R2. This is the convenience switch, NOT the protection — the
     worker's own MAGIC_ENABLED is what actually refuses the request,
     because anything in this file is editable by anyone reading it. */
  magic: {
    /* Was false, which is why no magic button appeared. The button
       renders on this switch; the worker's own MAGIC_ENABLED is what
       actually permits the model call. BOTH must be on. */
    enabled: true
  },

  /* Alpha gate for the photo feature. An invite code is an opaque
     string mapping to a quota bucket, not a person, so the zero PII
     model holds. Blank means no gate on the client side; the worker
     decides for itself via BICH_INVITE_CODES. */
  invite: '',

  /* THE BASEMAP. On 2026-08-26 CARTO began requiring an API key for
     basemaps.cartocdn.com and started watermarking tiles that arrive
     without one — a policy change, not a limit anybody hit.

     provider:
       'esri'   keyless, and the default. Esri's Canvas basemaps, which
                have the same light/dark base-plus-labels split the
                theme system is built on. Nothing to sign up for.
       'carto'  the original look. Needs cartoApiKey below, free to
                5 million tiles a month from carto.com/basemaps/apikey.
       'osm'    emergency only. One style, so the map stops following
                the theme, and the OSMF asks apps not to lean on it.

     cartoApiKey is PUBLIC, like the Supabase anon key above — it ships
     in every tile URL a browser requests. Restrict it by domain in the
     CARTO dashboard; that is what protects it, not secrecy. */
  map: {
    provider: 'carto',

    /* Where the map goes when the provider above stops working. Two
       things move it automatically:

         · a sustained run of tile errors — 401, 403, 429, 5xx, or the
           CDN being unreachable
         · the CARTO watermark, which is NOT an error: it arrives as a
           valid 200 PNG with "API KEY REQUIRED" drawn on it. The app
           detects it by asking whether the key changes the answer —
           one tile fetched with the key and one without, once per
           session. Identical bytes mean the key is being ignored,
           which covers missing, wrong, expired and over-quota alike.

       The switch lasts the session, so the map cannot flap.

       WHAT THIS CANNOT DO: tell you that you are APPROACHING the
       limit. Only CARTO knows your monthly total, and the browser
       never sees it. This catches the moment the key stops working,
       not the week before. Watch the number in CARTO's dashboard if
       you want warning. */
    fallback: 'esri',

    /* LEAVE THIS EMPTY. The key comes from the worker instead:

         npx wrangler secret put CARTO_MAP_KEY

       and the app fetches it from GET /mapkey at startup. Until it
       arrives the map runs on `fallback`, so nobody ever sees the
       watermark, and the switch happens as soon as the key lands.

       WHY, AND WHAT IT DOES NOT BUY. The browser puts this key into
       every tile URL it requests from CARTO, so it is visible in the
       network tab a second after the map loads, and /mapkey can be
       curled by anyone. It is not a secret and cannot be made one.
       What the worker buys is real but narrow: the key is not in this
       repo or its git history, and rotating it is one wrangler command
       with no client deploy.

       WHAT ACTUALLY PROTECTS IT is the domain allowlist in the CARTO
       dashboard: allow bich.app and www.bich.app, and a copied key is
       useless in anybody else's page. Referer checks only bind
       browsers, so a determined script could still burn quota — and if
       that happens the map does not break, because the watermark probe
       moves everyone to `fallback` and you rotate the secret.

       Setting a key HERE still works and skips the fetch, which is
       useful for local work. It just puts it back in the repo.

       Note the parameter is `key=`, not `api_key=`. Free to 5 million
       tiles a month: carto.com/basemaps/apikey */
    cartoApiKey: ''
  },

  /* Bump on every release. Shown in the me screen so you can tell at
     a glance which build a phone is actually running. */
  version: '89'
};

/* ──────────────────────────────────────────────────────────────────
   NOT SET HERE — and deliberately so.

   The worker cannot read this file. It runs on Cloudflare's edge, not
   in the browser, and it gets its settings at deploy time from
   wrangler.toml plus encrypted secrets. Having it fetch this file on
   every request would add a network hop and a failure mode for no
   benefit.

   It does not need to, either. The worker does reach Supabase — for
   the magic cohort check and the two background sweeps — but it holds
   its OWN copy of the url and the same public anon key, set at deploy
   time. Nothing about that is shared with this file, and there is
   still no service_role key anywhere in the system.

   Worker settings live in wrangler.toml:
     ALLOWED_ORIGINS    https://bich.app,https://www.bich.app
     PUBLIC_IMG_BASE    https://img.bich.app
     GEMINI_MODEL       gemini-3.5-flash-lite
     BICH_INVITE_CODES  (comma separated, blank = open)
     SUPABASE_URL       same project as above
     SUPABASE_ANON_KEY  the same public key as above
   and its secrets with:
     wrangler secret put GEMINI_API_KEY
     wrangler secret put WORKER_SHARED_SECRET
   ────────────────────────────────────────────────────────────────── */
