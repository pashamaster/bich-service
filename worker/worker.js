/**
 * bich.service — Cloudflare Worker
 *
 * Holds exactly two things the browser must never see:
 *   1. the Gemini API key
 *   2. write access to the image bucket
 *
 * It deliberately holds NO Supabase credentials. Events go straight
 * from the browser to Supabase with the publishable key, and the
 * database's own row policies decide what is allowed. That keeps the
 * one genuinely dangerous credential, the service role key, out of
 * every system: not in the repo, not in the browser, not here.
 *
 * Setup:
 *   wrangler r2 bucket create bich-covers
 *   wrangler secret put GEMINI_API_KEY
 *   wrangler deploy
 *
 * Endpoints:
 *   POST /extract-event   image -> event records
 *   POST /upload          image -> stored in R2, returns a url
 *   GET  /img/<key>       serves a stored image
 */

import {
  passkeyRegisterBegin, passkeyRegisterFinish,
  passkeyAuthBegin, passkeyAuthFinish
} from './passkey.js';

const MAGIC_LOCKED = 'magic is invite only right now';

const EVENT_SCHEMA = {
  type: 'object',
  propertyOrdering: ['events', 'read_quality'],
  required: ['events', 'read_quality'],
  properties: {
    events: {
      type: 'array',
      items: {
        type: 'object',
        propertyOrdering: ['event_name','name_source','space_name','venue_match','venue_address','lineup','venue_latitude','venue_longitude',
          'date_literal','weekday_literal','year_literal','time_start','time_finish','duration_source',
          'recurrence','city','community','description','price','currency','contact','location_source'],
        required: ['event_name'],
        properties: {
          event_name:      { type:'string', description:'The title as printed. If the flyer carries no title, WRITE one from what is there: activity plus venue, e.g. "vinyasa at Casa Verde". Never empty, and never a placeholder like "untitled".' },
          name_source:     { type:'string', nullable:true, description:'"printed" when the title was on the flyer, "generated" when you wrote it.' },
          space_name:      { type:'string', nullable:true, description:'venue, studio, host or community name' },
          venue_match:     { type:'string', nullable:true, description:'If space_name matches one of the known venues supplied in the prompt, the exact string from that list. Null otherwise, and null when no list was supplied.' },
          lineup:          { type:'array', nullable:true, description:'Set times, programme or timetable INSIDE this one event. Empty or null when the flyer has no schedule. Never use this for separate events.',
                             items: { type:'object', properties:{
                               time: { type:'string', nullable:true, description:'HH:MM 24 hour when this slot starts. Null if only an order is given.' },
                               act:  { type:'string', description:'performer, act, talk or session name exactly as printed' },
                               stage:{ type:'string', nullable:true, description:'room or stage if the flyer names more than one' }
                             }, required:['act'] } },
          duration_source: { type:'string', nullable:true, description:'"stated" when the finish time was printed on the photo, "inferred" when you worked it out from the kind of event. Null when there is no finish time at all.' },
          venue_address:   { type:'string', nullable:true, description:'street address as printed, without the venue name. Null if no address is printed.' },
          venue_latitude:  { type:'number', nullable:true, description:'ONLY from coordinates or a pin printed in the image' },
          venue_longitude: { type:'number', nullable:true, description:'ONLY from coordinates or a pin printed in the image' },
          date_literal:    { type:'string', nullable:true, description:'the date EXACTLY as printed. Do not convert.' },
          weekday_literal: { type:'string', nullable:true, description:'weekday as printed. Do not convert to a date.' },
          year_literal:    { type:'string', nullable:true, description:'year ONLY if printed' },
          time_start:      { type:'string', nullable:true, description:'24 hour HH:MM' },
          time_finish:     { type:'string', nullable:true, description:'24 hour HH:MM if printed' },
          recurrence:      { type:'string', nullable:true, description:'ONLY when the photo claims the event repeats, e.g. "every sunday". Plain words such as "weekly on sunday". A timetable of different weekly classes is not such a claim: leave null there. The app creates four weeks from whatever is written here.' },
          city:            { type:'string', nullable:true },
          community:       { type:'string', nullable:true, description:'wider local area, coarse and stable' },
          description:     { type:'string', nullable:true, description:'two or three short phrases. No dashes of any kind.' },
          price:           { type:'number', nullable:true },
          currency:        { type:'string', nullable:true },
          contact:         { type:'string', nullable:true },
          location_source: { type:'string', nullable:true }
        }
      }
    },
    read_quality: {
      type: 'object',
      propertyOrdering: ['is_event','layout','legibility','unreadable','crop_would_help'],
      required: ['is_event','legibility'],
      properties: {
        is_event:        { type:'boolean', description:'True ONLY when the photo carries a time cue AND a location cue together. The system prompt states the bar.' },
        layout:          { type:'string', nullable:true, description:'single, multi_date or recurring_schedule. Null when is_event is false.' },
        legibility:      { type:'string', description:'clear, partial, or poor' },
        unreadable:      { type:'array', nullable:true, items:{ type:'string' } },
        crop_would_help: { type:'boolean', nullable:true }
      }
    }
  }
};

/* Kept deliberately tight: every character here is an input token on
   every extraction, and this used to be 7,259 of them — roughly 1,800
   tokens, three quarters of the cost of reading a photo.

   Two rules are NOT compressed, on purpose. The is_event bar and the
   "EXIF is not the venue" rule are the two places where terseness
   costs correctness, and both were written after real failures. Field
   level detail lives in the responseSchema descriptions instead, which
   Gemini reads at decode time, so repeating it here is paying twice
   for the same instruction. */
