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
    url:     'https://ibdqherxuolymstcqmsw.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImliZHFoZXJ4dW9seW1zdGNxbXN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ4MjE3OTEsImV4cCI6MjEwMDM5Nzc5MX0.iKR24FW26CsZdbJ6s4y-s9UPztYfujwIiitpX4btAvU'
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

  /* Bump on every release. Shown in the me screen so you can tell at
     a glance which build a phone is actually running. */
  version: '2026-07-26-28'
};

/* ──────────────────────────────────────────────────────────────────
   NOT SET HERE — and deliberately so.

   The worker cannot read this file. It runs on Cloudflare's edge, not
   in the browser, and it gets its settings at deploy time from
   wrangler.toml plus encrypted secrets. Having it fetch this file on
   every request would add a network hop and a failure mode for no
   benefit.

   It does not need to, either: the worker talks to Gemini and R2 and
   has no Supabase code in it at all. There is nothing to share.

   Worker settings live in wrangler.toml:
     ALLOWED_ORIGINS    https://bich.app,https://www.bich.app
     PUBLIC_IMG_BASE    https://img.bich.app
     GEMINI_MODEL       gemini-3.5-flash-lite
     BICH_INVITE_CODES  (comma separated, blank = open)
   and its secret with:
     wrangler secret put GEMINI_API_KEY
   ────────────────────────────────────────────────────────────────── */
