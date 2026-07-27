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

/* Passkey routes are written but the module they need is not in this
   repo yet, and an import of a missing file fails the BUILD, not the
   request — wrangler deploy would refuse the whole worker and take the
   working upload route down with it. Restore these two blocks together
   with passkey.js, never separately. */
// import {
//   passkeyRegisterBegin, passkeyRegisterFinish,
//   passkeyAuthBegin, passkeyAuthFinish
// } from './passkey.js';

const EVENT_SCHEMA = {
  type: 'object',
  propertyOrdering: ['events', 'read_quality'],
  required: ['events', 'read_quality'],
  properties: {
    events: {
      type: 'array',
      items: {
        type: 'object',
        propertyOrdering: ['event_name','space_name','venue_match','category','venue_address','lineup','duration_source','venue_latitude','venue_longitude',
          'date_literal','weekday_literal','year_literal','time_start','time_finish',
          'recurrence','city','community','description','price','currency','contact','location_source'],
        required: ['event_name'],
        properties: {
          event_name:      { type:'string' },
          space_name:      { type:'string', nullable:true, description:'venue, studio, host or community name' },
          venue_match:     { type:'string', nullable:true, description:'If space_name matches one of the known venues supplied in the prompt, the exact string from that list. Null otherwise, and null when no list was supplied.' },
          lineup:          { type:'array', nullable:true, description:'Set times, programme or timetable INSIDE this one event. Empty or null when the flyer has no schedule. Never use this for separate events.',
                             items: { type:'object', properties:{
                               time: { type:'string', nullable:true, description:'HH:MM 24 hour when this slot starts. Null if only an order is given.' },
                               act:  { type:'string', description:'performer, act, talk or session name exactly as printed' },
                               stage:{ type:'string', nullable:true, description:'room or stage if the flyer names more than one' }
                             }, required:['act'] } },
          duration_source: { type:'string', nullable:true, description:'"stated" when the finish time is printed, "inferred" when you derived it from the activity type. Null when there is no finish time.' },
          category:        { type:'string', nullable:true, description:'exactly one of: music, wellness, food, market, sport, art, talk, film, social, workshop, nightlife, other. Yoga, breathwork and meditation are wellness. A dj night is nightlife. A gig is music. Null only if genuinely unclear.' },
          venue_address:   { type:'string', nullable:true, description:'street address as printed, without the venue name. Null if no address is printed.' },
          venue_latitude:  { type:'number', nullable:true, description:'ONLY from coordinates or a pin printed in the image' },
          venue_longitude: { type:'number', nullable:true, description:'ONLY from coordinates or a pin printed in the image' },
          date_literal:    { type:'string', nullable:true, description:'the date EXACTLY as printed. Do not convert.' },
          weekday_literal: { type:'string', nullable:true, description:'weekday as printed. Do not convert to a date.' },
          year_literal:    { type:'string', nullable:true, description:'year ONLY if printed' },
          time_start:      { type:'string', nullable:true, description:'24 hour HH:MM' },
          time_finish:     { type:'string', nullable:true, description:'24 hour HH:MM if printed' },
          recurrence:      { type:'string', nullable:true, description:'plain words if stated, e.g. every sunday' },
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
      propertyOrdering: ['is_event','legibility','unreadable','crop_would_help'],
      required: ['is_event','legibility'],
      properties: {
        is_event:        { type:'boolean' },
        legibility:      { type:'string', description:'clear, partial, or poor' },
        unreadable:      { type:'array', nullable:true, items:{ type:'string' } },
        crop_would_help: { type:'boolean', nullable:true }
      }
    }
  }
};

const systemPrompt = (today) => `You are a data formatting analyst. You read one uploaded photo and turn it into structured event records.

The photo is whatever was in someone's camera roll: a printed flyer photographed at an angle, a poster on a wall, a screenshot of a social post or a map pin, a chalkboard, a handwritten sign, or something that is not about an event at all. Judge before you extract.

Read everything visible, including text that is rotated, handwritten, or running around an edge. Expect perspective distortion, glare, shadow and clutter that is not part of the flyer.

Report dates and times EXACTLY as printed. Do not convert them, do not work out the year, do not work out which weekday comes next. Put the printed characters in date_literal and weekday_literal and leave the arithmetic to us. If no year is printed, leave year_literal null rather than guessing.

Venue coordinates come only from coordinates or a map pin printed in the image. If none are printed, leave them null. Any EXIF location supplied is where the PHOTO was taken, which is not where the event happens: a flyer in a cafe window advertises something elsewhere. Use EXIF only to name the city and the wider community. EXIF capture time is never the event time.

One record per distinct event date. A flyer listing four dates produces four records with shared fields repeated.

Never invent coordinates, names, prices or dates the photo does not support. A blank field prompts the user; a wrong field does not.

Judge legibility honestly. If text was cut off, too small, blurred or lost to glare, say so and name what you could not read. Do not pretend a hard photo was easy.

Today's date is ${today}.`;

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

    if (request.method !== 'POST') return json({ error: 'nothing here' }, 405, origin);

    /* Passkeys sit ABOVE the invite gate. That gate exists to ration
       Gemini calls; recovering your own history costs nothing, and
       locking somebody out of their own history because they have no
       invite code would be absurd. Commented out with the import at
       the top of this file — the two go back in together. */
    // if (path.endsWith('/passkey/register/begin'))  return passkeyRegisterBegin(request, env, json, origin);
    // if (path.endsWith('/passkey/register/finish')) return passkeyRegisterFinish(request, env, json, origin);
    // if (path.endsWith('/passkey/auth/begin'))      return passkeyAuthBegin(request, env, json, origin);
    // if (path.endsWith('/passkey/auth/finish'))     return passkeyAuthFinish(request, env, json, origin);

    /* Reverse geocoding sits above the invite gate: it costs nothing,
       it is needed by core, and it never touches Gemini. */
    if (path.endsWith('/geocode')) return reverseGeocode(request, env, origin);

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