const systemPrompt = (today) => `You read one photo and return structured event data. Today is ${today}.

The photo is whatever was in someone's camera roll: a flyer shot at an angle, a poster, a WhatsApp or social screenshot, a chalkboard, a handwritten sign, a studio timetable, a place, a selfie, or nothing to do with an event. Read rotated, handwritten and edge-wrapped text. Expect distortion, glare and clutter.

IS THIS AN EVENT?
Set is_event true ONLY when the photo carries BOTH, together:
  · a TIME cue: a date, a weekday, or a clock time
  · a LOCATION cue: a venue name, a place name, or an address
Neither alone qualifies. A date with no hint of where is not enough; a bar's frontage with no time is not enough. A title is not required, and neither is a printed flyer: "yoga tomorrow 9am at Casa Verde" in a screenshot passes, because it has both.
If either cue is missing, set is_event false, return an empty events array and stop. Do not stretch to find an event. A photo that is not an event is an ordinary outcome the app handles well; inventing a vague one to seem useful is far worse than returning nothing.

LAYOUT
  single — one event, one occurrence.
  multi_date — one named event on several printed dates: one record PER DATE.
  recurring_schedule — a timetable of different sessions tied to weekdays: one record PER SESSION LISTED.
Emit each occurrence once. If something repeats weekly, say so in recurrence and still emit ONE record; the app creates the repeats.

DATES
Report as printed, into date_literal / weekday_literal / year_literal. No conversion, no year guessing, no calendar arithmetic; we resolve against today deterministically. Relative words ("tomorrow", "this saturday") go into date_literal verbatim. Only fill year_literal if a year is printed.
When the photo gives only a weekday, weekday_literal is the whole of the date and must be filled.

TIMES
24 hour HH:MM. "7pm" is 19:00, "half seven" is 19:30 — that is reading a clock, and you should do it.
If a finish time is printed, use it and set duration_source "stated". If not, work one out from the kind of thing this is, add it to time_start, and set duration_source "inferred":
  yoga, pilates, fitness, breathwork, meditation → 60 min
  class, workshop, talk, small group session → 90 min
  concert, gig, dj set, performance → 3 h
  party, festival, larger gathering → 4 h
  dinner, supper, long meal → 2 h 30
Fits none of these clearly? Leave time_finish and duration_source null rather than force a guess.
"Opens 19:00" and "doors 8pm" are DOOR times: time_start only, finish null. Doors say nothing about length.

LOCATION
venue_latitude and venue_longitude come ONLY from coordinates or a map pin printed inside the image. If none are printed, leave both null.
Any EXIF location supplied with the photo is where the PHOTO WAS TAKEN, which is not where the event happens: a flyer in a cafe window advertises something across town. Never copy it into venue_latitude or venue_longitude. Its only jobs are naming city and community when the photo does not state them, and sanity checking a place name you did read. If the photo contradicts the supplied location, trust the photo and say so in location_note.
community — the town, city or island. The single most useful location field.

Never invent coordinates, names, prices or dates. A blank field prompts the person; a wrong one is believed and published. event_name is the one exception: write a short plain title when none is printed.

LEGIBILITY
Judge honestly, and only when is_event is true. Name what you could not read. On a timetable, extract the rows you can read and list the ones you cannot rather than dropping the whole photo to "poor". Do not soften a genuinely unreadable photo to "partial".`;

const cors = (o) => ({
  'Access-Control-Allow-Origin': o,
  'Vary': 'Origin',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Bich-Invite',
  'Access-Control-Max-Age': '86400'
});
const json = (b, s, o) => new Response(JSON.stringify(b), {
  status: s, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors(o) }
});

export default {
  /* The safety net. The app pokes /venues/review after each publish,
     which handles the common case immediately — but a tab closed too
     early, an offline publish that syncs later, or a worker deploy
     mid-flight all leave venues unchecked. This sweeps them up.

     Every ten minutes, which is the agreed tolerance: a correction
     that lands within ten minutes of publishing is invisible to
     everybody. The queue is naturally tiny — only hand-typed venues,
     each checked once — so most runs find nothing and cost nothing. */
  async scheduled(event, env, ctx) {
    ctx.waitUntil((async () => {
      try {
        const req = new Request('https://internal/venues/review?limit=20', { method: 'POST' });
        const res = await reviewVenues(req, env, null);
        const body = await res.json().catch(() => null);
        console.log('[bich] scheduled venue review:', JSON.stringify(body));
      } catch (err) {
        console.error('[bich] scheduled venue review failed:', err.message);
      }

      /* Then the name-first pass, for events that never got a pin at
         all. Separate try block on purpose: these are two independent
         jobs and a failure in the first must not stop the second.

         limit 10 rather than 20 because both jobs share one scheduled
         invocation and each Nominatim call costs 1.1s — 20 + 10 is
         about 33 seconds of wall time, comfortably inside the limit
         while leaving room. */
      try {
        const req = new Request('https://internal/events/pin?limit=10', { method: 'POST' });
        const res = await pinEvents(req, env, null);
        const body = await res.json().catch(() => null);
        console.log('[bich] scheduled event pin:', JSON.stringify(body));
      } catch (err) {
        console.error('[bich] scheduled event pin failed:', err.message);
      }
    })());
  },

  async fetch(request, env) {
    const allowed = (env.ALLOWED_ORIGINS || '*').split(',').map(s => s.trim());
    const reqOrigin = request.headers.get('Origin') || '';
    const origin = allowed.includes('*') ? '*'
                 : (allowed.includes(reqOrigin) ? reqOrigin : allowed[0] || '');

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '');

    if (request.method === 'GET' && url.pathname.includes('/img/')) return serveImage(request, env, origin);

    /* Health has to sit above the POST-only check and above the invite
       gate: it is a GET you can hit from a browser bar, and its whole
       job is telling you when the gate is misconfigured. */
    if (request.method === 'GET' && path.endsWith('/health')) return health(request, env, origin);

    /* Reverse geocoding is a GET, and it has to be matched BEFORE the
       POST-only guard below or it never runs. It sat underneath, so
       every /geocode call returned 405 and no community was ever
       created — which is why the communities table stayed empty while
       the request showed up in the logs looking fine.

       It also sits above the invite gate deliberately: it costs
       nothing, core needs it, and it never touches Gemini. */
    if (path.endsWith('/geocode')) return reverseGeocode(request, env, origin);

    /* Venue search. Also a GET, also above the POST guard, also free
       and never near Gemini. */
    if (path.endsWith('/places')) return searchPlaces(request, env, origin);

    /* Venue canonicalisation. Poked by the app after a publish, and by
       the scheduled handler as a safety net. Touches no model, so it
       sits above the invite gate with the rest.

       POST only, and that is not cosmetic. This route sits ABOVE the
       method guard below, so before this check a bare
       `GET /venues/review?limit=20` from anybody at all started twenty
       Overpass queries spaced 1.1s apart — twenty seconds of wall time
       and twenty hits on a shared community quota, per request, from a
       URL you could paste into a browser bar. Both real callers already
       use POST. */
    if (path.endsWith('/venues/review')) {
      if (request.method !== 'POST') return json({ error: 'post only' }, 405, origin);
      return reviewVenues(request, env, origin);
    }

    if (request.method !== 'POST') return json({ error: 'nothing here' }, 405, origin);

    /* Passkeys sit ABOVE the invite gate. That gate exists to ration
       Gemini calls; recovering your own history costs nothing, and
       locking somebody out of their own history because they have no
       invite code would be absurd. */
    if (path.endsWith('/passkey/register/begin'))  return passkeyRegisterBegin(request, env, json, origin);
    if (path.endsWith('/passkey/register/finish')) return passkeyRegisterFinish(request, env, json, origin);
    if (path.endsWith('/passkey/auth/begin'))      return passkeyAuthBegin(request, env, json, origin);
    if (path.endsWith('/passkey/auth/finish'))     return passkeyAuthFinish(request, env, json, origin);

    /* Invite gate. An invite code is an opaque string mapping to a
       quota bucket, not a person, so the zero PII model holds.
       Leave BICH_INVITE_CODES unset to run open. */
    const codes = (env.BICH_INVITE_CODES || '').split(',').map(s => s.trim()).filter(Boolean);
    if (codes.length) {
      const code = (request.headers.get('X-Bich-Invite') || '').trim();
      if (!codes.includes(code)) return json({ error: 'not on the list yet' }, 403, origin);
    }

    if (path.endsWith('/upload'))        return uploadImage(request, env, origin);
    if (path.endsWith('/extract-event')) {
      /* The core/magic split is enforced HERE, not in the browser. A
         switch in the client is a suggestion; this is a wall. With
         MAGIC_ENABLED off, nothing reaches Gemini however the request
         is crafted, so a core deployment cannot spend money at all. */
      if (String(env.MAGIC_ENABLED || 'false') !== 'true') {
        return json({ error: 'magic is off on this deployment' }, 404, origin);
      }
      return extractEvent(request, env, origin);
    }
    return json({ error: 'nothing here' }, 404, origin);
  }
};

