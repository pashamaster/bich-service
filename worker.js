/**
 * bich.service — photo to event
 * A complete replacement for the n8n workflow, in one file.
 *
 * Deploy:
 *   npm i -g wrangler
 *   wrangler secret put GEMINI_API_KEY
 *   wrangler deploy
 *
 * Why a Worker: you already use Cloudflare R2 for covers (spec 6/10, roadmap
 * phase 0), so this adds no new vendor and no new credential surface. The
 * event cover upload will live next door in the same Worker later.
 */

/* The 10-field record. Lives in responseSchema ONLY — never repeat it in the
   prompt, that measurably lowers output quality. */
const EVENT_SCHEMA = {
  type: 'array',
  items: {
    type: 'object',
    propertyOrdering: ['event_name','longitude','latitude','date','time_start','time_finish','google_maps_link','city','description','space_name'],
    required: ['event_name'],
    properties: {
      event_name:       { type:'string', description:'The event or place title exactly as written in the photo.' },
      longitude:        { type:'number', nullable:true, description:'Decimal degrees. West is negative. Null if the photo and EXIF give no location.' },
      latitude:         { type:'number', nullable:true, description:'Decimal degrees. South is negative. Null if the photo and EXIF give no location.' },
      date:             { type:'string', format:'date', nullable:true, description:'Event date as YYYY-MM-DD. A bare month and day means the next upcoming occurrence: current year if it still lies ahead, otherwise next year. A weekday with no date means the next occurrence of that weekday from today. Null if the photo gives no date.' },
      time_start:       { type:'string', nullable:true, description:'Start time, 24 hour HH:MM. Null if not stated.' },
      time_finish:      { type:'string', nullable:true, description:'Finish time, 24 hour HH:MM. If a start time is given but no finish and the activity type is known, assume a 45 to 90 minute session; a yoga or fitness class is 60 minutes. For a venue opening hour such as Opens 5 pm, that is a door time, not a session: leave null.' },
      google_maps_link: { type:'string', nullable:true, description:'Built from the coordinates as https://www.google.com/maps/search/?api=1&query=LATITUDE,LONGITUDE with latitude first. Null if there are no coordinates.' },
      city:             { type:'string', nullable:true, description:'Nearest town or village from the coordinates, or the city read from text in the photo. Null if unknown.' },
      description:      { type:'string', nullable:true, description:'Two or three short phrases describing the event, inferred from the activity type. Fold in any host name, contact, or one line of useful context. Contains no dashes of any kind.' },
      space_name:       { type:'string', nullable:true, description:'The venue, studio, host or community name.' }
    }
  }
};

/* Carries only the judgement the schema can't express. */
const systemPrompt = (today) => `You are a data formatting analyst. You read a single uploaded photo and turn it into structured event records for a database. The photo can be an event flyer, a poster, a screenshot of a maps pin, a screenshot of a social post, or a photo of a printed sign.

Read the photo carefully. Identify: the event or place name, the host or space name, every date, every start and finish time, any address or coordinates, any contact details, and the type of activity.

Coordinates priority: printed coordinates or a clearly labelled pin in the image win. Supplied EXIF GPS is the fallback, and it is for location only.

EXIF capture time is NOT the event time. A photo taken on 3 June does not mean the event is on 3 June. Never use the capture timestamp to fill the date unless the photo itself confirms that date.

Create one record per distinct event. A flyer that lists four dates produces four records, repeating the shared fields on each.

Never invent coordinates, names or prices that are not supported by the photo or the supplied EXIF. Where the photo gives nothing and a guess would mislead, return null rather than guessing.

Today's date is ${today}. Use it to resolve relative dates and weekdays.`;

const cors = (origin) => ({
  'Access-Control-Allow-Origin': origin,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Bich-Invite',
  'Access-Control-Max-Age': '86400'
});

const json = (body, status, origin) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors(origin) }
  });

