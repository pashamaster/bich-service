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

const EVENT_SCHEMA = {
  type: 'object',
  propertyOrdering: ['events', 'read_quality'],
  required: ['events', 'read_quality'],
  properties: {
    events: {
      type: 'array',
      items: {
        type: 'object',
        propertyOrdering: ['event_name','space_name','venue_latitude','venue_longitude',
          'date_literal','weekday_literal','year_literal','time_start','time_finish',
          'recurrence','city','community','description','price','currency','contact','location_source'],
        required: ['event_name'],
        properties: {
          event_name:      { type:'string' },
          space_name:      { type:'string', nullable:true, description:'venue, studio, host or community name' },
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
    if (request.method !== 'POST') return json({ error: 'nothing here' }, 405, origin);

    /* Invite gate. An invite code is an opaque string mapping to a
       quota bucket, not a person, so the zero PII model holds.
       Leave BICH_INVITE_CODES unset to run open. */
    const codes = (env.BICH_INVITE_CODES || '').split(',').map(s => s.trim()).filter(Boolean);
    if (codes.length) {
      const code = (request.headers.get('X-Bich-Invite') || '').trim();
      if (!codes.includes(code)) return json({ error: 'not on the list yet' }, 403, origin);
    }

    if (path.endsWith('/upload'))        return uploadImage(request, env, origin);
    if (path.endsWith('/extract-event')) return extractEvent(request, env, origin);
    return json({ error: 'nothing here' }, 404, origin);
  }
};

/* ── images: R2, zero egress cost at any volume ─────────────────── */
async function uploadImage(request, env, origin) {
  if (!env.COVERS) return json({ error: 'no bucket bound' }, 500, origin);

  const type = request.headers.get('Content-Type') || 'image/webp';
  if (!/^image\/(webp|jpeg|png)$/.test(type)) return json({ error: 'images only' }, 415, origin);

  const buf = await request.arrayBuffer();
  if (buf.byteLength > 3 * 1024 * 1024) return json({ error: 'image too large' }, 413, origin);

  const ext = type.split('/')[1].replace('jpeg', 'jpg');
  const key = `c/${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}.${ext}`;

  await env.COVERS.put(key, buf, {
    httpMetadata: {
      contentType: type,
      /* The key is unique per upload, so this can cache forever.
         Repeat views are served from the edge and never touch the
         bucket, which is what keeps R2 effectively free. */
      cacheControl: 'public, max-age=31536000, immutable'
    }
  });

  const base = env.PUBLIC_IMG_BASE || (new URL(request.url).origin + '/img');
  return json({ url: `${base}/${key}`, key }, 200, origin);
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
      'Access-Control-Allow-Origin': origin
    }
  });
}

/* ── gemini ─────────────────────────────────────────────────────── */
async function extractEvent(request, env, origin) {
  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad request' }, 400, origin); }

  const { image, mime = 'image/jpeg', exif = null } = body || {};
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

  let res;
  try {
    res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: systemPrompt(today) }] },
        contents: [{ role: 'user', parts: [
          { inline_data: { mime_type: mime, data: image } },
          { text: 'Extract every event in this photo as records.' + exifLine }
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