/* ── health ────────────────────────────────────────────────────────
   Answers "is this deployed correctly" without anyone reading logs or
   guessing. Reports whether each binding EXISTS; ?deep=1 additionally
   proves each one WORKS by writing a throwaway R2 object and asking
   Google to describe the model. Never returns a key, only whether one
   is present.                                                        */
async function health(request, env, origin) {
  const url = new URL(request.url);
  const deep = url.searchParams.get('deep') === '1';
  const allowed = (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
  const yours = request.headers.get('Origin') || null;

  const out = {
    worker: 'up',
    r2_bucket_bound: Boolean(env.COVERS),
    /* Where covers are served from. If this is a domain that was never
       attached to the bucket, uploads succeed and every image is dead —
       so it is worth being able to read it back rather than guess. When
       unset the worker serves them itself, which always works. */
    image_base: env.PUBLIC_IMG_BASE || (new URL(request.url).origin + '/img (served by this worker)'),
    magic_enabled: String(env.MAGIC_ENABLED || 'false') === 'true',
    gemini_key_present: Boolean(env.GEMINI_API_KEY),
    gemini_model: env.GEMINI_MODEL || 'gemini-3.5-flash-lite',
    kv_quota_bound: Boolean(env.BICH_KV),
    invite_gate_on: Boolean((env.BICH_INVITE_CODES || '').trim()),
    public_img_base: env.PUBLIC_IMG_BASE || '(falling back to /img on this worker)',
    allowed_origins: allowed,
    your_origin: yours,
    origin_allowed: !allowed.length || (yours ? allowed.includes(yours) : null)
  };

  if (deep && env.GEMINI_API_KEY) {
    /* Shape of the secret, never the secret. Every Google AI Studio key
       is "AIza" + 35 characters, so the prefix carries no information
       and the length tells you immediately whether a whole key landed.
       A 401 saying "expected OAuth 2 access token" almost always means
       Google saw no usable key at all - blank, whitespace, or a
       placeholder - rather than a key it rejected. */
    const k = env.GEMINI_API_KEY;
    const trimmed = k.trim();
    out.gemini_key_shape = {
      length: k.length,
      prefix: trimmed.slice(0, 4),
      looks_like_ai_studio_key: /^AIza[\w-]{35}$/.test(trimmed),
      has_surrounding_whitespace: k !== trimmed,
      has_quotes: /^['"]|['"]$/.test(trimmed)
    };

    /* Try both accepted forms. If the header fails and the query
       param works, the key is fine and the transport was the problem;
       if both fail the same way, the key itself is wrong. */
    const base = `https://generativelanguage.googleapis.com/v1beta/models/${out.gemini_model}`;
    const attempt = async (label, url, headers) => {
      try {
        const r = await fetch(url, { headers });
        const b = await r.json().catch(() => null);
        return { via: label, ok: r.ok, status: r.status,
                 name: b?.name, methods: b?.supportedGenerationMethods,
                 error: b?.error?.message, reason: b?.error?.status };
      } catch (e) { return { via: label, ok: false, error: 'network: ' + String(e).slice(0, 80) }; }
    };

    const viaHeader = await attempt('x-goog-api-key header', base, { 'x-goog-api-key': trimmed });
    const viaQuery  = viaHeader.ok ? null
      : await attempt('?key= query param', `${base}?key=${encodeURIComponent(trimmed)}`, {});
    const win = viaHeader.ok ? viaHeader : (viaQuery && viaQuery.ok ? viaQuery : viaHeader);

    out.gemini = {
      key_works: Boolean(win.ok),
      model_reachable: Boolean(win.ok),
      via: win.via,
      status: win.status,
      name: win.name,
      methods: win.methods,
      error: win.ok ? undefined : win.error,
      also_tried: viaQuery ? { via: viaQuery.via, status: viaQuery.status, error: viaQuery.error } : undefined
    };

    if (!win.ok) {
      /* whitespace and quotes first: those also fail the shape test,
         but the fix is different and more specific. */
      out.gemini.hint =
        out.gemini_key_shape.has_surrounding_whitespace || out.gemini_key_shape.has_quotes
          ? 'the stored key has stray whitespace or quotes around it, usually a trailing newline from a paste. ' +
            'Re-enter it with no quotes: wrangler secret put GEMINI_API_KEY --name bich-app' :
        !out.gemini_key_shape.looks_like_ai_studio_key
          ? 'the stored value is not shaped like a Google AI Studio key (AIza followed by 35 characters, 39 total). ' +
            'Most likely the secret is blank, a placeholder, or an OAuth client id rather than an API key. ' +
            'Get one at https://aistudio.google.com/apikey then: wrangler secret put GEMINI_API_KEY --name bich-app' :
        win.status === 404
          ? `the key is valid but cannot reach "${out.gemini_model}". List what it can reach: ` +
            `curl -s -H "x-goog-api-key: $KEY" "https://generativelanguage.googleapis.com/v1beta/models" | grep '"name"'` :
        win.status === 403
          ? 'key rejected: the Generative Language API may not be enabled on that project, or the key has referrer/IP restrictions that block a Worker.' :
        win.status === 401
          ? 'Google saw no usable credential. The secret exists but its contents are not a working API key.'
          : undefined;
    }
  } else if (deep) {
    out.gemini = { key_works: false, error: 'GEMINI_API_KEY secret is not set. Run: wrangler secret put GEMINI_API_KEY --name bich-app' };
  }

  if (deep && env.COVERS) {
    const key = `health/${Date.now()}.txt`;
    try {
      await env.COVERS.put(key, 'ok');
      out.r2 = { writable: Boolean(await env.COVERS.get(key)) };
      await env.COVERS.delete(key);
    } catch (e) { out.r2 = { writable: false, error: String(e).slice(0, 140) }; }
  }

  out.ok = out.r2_bucket_bound && out.gemini_key_present && out.origin_allowed !== false
           && (!deep || (out.gemini?.model_reachable !== false && out.r2?.writable !== false));
  return json(out, 200, origin);
}

/* Magic bytes. JPEG starts FF D8 FF, PNG 89 50 4E 47, WebP is RIFF
   then WEBP at offset 8. */
function sniff(buf, declared) {
  const b = new Uint8Array(buf.slice(0, 16));
  if (b.length < 12) return false;
  const isJpeg = b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF;
  const isPng  = b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
  const isWebp = b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
                 b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50;
  if (declared === 'image/jpeg') return isJpeg;
  if (declared === 'image/png')  return isPng;
  if (declared === 'image/webp') return isWebp;
  return false;
}

/* ── images: R2, zero egress cost at any volume ─────────────────── */
async function uploadImage(request, env, origin) {
  if (!env.COVERS) return json({ error: 'no bucket bound' }, 500, origin);

  /* Two derivatives arrive as one multipart form: a small one for feed
     cards and a large one for the detail hero. The browser has already
     cropped and resized both, which is why no server side image
     processing is needed here - and why this stays on the free tier. */
  let form;
  try { form = await request.formData(); }
  catch { return json({ error: 'send a form' }, 400, origin); }

  const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

  /* Validate everything BEFORE writing anything. The old loop wrote
     `full` to R2 and only then checked `thumb`, so a rejected thumb
     left an orphaned object in the bucket that no row referenced and
     nothing would ever clean up. */
  const staged = [];
  for (const variant of ['full', 'thumb']) {
    const file = form.get(variant);
    if (!file || typeof file === 'string') continue;

    const type = file.type || 'image/webp';
    if (!/^image\/(webp|jpeg|png)$/.test(type)) {
      return json({ error: `${variant}: only webp, jpeg or png` }, 415, origin);
    }

    /* size before arrayBuffer(). Reading first meant a deliberately
       huge POST could exhaust the isolate's 128 MB before the check
       it was supposed to fail. */
    const cap = variant === 'thumb' ? 400 * 1024 : 3 * 1024 * 1024;
    if (typeof file.size === 'number' && file.size > cap) {
      return json({ error: `${variant}: ${Math.round(file.size / 1024)}kb exceeds the ${Math.round(cap / 1024)}kb limit` }, 413, origin);
    }

    const buf = await file.arrayBuffer();
    if (buf.byteLength > cap) {
      return json({ error: `${variant}: too large` }, 413, origin);
    }

    /* file.type is whatever the client's multipart header claimed.
       Check the actual bytes, or this is anonymous file hosting for
       anything at all. */
    if (!sniff(buf, type)) {
      return json({ error: `${variant}: contents are not a ${type}` }, 415, origin);
    }

    const ext = type.split('/')[1].replace('jpeg', 'jpg');
    staged.push({ variant, buf, type, key: `c/${stamp}${variant === 'thumb' ? '-t' : ''}.${ext}` });
  }

  if (!staged.some(v => v.variant === 'full')) return json({ error: 'no image' }, 400, origin);

  const out = {};
  for (const v of staged) {
    await env.COVERS.put(v.key, v.buf, {
      httpMetadata: {
        contentType: v.type,
        /* The key is unique per upload, so this may cache forever.
           Repeat views come from the edge and never touch the bucket,
           which is what keeps R2 effectively free. */
        cacheControl: 'public, max-age=31536000, immutable'
      }
    });
    out[v.variant] = v.key;
  }

  // Fall back to serving through this worker when no image domain is
  // configured, so covers work before img.bich.app exists.
  const base = env.PUBLIC_IMG_BASE || (new URL(request.url).origin + '/img');
  return json({
    url:   `${base}/${out.full}`,
    thumb: out.thumb ? `${base}/${out.thumb}` : `${base}/${out.full}`,
    key:   out.full
  }, 200, origin);
}

async function serveImage(request, env, origin) {
  if (!env.COVERS) return new Response('no bucket', { status: 500 });
  const key = new URL(request.url).pathname.split('/img/')[1];
  if (!key) return new Response('not found', { status: 404 });

  const obj = await env.COVERS.get(key);
  if (!obj) return new Response('not found', { status: 404 });

  return new Response(obj.body, {
    headers: {
      'Content-Type': obj.httpMetadata?.contentType || 'image/webp',
      'Cache-Control': 'public, max-age=31536000, immutable',
      'Access-Control-Allow-Origin': origin,
      'Vary': 'Origin'
    }
  });
}

/* ── gemini ─────────────────────────────────────────────────────── */
async function extractEvent(request, env, origin) {
  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad request' }, 400, origin); }

  const { image, mime = 'image/jpeg', exif = null, known_venues = [] } = body || {};
  if (!image || typeof image !== 'string') return json({ error: 'no image' }, 400, origin);
  if (image.length > 8 * 1024 * 1024) return json({ error: 'image too large' }, 413, origin);

  /* ── the cohort gate ─────────────────────────────────────────────
     Magic is for the first N accounts. The check happens HERE, before
     a single token is spent, and not in the browser — whoever controls
     the browser controls the answer, so a client-side check would be
     theatre.

     It demands the device secret alongside the uid. uid alone proves
     nothing: public.users has an open select policy, so every user id
     is listable by anyone with the anon key, and somebody outside the
     cohort could simply borrow an early one. */
  const access = await checkMagicAccess(body, env);
  if (!access.allowed) return json({ error: access.reason, magic_locked: true }, 403, origin);

  /* The daily cap is the REAL spend protection and stays regardless.
     The cohort rule is a product decision that a cleared browser walks
     straight through; this is the one that bounds the bill. */
  if (env.BICH_KV) {
    const day = new Date().toISOString().slice(0, 10);
    const used = parseInt((await env.BICH_KV.get(`count:${day}`)) || '0', 10);
    const cap = parseInt(env.DAILY_CAP || '180', 10);
    if (used >= cap) return json({ error: 'quiet for today. try tomorrow?' }, 429, origin);
    await env.BICH_KV.put(`count:${day}`, String(used + 1), { expirationTtl: 172800 });
  }

  const today = new Date().toISOString().slice(0, 10);
  const model = env.GEMINI_MODEL || 'gemini-3.5-flash-lite';
  const exifLine = exif && (exif.lat != null || exif.dt)
    ? `\n\nEXIF supplied (location fallback only, never the event date): GPS ${exif.lat ?? 'none'}, ${exif.lng ?? 'none'} · captured ${exif.dt ?? 'unknown'}`
    : '\n\nNo EXIF was supplied with this photo.';

  /* Venue names we already hold for this area. Reading a venue off a
     flyer is the single least reliable field: the type is stylised,
     often partly obscured, and a near miss ("Casa Eyra") creates a
     duplicate that never merges. Giving the model the real strings
     turns an open transcription into a much easier multiple choice. */
  /* One event or several? This is the judgement the schema cannot
     express on its own, and getting it wrong in the splitting
     direction is the expensive one: three cards for the same night
     get shared and marked going and can never be quietly recombined. */
  const shapeRules = `

DECIDING HOW MANY EVENTS ARE IN THIS PHOTO.

Return ONE event with a filled "lineup" when ALL of these hold:
  · the same calendar date
  · the same venue
  · the listed times sit inside one continuous span
  · the rows read as performers, acts, stages or sessions, not as event titles
  · one door time or one price covers all of them
Headings like "line up", "set times", "programme", "timetable", "stages",
"schedule" mean ONE event. Put every row in "lineup", in printed order.

Return SEPARATE events when ANY of these hold:
  · the dates differ
  · the venues differ
  · a row carries its own price or its own ticket link
  · the gaps between rows are days rather than hours
Headings like "what's on", "this month", "upcoming", "programme for
September", or a calendar grid, mean SEVERAL events. One record per date.

If it is genuinely ambiguous, return ONE event with a lineup. Merging can be
undone later; splitting cannot.

DATE RANGES AND WEEKDAY COLUMNS. This is the case most often got wrong.

A timetable usually carries a date range in its header, like "29.12 - 04.01",
with columns labelled only MONDAY, TUESDAY and so on. Those columns are
SPECIFIC DATES inside that range. They are not a repeating weekly pattern.
Work out each weekday's actual date within the range and use it. Leave
recurrence null.

The range may cross a year boundary. "29.12 - 04.01" beginning in December
means the December dates are one year and the January dates are the NEXT.
Use the EXIF capture date, or today's date, to decide which year the range
starts in, then let the rollover follow.

CROSS CHECK THE WEEKDAYS, because they pin the year on their own. The first
day of the printed range must fall on the weekday of the first column. For
"29.12 - 04.01" over MONDAY to SUNDAY, 29 December has to be a Monday, and
that is true in 2025 but not in 2024 or 2026. If the year you chose does not
line up, you chose wrong: try the adjacent years until the weekdays match. If
none match, the range and the columns disagree - use the range, and say so in
location_note.

Set recurrence ONLY when the flyer itself says the schedule repeats: "every
week", "weekly", "every monday", "ongoing". A date range in the header is
the opposite of a recurrence - it is a statement that this schedule applies
to these dates and no others.

If a grid has neither a date range nor an explicit recurrence, treat each
weekday as the next upcoming occurrence of that weekday and say so in
read_quality.unreadable.

Never return more than 50 events. If the photo lists more, return the 50
soonest and say so in read_quality.unreadable.

DURATION. When a finish time is printed, use it and set duration_source
"stated". When none is printed, infer from the activity and set
duration_source "inferred":
  club night or party      5 to 6 hours
  gig or live set          2 to 3 hours
  dj set listed in lineup  finish at the last slot plus 90 minutes
  yoga or fitness class    60 minutes
  workshop                 2 to 3 hours
  market or fair           4 to 6 hours
  dinner or supper club    2 to 3 hours
  exhibition opening       2 to 3 hours
  talk or screening        90 minutes
  anything else            90 minutes
A door or opening hour such as "opens 5pm" is not a session length: leave the
finish empty. An event crossing midnight is normal and expected; give the
finish as a clock time and the app will resolve the date.`;

  const venueList = Array.isArray(known_venues)
    ? known_venues.filter(v => typeof v === 'string' && v.length < 120).slice(0, 40)
    : [];
  const venueLine = venueList.length
    ? `\n\nVenues already known near these coordinates:\n` +
      venueList.map(v => `  · ${v}`).join('\n') +
      `\n\nIf the space named on the flyer is one of these, copy that string EXACTLY into space_name ` +
      `and set venue_match to the same string. Match on meaning, not spelling: a flyer reading ` +
      `"ORGANIC WAY" matches "The Organic Way". If the flyer names a space that is NOT on this list, ` +
      `write what the flyer says and leave venue_match null. Never pick the nearest looking entry to ` +
      `something unrelated - a wrong match is worse than no match.`
    : '';

  let res;
  try {
    res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: systemPrompt(today) }] },
        contents: [{ role: 'user', parts: [
          { inline_data: { mime_type: mime, data: image } },
          { text: 'Extract every event in this photo as records.' + exifLine + venueLine + shapeRules }
        ]}],
        generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: EVENT_SCHEMA }
      })
    });
  } catch { return json({ error: "couldn't reach the model" }, 502, origin); }

  const data = await res.json().catch(() => null);
  if (!res.ok || !data || data.error) {
    const code = data?.error?.code ?? res.status;
    if (code === 429) return json({ error: 'busy right now. try again in a moment?' }, 429, origin);
    return json({ error: "couldn't read that photo" }, 502, origin);
  }

  try {
    const text = (data.candidates?.[0]?.content?.parts || []).map(p => p.text).join('') || '{}';
    const out = JSON.parse(text);
    return json({
      events: Array.isArray(out) ? out : (out.events || []),
      read_quality: out.read_quality || {}
    }, 200, origin);
  } catch {
    return json({ error: "couldn't read that photo" }, 502, origin);
  }
}


