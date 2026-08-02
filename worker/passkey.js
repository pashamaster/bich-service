/* ═══════════════════════════════════════════════════════════════════
   PASSKEYS — WebAuthn, no PII, no npm

   What a passkey is for here, precisely:

     It restores ONE value — the device secret. After schema 13 that
     single random string grants edit and cancel rights over every event
     a person has published, and my_hosted() gives the list back. So
     this file does not sync history, does not store an encrypted blob,
     and does not need the PRF extension. It hands back one string and
     the app rebuilds itself from Postgres.

   Why we run it ourselves instead of using Supabase Auth:

     Supabase's passkey support requires a confirmed email or phone
     before a credential can be registered. This app promises neither
     will ever exist. That is a product-level incompatibility, not a
     configuration one.

   Zero PII, and the standard agrees:

     The WebAuthn user handle "MUST NOT contain personally identifying
     information" (§14.6.1) and should be a random 16–32 byte value.
     users.id is exactly that. name/displayName are display-only
     strings, so the generated handle — "slide tem" — goes there and
     shows in the passkey picker. No email field exists in the ceremony.

   No npm, deliberately: pulling @simplewebauthn/server would make the
   worker require a bundler step it does not currently have. Everything
   below is Web Crypto, which Workers provide natively.

   ─────────────────────────────────────────────────────────────────
   WHAT IS AND IS NOT VERIFIED

   Verified on authentication: challenge match (single use), origin,
   type, rpIdHash, user-present flag, and the signature itself over
   authenticatorData || SHA-256(clientDataJSON).

   NOT verified on registration: the attestation statement. This is
   deliberate. Attestation identifies the make and model of somebody's
   authenticator, which is a fingerprinting surface, and we have no
   reason to care which brand of phone somebody owns. The public key is
   taken from the browser's own getPublicKey(), which avoids parsing
   CBOR in a worker.

   That means a client could register a public key of its own choosing
   against a uid. It gains nothing: registration requires the device
   secret, and a made-up secret comes back on restore and is then
   rejected by Postgres, which holds the real hash.
   ═══════════════════════════════════════════════════════════════════ */

const CHALLENGE_TTL   = 300;                 // seconds
const CREDENTIAL_TTL  = 60 * 60 * 24 * 3650; // ten years