export default {
  async fetch(request, env) {
    // Lock CORS to your own origins. '*' only while developing.
    const allowed = (env.ALLOWED_ORIGINS || '*').split(',').map(s => s.trim());
    const reqOrigin = request.headers.get('Origin') || '';
    const origin = allowed.includes('*') ? '*' : (allowed.includes(reqOrigin) ? reqOrigin : allowed[0] || '');

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });
    if (request.method !== 'POST')    return json({ error: 'post a photo' }, 405, origin);

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '');

    /* ── Supabase writes ───────────────────────────────────────────
       The browser holds only the publishable key, which can read but
       never write. Every insert comes through here with the service
       role key, so validation and rate limits live in one place. */
    if (path.endsWith('/users'))  return createUser(request, env, origin);
    if (path.endsWith('/events')) return createEvent(request, env, origin);
    if (path.endsWith('/attend')) return setAttendance(request, env, origin);

    if (!path.endsWith('/extract-event')) return json({ error: 'nothing here' }, 404, origin);

    /* ── gate ──────────────────────────────────────────────────────────
       An invite code is an opaque string mapping to a quota bucket, not a
       person — the zero-PII model holds. Leave BICH_INVITE_CODES unset to
       run open (fine for a single local user).                          */
    const codes = (env.BICH_INVITE_CODES || '').split(',').map(s => s.trim()).filter(Boolean);
    if (codes.length) {
      const code = (request.headers.get('X-Bich-Invite') || '').trim();
      if (!codes.includes(code)) return json({ error: 'not on the list yet' }, 403, origin);
    }

    let body;
    try { body = await request.json(); }
    catch { return json({ error: 'bad request' }, 400, origin); }

    const { image, mime = 'image/jpeg', exif = null } = body || {};
    if (!image || typeof image !== 'string') return json({ error: 'no image' }, 400, origin);
    if (image.length > 8 * 1024 * 1024)      return json({ error: 'image too large' }, 413, origin);

    /* ── optional daily quota via KV (bind BICH_KV to enable) ───────── */
    if (env.BICH_KV) {
      const day = new Date().toISOString().slice(0, 10);
      const key = `count:${day}`;
      const used = parseInt((await env.BICH_KV.get(key)) || '0', 10);
      const cap = parseInt(env.DAILY_CAP || '180', 10);
      if (used >= cap) return json({ error: 'quiet for today. try tomorrow?' }, 429, origin);
      await env.BICH_KV.put(key, String(used + 1), { expirationTtl: 172800 });
    }

    /* ── Gemini ────────────────────────────────────────────────────── */
    const today = new Date().toISOString().slice(0, 10);
    const model = env.GEMINI_MODEL || 'gemini-2.5-flash';
    const exifLine = exif && (exif.lat != null || exif.dt)
      ? `\n\nEXIF supplied with this photo (location fallback only, never the event date): GPS ${exif.lat ?? 'none'}, ${exif.lng ?? 'none'} · captured ${exif.dt ?? 'unknown'}`
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
          generationConfig: {
            temperature: 0,
            responseMimeType: 'application/json',
            responseSchema: EVENT_SCHEMA
          }
        })
      });
    } catch {
      return json({ error: "couldn't reach the model" }, 502, origin);
    }

    const data = await res.json().catch(() => null);
    if (!res.ok || !data || data.error) {
      const code = data?.error?.code ?? res.status;
      if (code === 429) return json({ error: 'busy right now. try again in a moment?' }, 429, origin);
      return json({ error: "couldn't read that photo" }, 502, origin);
    }

    /* ── parse + backfill ──────────────────────────────────────────── */
    let rows;
    try {
      const text = (data.candidates?.[0]?.content?.parts || []).map(p => p.text).join('') || '[]';
      rows = JSON.parse(text);
      if (!Array.isArray(rows)) rows = [rows];
    } catch {
      return json({ error: "couldn't read that photo" }, 502, origin);
    }

    const clean = v => (v === null || v === undefined || v === '') ? '' : v;
    const hhmm  = v => { const s = clean(v); return s ? String(s).slice(0, 5) : ''; };

    rows = rows.map(r => {
      let lat = r.latitude, lng = r.longitude;
      // Safety net from photo_to_event_tool.md: a model that forgets the EXIF
      // fallback must never cost you the location.
      if ((lat == null || lng == null) && exif && exif.lat != null && exif.lng != null) {
        lat = exif.lat; lng = exif.lng;
      }
      const has = lat != null && lng != null && !Number.isNaN(+lat) && !Number.isNaN(+lng);
      return {
        event_name:       clean(r.event_name),
        longitude:        has ? +(+lng).toFixed(6) : '',
        latitude:         has ? +(+lat).toFixed(6) : '',
        date:             clean(r.date),
        time_start:       hhmm(r.time_start),
        time_finish:      hhmm(r.time_finish),
        // always rebuilt here, latitude first — never trust the model's string
        google_maps_link: has ? `https://www.google.com/maps/search/?api=1&query=${(+lat).toFixed(6)},${(+lng).toFixed(6)}` : '',
        city:             clean(r.city),
        description:      String(clean(r.description)).replace(/[\u2010-\u2015-]/g, ' ').replace(/\s+/g, ' ').trim(),
        space_name:       clean(r.space_name)
      };
    }).filter(r => r.event_name);

    return json(rows, 200, origin);
  }
};

/* ── Supabase helpers ──────────────────────────────────────────────
   SUPABASE_SERVICE_KEY bypasses row level security, so it must never
   leave the worker:  wrangler secret put SUPABASE_SERVICE_KEY          */