/* ═══════════════════════════════════════════════════════════════════
   REVERSE GEOCODING — coordinates to a community

   Why this runs on the worker instead of in the browser:

     · Nominatim's usage policy wants one request per second and a
       User-Agent that identifies the app. A browser cannot honour
       either on behalf of everyone, a worker can.
     · Caching. Coordinates round to ~1km before lookup, so a whole
       town collapses to a handful of cache keys and almost every call
       is served from KV without touching OSM at all.
     · The person's coordinates never leave for a third party from
       their own device — the request comes from the edge, not from
       them.

   No location permission is involved anywhere in this file. The
   coordinates arriving here came from an event's venue or a photo's
   own EXIF, both of which the app already had for other reasons.
   ═══════════════════════════════════════════════════════════════════ */

/* Which administrative level counts as "a community" is a per-region
   judgement, not a global rule. Default is the town or city. The
   overrides are for places where the island IS the community: Canggu
   and Ubud are different villages that behave like one place, and
   splitting them would leave both feeds empty.

   Keyed by ISO country code. Order matters — first key that has a
   value in the OSM address wins. */
const PLACE_LEVELS = {
  _default: ['city', 'town', 'village', 'municipality', 'suburb', 'county'],
  ID:       ['island', 'state', 'city', 'town', 'village'],        // Bali as one
  GR:       ['island', 'city', 'town', 'village'],                 // the islands
  PT:       ['island', 'city', 'town', 'village', 'municipality'], // Azores, Madeira
  ES:       ['island', 'city', 'town', 'village', 'municipality'], // Balearics, Canaries
  CV:       ['island', 'city', 'town', 'village'],
  MV:       ['island', 'atoll', 'city', 'town']
};