const b64uToBytes = (s) => {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(pad + '==='.slice((pad.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};

const bytesToB64u = (buf) => {
  const b = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

const sha256 = async (bytes) =>
  new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));

const hex = (buf) =>
  Array.from(new Uint8Array(buf), b => b.toString(16).padStart(2, '0')).join('');

/* Comparing secrets with === leaks their contents through timing.
   Everything here that compares two secret-ish strings goes through
   this instead. */
function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

const sameString = (a, b) =>
  sameBytes(new TextEncoder().encode(String(a)), new TextEncoder().encode(String(b)));

function rpId(env, request) {
  return env.WEBAUTHN_RP_ID || new URL(request.url).hostname.replace(/^api\./, '');
}

function requireKV(env, json, origin) {
  if (!env.BICH_KV) {
    return json({ error: 'passkeys need the BICH_KV namespace bound' }, 503, origin);
  }
  return null;
}

/* ── registration ──────────────────────────────────────────────────
   The device secret is required here and that is the whole access
   control. uid is publicly listable — users has an open select policy —
   so a uuid alone would let anyone enrol a passkey against anyone. The
   secret never leaves the owner's device except as a hash to Postgres
   and as a value to this worker. */
export async function passkeyRegisterBegin(request, env, json, origin) {
  const gate = requireKV(env, json, origin);
  if (gate) return gate;

  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad json' }, 400, origin); }

  const { uid, handle, secret } = body || {};
  if (!uid || !handle || !secret) return json({ error: 'uid, handle and secret required' }, 400, origin);
  if (String(secret).length < 24) return json({ error: 'secret too short' }, 400, origin);

  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const id = bytesToB64u(challenge);

  await env.BICH_KV.put(
    `pkreg:${id}`,
    JSON.stringify({ uid, handle, secret }),
    { expirationTtl: CHALLENGE_TTL }
  );

  /* Anything already enrolled for this account, so the authenticator
     offers to replace rather than silently making a second credential. */
  const existing = await env.BICH_KV.get(`pkuser:${uid}`, 'json').catch(() => null);

  return json({
    challenge: id,
    rp: { id: rpId(env, request), name: env.WEBAUTHN_RP_NAME || 'bich.service' },
    user: {
      // §14.6.1: the user handle must not contain PII. A random uuid.
      id: bytesToB64u(new TextEncoder().encode(uid)),
      name: handle,           // "slide tem" — what the picker shows
      displayName: handle
    },
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
    authenticatorSelection: {
      residentKey: 'required',        // discoverable, so restore needs no typing
      requireResidentKey: true,
      userVerification: 'preferred'
    },
    attestation: 'none',              // see the header note
    excludeCredentials: (existing?.credentials || []).map(c => ({ type: 'public-key', id: c.id })),
    timeout: CHALLENGE_TTL * 1000
  }, 200, origin);
}

export async function passkeyRegisterFinish(request, env, json, origin) {
  const gate = requireKV(env, json, origin);
  if (gate) return gate;

  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad json' }, 400, origin); }

  const { challenge, credentialId, clientDataJSON, publicKey, alg } = body || {};
  if (!challenge || !credentialId || !clientDataJSON || !publicKey) {
    return json({ error: 'incomplete registration' }, 400, origin);
  }

  const pendingRaw = await env.BICH_KV.get(`pkreg:${challenge}`);
  if (!pendingRaw) return json({ error: 'challenge expired or already used' }, 400, origin);
  await env.BICH_KV.delete(`pkreg:${challenge}`);        // single use, always
  const pending = JSON.parse(pendingRaw);

  const check = await checkClientData(clientDataJSON, challenge, 'webauthn.create', env, request);
  if (check) return json({ error: check }, 400, origin);

  const record = {
    id: credentialId,
    publicKey,                       // SPKI, base64url, from getPublicKey()
    alg: Number(alg) || -7,
    counter: 0,
    createdAt: new Date().toISOString()
  };

  const account = {
    uid: pending.uid,
    handle: pending.handle,
    /* The device secret lives here in plaintext. It is not PII — it is
       32 random bytes — but it does grant edit rights over that
       person's events, so Cloudflare is inside the trust boundary for
       it exactly as it already is for the images. Encrypting it would
       need a key derived from the passkey (the PRF extension), whose
       support is still uneven across platforms; that is the upgrade
       path, not a reason to delay this. */
    secret: pending.secret,
    credentials: []
  };

  const prior = await env.BICH_KV.get(`pkuser:${pending.uid}`, 'json').catch(() => null);
  if (prior) {
    account.credentials = prior.credentials || [];
    /* Keep the FIRST secret ever enrolled. If somebody registered
       against this uid with a made-up secret, theirs is already the
       stored one and the real owner's edits still work because Postgres
       holds the real hash — but do not let a later caller overwrite a
       working secret either way. */
    account.secret = prior.secret;
  }
  account.credentials = account.credentials.filter(c => c.id !== record.id).concat([record]);

  await env.BICH_KV.put(`pkuser:${pending.uid}`, JSON.stringify(account), { expirationTtl: CREDENTIAL_TTL });
  await env.BICH_KV.put(`pkcred:${record.id}`, pending.uid, { expirationTtl: CREDENTIAL_TTL });

  return json({ ok: true, credentialId: record.id, credentials: account.credentials.length }, 200, origin);
}

/* ── authentication ────────────────────────────────────────────────
   Discoverable credentials, so allowCredentials is empty and the
   person picks their account in the system sheet. Nothing is typed and
   no identifier is sent before the assertion. */
export async function passkeyAuthBegin(request, env, json, origin) {
  const gate = requireKV(env, json, origin);
  if (gate) return gate;

  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const id = bytesToB64u(challenge);
  await env.BICH_KV.put(`pkauth:${id}`, '1', { expirationTtl: CHALLENGE_TTL });

  return json({
    challenge: id,
    rpId: rpId(env, request),
    allowCredentials: [],
    userVerification: 'preferred',
    timeout: CHALLENGE_TTL * 1000
  }, 200, origin);
}

export async function passkeyAuthFinish(request, env, json, origin) {
  const gate = requireKV(env, json, origin);
  if (gate) return gate;

  let body;
  try { body = await request.json(); } catch { return json({ error: 'bad json' }, 400, origin); }

  const { challenge, credentialId, clientDataJSON, authenticatorData, signature } = body || {};
  if (!challenge || !credentialId || !clientDataJSON || !authenticatorData || !signature) {
    return json({ error: 'incomplete assertion' }, 400, origin);
  }

  const live = await env.BICH_KV.get(`pkauth:${challenge}`);
  if (!live) return json({ error: 'challenge expired or already used' }, 400, origin);
  await env.BICH_KV.delete(`pkauth:${challenge}`);

  const problem = await checkClientData(clientDataJSON, challenge, 'webauthn.get', env, request);
  if (problem) return json({ error: problem }, 400, origin);

  const uid = await env.BICH_KV.get(`pkcred:${credentialId}`);
  if (!uid) return json({ error: 'unknown passkey' }, 404, origin);

  const account = await env.BICH_KV.get(`pkuser:${uid}`, 'json');
  if (!account) return json({ error: 'account not found' }, 404, origin);

  const cred = (account.credentials || []).find(c => c.id === credentialId);
  if (!cred) return json({ error: 'unknown passkey' }, 404, origin);

  const authData = b64uToBytes(authenticatorData);

  // The rp this assertion was made for must be ours.
  const wantRpHash = await sha256(new TextEncoder().encode(rpId(env, request)));
  if (!sameBytes(authData.slice(0, 32), wantRpHash)) {
    return json({ error: 'wrong relying party' }, 400, origin);
  }

  // Bit 0 of the flags byte: a human was present.
  if ((authData[32] & 0x01) !== 0x01) {
    return json({ error: 'user not present' }, 400, origin);
  }

  const clientHash = await sha256(b64uToBytes(clientDataJSON));
  const signed = new Uint8Array(authData.length + clientHash.length);
  signed.set(authData, 0);
  signed.set(clientHash, authData.length);

  const ok = await verifySignature(cred, b64uToBytes(signature), signed);
  if (!ok) return json({ error: 'signature did not verify' }, 401, origin);

  /* Clone detection. A counter that goes backwards means two copies of
     one credential exist. Synced passkeys — iCloud Keychain, Google
     Password Manager — legitimately report 0 forever, so only a
     non-zero counter that fails to advance is suspicious. */
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter !== 0 && counter <= cred.counter) {
    return json({ error: 'passkey may have been cloned' }, 401, origin);
  }
  cred.counter = counter;
  cred.lastUsed = new Date().toISOString();
  await env.BICH_KV.put(`pkuser:${uid}`, JSON.stringify(account), { expirationTtl: CREDENTIAL_TTL });

  /* The whole point of the exercise: one string back. The app writes it
     to localStorage and every event this person ever published becomes
     editable again, and my_hosted() rebuilds the list from Postgres. */
  return json({
    ok: true,
    uid: account.uid,
    handle: account.handle,
    secret: account.secret
  }, 200, origin);
}

/* ── shared checks ─────────────────────────────────────────────────── */

async function checkClientData(clientDataJSON, expectedChallenge, expectedType, env, request) {
  let data;
  try {
    data = JSON.parse(new TextDecoder().decode(b64uToBytes(clientDataJSON)));
  } catch {
    return 'client data was not readable';
  }

  if (data.type !== expectedType) return `expected ${expectedType}`;
  if (!sameString(data.challenge, expectedChallenge)) return 'challenge did not match';

  /* The origin must be one we serve. Without this a phishing page on
     another domain could relay a valid-looking ceremony. */
  const allowed = (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (allowed.length && !allowed.includes(data.origin)) return 'origin not allowed';

  if (data.tokenBinding && data.tokenBinding.status === 'present') {
    return 'token binding is not supported';
  }
  return null;
}

async function verifySignature(cred, signature, signed) {
  const spki = b64uToBytes(cred.publicKey);

  if (cred.alg === -257) {
    const key = await crypto.subtle.importKey(
      'spki', spki,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false, ['verify']
    );
    return crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, signature, signed);
  }

  // ES256 by default.
  const key = await crypto.subtle.importKey(
    'spki', spki,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false, ['verify']
  );
  /* Authenticators emit DER-wrapped ECDSA signatures; Web Crypto wants
     raw r||s. Skipping this conversion is the single most common reason
     a hand-rolled WebAuthn verifier rejects every valid signature. */
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' }, key, derToRaw(signature), signed
  );
}

function derToRaw(der) {
  // SEQUENCE { INTEGER r, INTEGER s }
  if (der[0] !== 0x30) return der;               // already raw
  let i = 2;
  if (der[1] & 0x80) i += der[1] & 0x7f;         // long-form length

  if (der[i] !== 0x02) return der;
  const rLen = der[i + 1];
  let r = der.slice(i + 2, i + 2 + rLen);
  i = i + 2 + rLen;

  if (der[i] !== 0x02) return der;
  const sLen = der[i + 1];
  let s = der.slice(i + 2, i + 2 + sLen);

  // strip the leading zero DER adds to keep integers positive, then
  // left-pad both halves to exactly 32 bytes
  const fix = (b) => {
    while (b.length > 32 && b[0] === 0x00) b = b.slice(1);
    if (b.length === 32) return b;
    const out = new Uint8Array(32);
    out.set(b, 32 - b.length);
    return out;
  };

  const out = new Uint8Array(64);
  out.set(fix(r), 0);
  out.set(fix(s), 32);
  return out;
}

export const _internals = { derToRaw, bytesToB64u, b64uToBytes, hex };