async function sb(env, path, init = {}){
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/' + path, {
    ...init,
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': 'Bearer ' + env.SUPABASE_SERVICE_KEY,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
      ...(init.headers || {})
    }
  });
  const body = await r.text();
  return { ok: r.ok, status: r.status, data: body ? JSON.parse(body) : null };
}

const cors2 = origin => ({
  'Access-Control-Allow-Origin': origin,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Bich-Invite'
});
const reply = (body, status, origin) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors2(origin) }
});

/* First visit: mint the user row for a generated handle. No email, no
   phone, no name - just a two word label and a uuid. */
async function createUser(request, env, origin){
  let b; try { b = await request.json(); } catch { return reply({ error:'bad request' }, 400, origin); }
  const handle = String(b.handle || '').trim().toLowerCase();
  if (!/^[a-z]{3,5} [a-z]{3,5}$/.test(handle)) return reply({ error:'bad handle' }, 400, origin);

  const res = await sb(env, 'users', { method:'POST', body: JSON.stringify({ handle }) });
  if (!res.ok){
    // handle collision: the client re-rolls and tries again
    if (res.status === 409) return reply({ error:'taken' }, 409, origin);
    return reply({ error:'could not save that' }, 502, origin);
  }
  return reply({ id: res.data[0].id, handle: res.data[0].handle }, 200, origin);
}

/* Publish. Validates, resolves the venue, then inserts. */
async function createEvent(request, env, origin){
  let b; try { b = await request.json(); } catch { return reply({ error:'bad request' }, 400, origin); }

  const title = String(b.title || '').trim();
  const starts = b.starts_at;
  if (!title) return reply({ error:'missing: title' }, 400, origin);
  if (!starts || Number.isNaN(Date.parse(starts))) return reply({ error:'missing: date' }, 400, origin);
  if (title.length > 200) return reply({ error:'title too long' }, 400, origin);

  // Reuse a venue if we already know it, otherwise add it to the book.
  let venue_id = b.venue_id || null;
  if (!venue_id && b.venue_name && b.venue_lat != null && b.venue_lng != null){
    const found = await sb(env, 'venues?select=id&name=eq.' + encodeURIComponent(b.venue_name) + '&limit=1');
    if (found.ok && found.data && found.data.length){
      venue_id = found.data[0].id;
    } else {
      const made = await sb(env, 'venues', { method:'POST', body: JSON.stringify({
        name: b.venue_name, lat: b.venue_lat, lng: b.venue_lng,
        city: b.city || null, community_slug: b.community_slug || null,
        source: b.venue_source === 'printed_coordinates' ? 'photo' : 'manual'
      })});
      if (made.ok && made.data && made.data.length) venue_id = made.data[0].id;
    }
  }

  const row = {
    host_id: b.host_id || null,
    title,
    description: b.description || null,
    venue_id,
    venue_name: b.venue_name || null,
    venue_lat: b.venue_lat ?? null,
    venue_lng: b.venue_lng ?? null,
    venue_source: b.venue_source || 'manual',
    city: b.city || null,
    community_slug: b.community_slug || null,
    photo_lat: b.photo_lat ?? null,     // origin only, never the pin
    photo_lng: b.photo_lng ?? null,
    starts_at: starts,
    ends_at: b.ends_at || null,
    recurrence: b.recurrence || null,
    price_value: Math.max(0, Math.round(Number(b.price_value) || 0)),
    price_currency: b.price_currency || 'EUR',
    capacity: b.capacity ?? null,
    cover_url: b.cover_url || null,
    contact: b.contact || null,
    source: b.source === 'photo' ? 'photo' : 'manual'
  };

  const res = await sb(env, 'events', { method:'POST', body: JSON.stringify(row) });
  if (!res.ok) return reply({ error:"couldn't publish that. try again?" }, 502, origin);
  return reply(res.data[0], 200, origin);
}

/* going / not going. 'attended' is set later by the post-event prompt,
   never here: spec 7.8 keeps the graph honest. */
async function setAttendance(request, env, origin){
  let b; try { b = await request.json(); } catch { return reply({ error:'bad request' }, 400, origin); }
  const { event_id, user_id } = b;
  if (!event_id || !user_id) return reply({ error:'bad request' }, 400, origin);
  const status = b.status === 'cancelled' ? 'cancelled' : 'going';

  const res = await sb(env, 'attendances', {
    method: 'POST',
    headers: { 'Prefer': 'resolution=merge-duplicates,return=representation' },
    body: JSON.stringify({ event_id, user_id, status })
  });
  if (!res.ok) return reply({ error:"couldn't save that" }, 502, origin);
  return reply({ ok:true, status }, 200, origin);
}