function pickPlace(addr, countryCode) {
  const order = PLACE_LEVELS[String(countryCode || '').toUpperCase()] || PLACE_LEVELS._default;
  for (const key of order) {
    const value = addr[key];
    if (value && String(value).trim()) return { name: String(value).trim(), kind: key };
  }
  // Nothing recognisable. Better to have no community than a wrong one.
  return null;
}

async function reverseGeocode(request, env, origin) {
  const url = new URL(request.url);
  const lat = Number(url.searchParams.get('lat'));
  const lng = Number(url.searchParams.get('lng'));

  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return json({ error: 'lat and lng required' }, 400, origin);
  }

  /* Round to three decimals, roughly 100m, before it becomes a cache
     key. Two people standing in the same square share a lookup, and
     the stored key is deliberately coarser than the coordinate that
     arrived. */
  const key = `geo:${lat.toFixed(3)},${lng.toFixed(3)}`;

  if (env.BICH_KV) {
    const hit = await env.BICH_KV.get(key, 'json').catch(() => null);
    if (hit) return json({ ...hit, cached: true }, 200, origin);
  }

  const q = new URL('https://nominatim.openstreetmap.org/reverse');
  q.searchParams.set('lat', String(lat));
  q.searchParams.set('lon', String(lng));
  q.searchParams.set('format', 'jsonv2');
  q.searchParams.set('zoom', '12');          // settlement level, not street
  q.searchParams.set('addressdetails', '1');

  let body;
  try {
    const r = await fetch(q.toString(), {
      headers: {
        // Nominatim's policy requires this to identify the caller.
        'User-Agent': 'bich.service/1.0 (https://bich.app)',
        'Accept': 'application/json'
      }
    });
    if (!r.ok) return json({ error: `geocoder said ${r.status}` }, 502, origin);
    body = await r.json();
  } catch (err) {
    return json({ error: 'geocoder unreachable' }, 502, origin);
  }

  const addr = (body && body.address) || {};
  const country = String(addr.country_code || '').toUpperCase() || null;
  const place = pickPlace(addr, country);

  if (!place || !body.osm_id) {
    /* Middle of the sea, or somewhere OSM has no settlement for. The
       event still publishes; it just has no community, which is the
       same blank state a brand new visitor has. */
    return json({ community: null, reason: 'no settlement at these coordinates' }, 200, origin);
  }

  const out = {
    osm_id:  `${body.osm_type || 'x'}/${body.osm_id}`,
    name:    place.name,
    kind:    place.kind,
    country,
    // The centre of the PLACE, not the coordinate we were handed, so a
    // community's circle is not centred on one person's back garden.
    lat: Number(body.lat) || lat,
    lng: Number(body.lon) || lng
  };

  if (env.BICH_KV) {
    // Places do not move. Thirty days is conservative.
    await env.BICH_KV.put(key, JSON.stringify(out), { expirationTtl: 60 * 60 * 24 * 30 })
      .catch(() => {});
  }

  return json(out, 200, origin);
}


/* ═══════════════════════════════════════════════════════════════════
   MAGIC ACCESS CHECK

   Asks Postgres whether this account has the magic flag, using the ANON
   key — the same public key the browser already holds, so nothing new
   is trusted to this worker and no service-role key exists anywhere in
   this system. Row level security still applies; the RPC is SECURITY
   DEFINER and verifies the device secret itself.

   Access is a boolean on the account, granted by hand or by redeeming
   a code. It replaced a "first 100 by signup order" rule that was
   arbitrary in both directions and, worse, failed in the wrong one:
   clearing browser storage made a NEW account with a HIGHER index, so
   the people most likely to lose access were the ones already using it.

   Cached in KV for ten minutes. Long enough to spare the database a
   round trip before every photo, short enough that granting somebody
   access in the table editor takes effect while they are still in the
   room with you.
   ═══════════════════════════════════════════════════════════════════ */
async function checkMagicAccess(body, env) {
  // Not configured to check: fall back to the daily cap alone rather
  // than locking everybody out of a feature that used to work.
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    console.warn('[bich] magic check skipped: no SUPABASE_URL / SUPABASE_ANON_KEY');
    return { allowed: true, reason: null };
  }

  const uid = body && body.uid;
  const secret = body && body.secret;
  if (!uid || !secret) {
    return { allowed: false, reason: 'magic needs an account on this device' };
  }

  const cacheKey = `magic:${uid}`;
  if (env.BICH_KV) {
    const hit = await env.BICH_KV.get(cacheKey).catch(() => null);
    if (hit === 'yes') return { allowed: true, reason: null };
    if (hit === 'no') return { allowed: false, reason: MAGIC_LOCKED };
  }

  let row;
  try {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/may_use_magic_as`, {
      method: 'POST',
      headers: {
        apikey: env.SUPABASE_ANON_KEY,
        Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ p_user: uid, p_secret: secret }),
      signal: AbortSignal.timeout(6000)
    });
    if (!r.ok) throw new Error('rpc said ' + r.status);
    const rows = await r.json();
    row = Array.isArray(rows) ? rows[0] : rows;
  } catch (err) {
    /* The database being briefly unreachable should not take a working
       feature down for people who are entitled to it. The daily cap
       still bounds the damage. */
    console.warn('[bich] magic check failed, allowing:', err.message);
    return { allowed: true, reason: null };
  }

  const allowed = Boolean(row && row.allowed);
  if (env.BICH_KV) {
    /* Ten minutes, not an hour. Long enough to spare the database a
       round trip before every photo, short enough that ticking the box
       in the table editor takes effect while that person is still
       standing in front of you. */
    await env.BICH_KV.put(cacheKey, allowed ? 'yes' : 'no', { expirationTtl: 600 }).catch(() => {});
  }

  return allowed
    ? { allowed: true, reason: null }
    : { allowed: false, reason: MAGIC_LOCKED };
}


/* ═══════════════════════════════════════════════════════════════════
   VENUE SEARCH

   The venue book only contains places somebody has already published
   to, so the first person in a new town types a name and gets nothing —
   the emptiest possible moment for a discovery app to be empty.

   This asks OpenStreetMap instead. Results are SUGGESTIONS: the app
   still writes its own venues row on publish, so the local book keeps
   growing and keeps winning, and a place somebody has used before
   always outranks a stranger from OSM.

   Same reasons as /geocode for living here rather than in the browser:
   Nominatim wants an identifying User-Agent and roughly one request a
   second, KV caching makes that achievable, and nobody's search text
   leaves their device for a third party.
   ═══════════════════════════════════════════════════════════════════ */
async function searchPlaces(request, env, origin) {
  const url = new URL(request.url);
  const q = (url.searchParams.get('q') || '').trim();
  const lat = Number(url.searchParams.get('lat'));
  const lng = Number(url.searchParams.get('lng'));

  if (q.length < 2) return json({ places: [] }, 200, origin);
  if (q.length > 120) return json({ error: 'query too long' }, 400, origin);

  const hasBias = Number.isFinite(lat) && Number.isFinite(lng);

  /* Cache key includes a coarse location, because "the mill" means a
     different building in Ericeira than in Lisbon. Rounded to ~11km so
     a whole town shares one cache entry. */
  const near = hasBias ? `${lat.toFixed(1)},${lng.toFixed(1)}` : 'any';
  const key = `places:${near}:${q.toLowerCase().replace(/\s+/g, ' ')}`;

  if (env.BICH_KV) {
    const hit = await env.BICH_KV.get(key, 'json').catch(() => null);
    if (hit) return json({ places: hit, cached: true }, 200, origin);
  }

  const search = new URL('https://nominatim.openstreetmap.org/search');
  search.searchParams.set('q', q);
  search.searchParams.set('format', 'jsonv2');
  search.searchParams.set('addressdetails', '1');
  search.searchParams.set('limit', '8');
  if (hasBias) {
    /* A box roughly 60km across, and NOT bounded — a venue just outside
       it should still be findable, it just ranks lower. */
    const d = 0.3;
    search.searchParams.set('viewbox', `${lng - d},${lat + d},${lng + d},${lat - d}`);
    search.searchParams.set('bounded', '0');
  }

  let rows;
  try {
    const r = await fetch(search.toString(), {
      headers: {
        'User-Agent': 'bich.service/1.0 (https://bich.app)',
        'Accept': 'application/json'
      },
      signal: AbortSignal.timeout(6000)
    });
    if (!r.ok) return json({ places: [], error: `geocoder said ${r.status}` }, 200, origin);
    rows = await r.json();
  } catch (err) {
    // A dead search box is better than a broken form. The person can
    // always type a name and drop a pin themselves.
    return json({ places: [], error: 'search unavailable' }, 200, origin);
  }

  const places = (Array.isArray(rows) ? rows : [])
    .filter(r => r.lat && r.lon && r.name)
    .map(r => {
      const a = r.address || {};
      /* Nominatim's display_name is the full postal chain and far too
         long for a list row. Two or three parts is what somebody needs
         to tell two places with the same name apart. */
      const where = [
        a.road || a.pedestrian || a.suburb || null,
        a.village || a.town || a.city || a.municipality || null
      ].filter(Boolean).join(', ');

      return {
        name: String(r.name).slice(0, 200),
        address: where || null,
        lat: Number(r.lat),
        lng: Number(r.lon),
        osm_id: `${r.osm_type || 'x'}/${r.osm_id}`,
        kind: r.type || r.category || null
      };
    })
    .slice(0, 6);

  if (env.BICH_KV) {
    // Buildings do not move. A day is conservative and keeps us well
    // inside Nominatim's usage policy.
    await env.BICH_KV.put(key, JSON.stringify(places), { expirationTtl: 86400 })
      .catch(() => {});
  }

  return json({ places }, 200, origin);
}


/* ═══════════════════════════════════════════════════════════════════
   VENUE CANONICALISATION

   People type "the mill". OpenStreetMap probably knows it as "Moinho
   do Cerrado". Afterwards — never during typing — we ask what is
   actually at those coordinates and record the answer beside what they
   typed.

   Overpass rather than Nominatim or OpenTripMap:
     · no key and no daily cap, unlike OpenTripMap's 5,000
     · raw OSM, so coverage is as good as OSM itself — which matters
       in Bali, where curated POI datasets are thin
     · one query returns every named place within a radius, and the
       matching happens here

   Overpass is often called slow and awkward for autocomplete. Both are
   true and neither applies: this runs after the fact, in batches, with
   nobody waiting.

   This Worker still holds no Supabase credential. It authenticates to
   two narrow RPCs with a shared secret, which can read venues awaiting
   review and write a match back, and nothing else.
   ═══════════════════════════════════════════════════════════════════ */

const OVERPASS_URL = 'https://overpass-api.de/api/interpreter';
const REVIEW_RADIUS_M = 300;   // the rule: correct only within 300m

/* Everything that separates "the Mill" from "the mill." before the
   strings are compared. */
function normaliseName(s) {
  return String(s || '')
    .toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')   // strip accents
    .replace(/[''`´]/g, '')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\b(the|a|o|a|el|la|le|de|do|da|di|du)\b/g, ' ')  // leading articles
    .trim()
    .replace(/\s+/g, ' ');
}

/* Token overlap rather than edit distance. "mill cafe" vs "cafe mill"
   is the same place with the words swapped, which Levenshtein scores
   as badly wrong. Word order carries almost no meaning in venue names.
   Falls back to a containment check for one-word names. */
function nameSimilarity(a, b) {
  const A = normaliseName(a), B = normaliseName(b);
  if (!A || !B) return 0;
  if (A === B) return 1;

  const ta = new Set(A.split(' ')), tb = new Set(B.split(' '));
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared++;
  const jaccard = shared / (ta.size + tb.size - shared);

  // "mill" inside "the old mill house" is a strong signal on its own
  if (ta.size === 1 || tb.size === 1) {
    const contained = A.includes(B) || B.includes(A);
    return Math.max(jaccard, contained ? 0.75 : 0);
  }
  return jaccard;
}

function metresBetween(aLat, aLng, bLat, bLng) {
  const dLat = (bLat - aLat) * 111000;
  const dLng = (bLng - aLng) * 111000 * Math.cos(aLat * Math.PI / 180);
  return Math.sqrt(dLat * dLat + dLng * dLng);
}

/* Name similarity carries most of the weight; proximity is a tiebreak
   that decays to nothing at 300m. A near-perfect name 250m away should
   still beat a poor name next door — venue coordinates are frequently
   a doorway, a car park, or wherever the phone happened to be.

   Nobody reviews the result, so this number is the whole decision.
   Postgres enforces the same thresholds again on the way in, because a
   Worker can be redeployed with looser ones and the database should
   not simply believe whatever it is told. */
function score(typedName, lat, lng, candidate) {
  const sim = nameSimilarity(typedName, candidate.name);
  const d = metresBetween(lat, lng, candidate.lat, candidate.lng);
  const near = Math.max(0, 1 - d / REVIEW_RADIUS_M);
  return {
    confidence: Math.round((sim * 0.8 + near * 0.2) * 100) / 100,
    distance: Math.round(d),
    sim
  };
}

async function overpassNear(lat, lng) {
  const q = `[out:json][timeout:25];
    (
      node(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["amenity"];
      node(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["leisure"];
      node(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["tourism"];
      node(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["shop"];
      way(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["amenity"];
      way(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["leisure"];
      way(around:${REVIEW_RADIUS_M},${lat},${lng})["name"]["tourism"];
    );
    out center 40;`;

  const r = await fetch(OVERPASS_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'bich.service/1.0 (https://bich.app)'
    },
    body: 'data=' + encodeURIComponent(q),
    signal: AbortSignal.timeout(30000)
  });
  if (!r.ok) throw new Error('overpass said ' + r.status);
  const body = await r.json();

  return (body.elements || [])
    .map(el => {
      const p = el.center || el;
      if (!p.lat || !p.lon || !el.tags || !el.tags.name) return null;
      return {
        name: String(el.tags.name).slice(0, 200),
        lat: p.lat, lng: p.lon,
        osm_id: `${el.type}/${el.id}`,
        kind: el.tags.amenity || el.tags.leisure || el.tags.tourism || el.tags.shop || null
      };
    })
    .filter(Boolean);
}

async function sbRpcFromWorker(env, fn, args) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: 'Bearer ' + env.SUPABASE_ANON_KEY,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(15000)
  });
  if (!r.ok) {
    const t = await r.text().catch(() => '');
    throw new Error(`${fn} ${r.status} ${t.slice(0, 200)}`);
  }
  return r.json();
}

/* Give a pin to events that only ever had a venue name.

   An event published without tapping the map has no coordinates, so it
   never enters the venue canonicalisation pipeline — that one searches
   AROUND a point and there is no point. It stays off the map forever
   and has no maps link either, because the link is derived from the
   coordinates.

   Here the anchor is the community instead: geocode the typed name
   biased to the town centre. Both tests — name similarity, and inside
   the town — are recomputed in apply_event_pin rather than trusted
   from here, the same way apply_venue_match recomputes its own
   distance. This function proposes; the database decides.

   dry=1 reports what it WOULD do and writes nothing, which is how to
   check a backfill before letting it near real rows. */
async function pinEvents(request, env, origin){
  const url = new URL(request.url);
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '10', 10) || 10, 50);
  const dry = url.searchParams.get('dry') === '1';

  let queue;
  try {
    queue = await supabaseRpc(env, 'events_needing_pin',
      { p_secret: env.WORKER_SECRET, p_limit: limit });
  } catch (err) {
    return json({ error: 'queue unavailable', detail: String(err && err.message) }, 502, origin);
  }
  if (!Array.isArray(queue) || !queue.length) return json({ checked: 0, pinned: 0 }, 200, origin);

  const results = [];
  let pinned = 0, lastVia = null;

  for (const row of queue) {
    /* Nominatim asks for one request a second. Waited only when the
       PREVIOUS row actually went to the network — a run answered
       entirely from the gazetteer now costs no wall time at all, where
       before every row paid 1.1s whether it needed to or not. */
    if (lastVia === 'nominatim') await new Promise(r => setTimeout(r, 1100));

    /* Ask our own gazetteer FIRST. It is free, instant, needs no
       network, and a venue several locals have independently agreed on
       is better evidence than a Nominatim guess. Nominatim is the
       fallback for places we have never seen. */
    let hit = null, via = 'gazetteer';
    try {
      const known = await supabaseRpc(env, 'resolve_venue_coords', {
        p_name: row.venue_name, p_community: row.community,
        p_bias_lat: row.centre_lat, p_bias_lng: row.centre_lng
      });
      const k = Array.isArray(known) && known[0];
      if (k && k.lat != null) hit = { name: k.matched_name, lat: k.lat, lng: k.lng };
    } catch (err) {
      // a gazetteer miss is not fatal; fall through to the network
      console.warn('[bich] gazetteer lookup failed:', err && err.message);
    }

    if (!hit) {
      via = 'nominatim';
      try {
        hit = await geocodeNamed(row.venue_name, row.centre_lat, row.centre_lng);
      } catch (err) {
        results.push({ short_id: row.short_id, result: 'lookup failed: ' + (err && err.message) });
        continue;    // deliberately unstamped: a network failure is not an answer
      }
    }

    lastVia = via;

    if (dry) {
      results.push({
        short_id: row.short_id, venue_name: row.venue_name, via,
        would_use: hit ? { name: hit.name, lat: hit.lat, lng: hit.lng } : null
      });
      continue;
    }

    try {
      const out = await supabaseRpc(env, 'apply_event_pin', {
        p_secret: env.WORKER_SECRET,
        p_short_id: row.short_id,
        p_match: hit ? { name: hit.name, lat: hit.lat, lng: hit.lng } : null
      });
      if (typeof out === 'string' && out.startsWith('pinned')) pinned++;
      results.push({ short_id: row.short_id, result: out, via });
    } catch (err) {
      results.push({ short_id: row.short_id, result: 'write failed: ' + (err && err.message) });
    }
  }

  return json({ checked: queue.length, pinned, dry, results }, 200, origin);
}

/* Nominatim, biased to a point. viewbox with bounded=1 RESTRICTS the
   search to a box around the town rather than merely preferring it —
   without bounded, a name it does not know locally returns the best
   match on the planet, and "Bar Central" exists in every country on
   earth. Postgres checks the community radius again anyway; this stops
   the obviously wrong answers costing a round trip. */
async function geocodeNamed(name, lat, lng){
  const d = 0.5;      // ~55km box; the real radius test is server side
  const u = new URL('https://nominatim.openstreetmap.org/search');
  u.searchParams.set('q', name);
  u.searchParams.set('format', 'jsonv2');
  u.searchParams.set('limit', '1');
  u.searchParams.set('bounded', '1');
  u.searchParams.set('viewbox', `${lng - d},${lat + d},${lng + d},${lat - d}`);

  const r = await fetch(u, {
    headers: { 'User-Agent': 'bich.service/1.0 (https://bich.app)', 'Accept-Language': 'en' }
  });
  if (!r.ok) throw new Error('nominatim ' + r.status);
  const rows = await r.json();
  const hit = Array.isArray(rows) && rows[0];
  if (!hit || hit.lat == null) return null;

  return {
    name: (hit.name && hit.name.trim()) || String(hit.display_name || '').split(',')[0].trim(),
    lat: Number(hit.lat),
    lng: Number(hit.lon)
  };
}

async function reviewVenues(request, env, origin) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.WORKER_SHARED_SECRET) {
    return json({ error: 'venue review is not configured' }, 503, origin);
  }

  const url = new URL(request.url);
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '5', 10) || 5, 20);

  let queue;
  try {
    queue = await sbRpcFromWorker(env, 'venues_needing_review', {
      p_secret: env.WORKER_SHARED_SECRET, p_limit: limit
    });
  } catch (err) {
    return json({ error: 'could not read the queue: ' + err.message }, 502, origin);
  }
  if (!Array.isArray(queue) || !queue.length) {
    return json({ checked: 0 }, 200, origin);
  }

  const out = [];
  for (const v of queue) {
    let candidates = [];
    try {
      candidates = await overpassNear(v.lat, v.lng);
    } catch (err) {
      /* Overpass being busy is not this venue's fault. Leave it
         unchecked so a later run picks it up, rather than recording a
         false "nothing found" that suppresses it for a month. */
      out.push({ id: v.id, skipped: err.message });
      break;                        // one failure: back off entirely
    }

    const best = candidates
      .map(c => ({ ...c, ...score(v.name, v.lat, v.lng, c) }))
      .sort((a, b) => b.confidence - a.confidence)[0];

    /* Act, or do nothing. There is no third option any more: nobody
       sees a suggestion, so a low-confidence guess would either be
       applied wrongly or sit in a table nobody opens. */
    const usable = best && best.sim >= 0.6 && best.distance <= REVIEW_RADIUS_M
      ? best : null;

    try {
      const status = await sbRpcFromWorker(env, 'apply_venue_match', {
        p_secret: env.WORKER_SHARED_SECRET,
        p_venue: v.id,
        p_match: usable ? {
          name: usable.name, lat: usable.lat, lng: usable.lng,
          osm_id: usable.osm_id, confidence: usable.confidence
        } : null
      });
      out.push({
        id: v.id, typed: v.name,
        corrected: usable && String(status).startsWith('matched') ? usable.name : null,
        distance: usable ? usable.distance : null,
        confidence: usable ? usable.confidence : null,
        status
      });
    } catch (err) {
      out.push({ id: v.id, error: err.message });
    }

    // Overpass asks for restraint; a second between calls is restraint.
    await new Promise(r => setTimeout(r, 1100));
  }

  return json({ checked: out.length, results: out }, 200, origin);
}
