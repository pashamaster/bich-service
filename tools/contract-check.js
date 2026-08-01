#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════
   CONTRACT CHECK

   Every serious bug in this project has been the same shape: the
   frontend and the database disagreeing about something, with the
   disagreement invisible until a real person hit it.

     update_event_as        client sent 5 args, function took 4
     venue_source           client sent a value the constraint rejected
     ""::integer            client sent '', the cast had no nullif
     my_hosted              deleted by a cascade, client still called it
     search_venues          lost its privileges, client still called it

   None of these needed a browser to find. All of them are two lists
   that should match and did not.

   Run:  node tools/contract-check.js
         node tools/contract-check.js --live      (queries the database)

   Static mode reads index.html and dbsql/*.sql — no credentials, no
   network, safe in CI. Live mode additionally asks the real database
   what it actually has, which is the only way to catch a migration
   that was never applied.
   ═══════════════════════════════════════════════════════════════════ */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const INDEX = path.join(ROOT, 'index.html');
const DBSQL = path.join(ROOT, 'dbsql');

let failures = 0, warnings = 0;
const fail = (m, d) => { failures++; console.log(`  FAIL  ${m}${d ? '\n        ' + d : ''}`); };
const warn = (m, d) => { warnings++; console.log(`  warn  ${m}${d ? '\n        ' + d : ''}`); };
const pass = (m) => console.log(`  ok    ${m}`);

/* ── parsing helpers ─────────────────────────────────────────────── */

/** split on top-level commas only — types like numeric(10,2) have their own */
function splitTop(s) {
  const out = []; let depth = 0, cur = '';
  for (const ch of s) {
    if ('([{'.includes(ch)) depth++;
    else if (')]}'.includes(ch)) depth--;
    if (ch === ',' && depth === 0) { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

/** read a balanced block starting at an opening bracket */
function balanced(src, start, open, close) {
  let depth = 0, i = start, buf = '';
  while (i < src.length) {
    if (src[i] === open) { depth++; if (depth === 1) { i++; continue; } }
    else if (src[i] === close) { depth--; if (depth === 0) break; }
    buf += src[i]; i++;
  }
  return buf;
}

/* ── what the database defines ───────────────────────────────────── */

function readSchema() {
  const fns = {};          // name -> Set(param names)   (later files win)
  const constraints = {};  // column -> allowed values
  const files = fs.readdirSync(DBSQL)
    .filter(f => f.endsWith('.sql'))
    .sort((a, b) => {
      const n = s => parseInt((s.match(/-(\d+)/) || [0, 0])[1], 10);
      return n(a) - n(b);
    });

  for (const f of files) {
    const src = fs.readFileSync(path.join(DBSQL, f), 'utf8');

    for (const m of src.matchAll(/create or replace function public\.(\w+)\s*\(/gi)) {
      const params = balanced(src, m.index + m[0].length - 1, '(', ')');
      const names = new Set();
      for (const p of splitTop(params)) {
        const nm = p.trim().match(/^([a-z_][\w]*)\s+/i);
        if (nm) names.add(nm[1]);
      }
      fns[m[1]] = { params: names, file: f };
    }

    // check (col in ('a','b',...))
    for (const m of src.matchAll(/check\s*\(\s*(\w+)\s+in\s*\(([^)]*)\)/gi)) {
      constraints[m[1]] = new Set([...m[2].matchAll(/'([^']*)'/g)].map(x => x[1]));
    }
  }
  return { fns, constraints };
}

/* ── what the client calls ───────────────────────────────────────── */

function readClient() {
  const src = fs.readFileSync(INDEX, 'utf8');
  const calls = [];        // { fn, args:Set, line }
  const restPaths = [];    // { path, line }
  const lineOf = i => src.slice(0, i).split('\n').length;

  for (const m of src.matchAll(/sbRpc\('([a-z_]+)'\s*,\s*\{/g)) {
    const body = balanced(src, m.index + m[0].length - 1, '{', '}');
    const args = new Set();
    for (const p of splitTop(body)) {
      const nm = p.trim().match(/^([a-z_][\w]*)\s*:/i);
      if (nm) args.add(nm[1]);
    }
    calls.push({ fn: m[1], args, line: lineOf(m.index) });
  }

  for (const m of src.matchAll(/sb(?:Get|Insert|Upsert)\(\s*[`'"]([a-z_]+)/g)) {
    restPaths.push({ table: m[1], line: lineOf(m.index) });
  }

  return { src, calls, restPaths };
}

/** Files whose every function definition is redefined by a later file.
    Those files still exist as history but no longer describe the
    deployed database, so defects in them are not live defects. */
function supersededFiles() {
  const order = fs.readdirSync(DBSQL).filter(f => f.endsWith('.sql'))
    .sort((a, b) => {
      const n = s => parseInt((s.match(/-(\d+)/) || [0, 0])[1], 10);
      return n(a) - n(b);
    });
  const lastDef = {};
  for (const f of order) {
    const src = fs.readFileSync(path.join(DBSQL, f), 'utf8');
    for (const m of src.matchAll(/create or replace function public\.(\w+)\s*\(/gi)) {
      lastDef[m[1]] = f;
    }
  }
  const out = new Set();
  for (const f of order) {
    const src = fs.readFileSync(path.join(DBSQL, f), 'utf8');
    const defined = [...src.matchAll(/create or replace function public\.(\w+)\s*\(/gi)].map(m => m[1]);
    if (defined.length && defined.every(n => lastDef[n] !== f)) out.add(f);
  }
  return out;
}

/* ── the checks ──────────────────────────────────────────────────── */

const { fns, constraints } = readSchema();
const { src, calls, restPaths } = readClient();

console.log('\ncontract check\n');

/* 1. every RPC the client calls must exist, with the arguments it
      sends. PostgREST resolves overloads BY ARGUMENT NAME, so a
      renamed parameter is a break even when the types are identical —
      this is the update_event_as failure, and it is invisible to any
      check that only compares function names. */
console.log('rpc signatures');
{
  const seen = new Set();
  for (const c of calls) {
    const key = c.fn + [...c.args].sort().join(',');
    if (seen.has(key)) continue;
    seen.add(key);

    const def = fns[c.fn];
    if (!def) { fail(`${c.fn} is called at line ${c.line} but no migration defines it`); continue; }
    const extra = [...c.args].filter(a => !def.params.has(a));
    if (extra.length) {
      fail(`${c.fn} (line ${c.line}) sends ${extra.join(', ')}`,
           `${def.file} declares (${[...def.params].join(', ')})`);
    }
  }
  if (!failures) pass(`${seen.size} distinct call shapes match their definitions`);
}

// 2. values the client sends for constrained columns
console.log('\ncheck constraints');
{
  const checks = [
    { col: 'venue_source', pat: /venueSource\s*=\s*'([a-z_]+)'/g },
    { col: 'status',       pat: /p_status:\s*\w+\s*\?\s*'([a-z_]+)'\s*:\s*'([a-z_]+)'/g },
    { col: 'community_via',pat: /adoptCommunity\([^,]+,[^,]+,\s*'([a-z_]+)'\)/g },
    { col: 'source',       pat: /source:\s*'([a-z_]+)'/g }
  ];
  let checked = 0;
  for (const { col, pat } of checks) {
    const allowed = constraints[col];
    if (!allowed) continue;
    for (const m of src.matchAll(pat)) {
      for (const v of m.slice(1).filter(Boolean)) {
        checked++;
        if (!allowed.has(v)) {
          fail(`${col} = '${v}' is sent by the client`,
               `constraint permits: ${[...allowed].join(', ')}`);
        }
      }
    }
  }
  if (checked) pass(`${checked} constrained values are all permitted`);
  else warn('no constrained values found to check — patterns may need updating');
}

// 3. casts that would blow up on an empty string
console.log('\nempty-string casts');
{
  let bad = 0;
  /* A migration whose functions were later replaced no longer runs
     against a current database, so an unguarded cast in it is history,
     not a live defect. Only the definition that WINS matters — the one
     in the highest-numbered file that defines that function. */
  const superseded = supersededFiles();
  for (const f of fs.readdirSync(DBSQL).filter(f => f.endsWith('.sql'))) {
    if (superseded.has(f)) continue;
    const s = fs.readFileSync(path.join(DBSQL, f), 'utf8');
    for (const m of s.matchAll(/\(p_(?:payload|patch|match)->>'(\w+)'\)::/g)) {
      bad++;
      fail(`${f}: (p_…->>'${m[1]}')::  has no nullif`,
           `an empty string from an untouched input fails this cast`);
    }
  }
  if (!bad) pass('all jsonb casts are wrapped in nullif');
}

// 4. functions returning a view type — the cascade trap
console.log('\ncascade risk');
{
  let bad = 0;
  const live = {};
  const gone = supersededFiles();
  for (const f of fs.readdirSync(DBSQL).filter(f => f.endsWith('.sql') && !gone.has(f))
                     .sort((a, b) => {
                       const n = s => parseInt((s.match(/-(\d+)/) || [0, 0])[1], 10);
                       return n(a) - n(b);
                     })) {
    const s = fs.readFileSync(path.join(DBSQL, f), 'utf8');
    /* Match each function's own header only. The previous pattern ran
       [\s\S]*? across function boundaries, so it happily paired
       bich_hash with a `returns public.events_public` belonging to a
       function defined 200 lines later — six false positives, all of
       them functions that return text or boolean. */
    for (const m of s.matchAll(/create or replace function public\.(\w+)\s*\(/gi)) {
      const after = s.slice(m.index + m[0].length - 1);
      const header = after.slice(0, after.search(/\bas\s*\$\$/i));
      const ret = header.match(/returns\s+(setof\s+)?public\.(\w+)/i);
      /* Files are walked in order, so the LAST definition wins — a
         function rebuilt to return jsonb in a later migration must
         clear the earlier events_public version, not be shadowed by
         it. Recording `null` is what makes that happen. */
      live[m[1]] = ret ? { returns: ret[2], file: f } : null;
    }
  }
  for (const [name, info] of Object.entries(live)) {
    if (info && info.returns === 'events_public') {
      bad++;
      fail(`${name} returns public.events_public (${info.file})`,
           'a "drop view … cascade" will delete this function');
    }
  }
  if (!bad) pass('no function depends on a view type');
}

// 5. direct table access from the browser
console.log('\ndirect table access');
{
  const allowed = new Set(['events_public']);
  const hits = restPaths.filter(r => !allowed.has(r.table));
  if (!hits.length) pass('reads go through events_public or an RPC');
  for (const h of hits) {
    // a probe that ASSERTS a table is unreachable is not a violation
    const line = src.split('\n')[h.line - 1] || '';
    /* A call whose PURPOSE is to prove a table is unreachable is not a
       violation — it is the test. bichCheck() deliberately attempts a
       direct write and expects it to fail. */
    const isProbe = /private|must fail|must now be closed|blocked|assert|revoke did not/i.test(
      src.split('\n').slice(Math.max(0, h.line - 10), h.line + 2).join(' '));
    (isProbe ? warn : fail)(
      `${h.table} accessed directly at line ${h.line}` + (isProbe ? ' (looks like a health probe)' : ''),
      line.trim().slice(0, 100));
  }
}

console.log(`\n${failures} failure${failures === 1 ? '' : 's'}, ${warnings} warning${warnings === 1 ? '' : 's'}\n`);

/* ── live mode ───────────────────────────────────────────────────── */

if (process.argv.includes('--live')) {
  const cfg = fs.readFileSync(path.join(ROOT, 'config.js'), 'utf8');
  const url = (cfg.match(/url:\s*'([^']+)'/) || [])[1];
  const key = (cfg.match(/anonKey:\s*'([^']+)'/) || [])[1];
  if (!url || !key) {
    console.log('live mode needs url and anonKey in config.js\n');
    process.exit(failures ? 1 : 0);
  }

  (async () => {
    console.log('live check — asking the deployed database\n');
    const rpc = (fn, args) => fetch(`${url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify(args || {})
    });

    /* Does every function the client calls actually EXIST in the
       deployed database with these argument names? PostgREST resolves
       by name, so a 404 PGRST202 means the signature does not match —
       which is exactly the update_event_as break. Null arguments make
       every call safely refuse rather than write anything. */
    const seen = new Set();
    for (const c of calls) {
      const key2 = c.fn + [...c.args].sort().join(',');
      if (seen.has(key2)) continue;
      seen.add(key2);
      const args = {};
      for (const a of c.args) args[a] = null;
      try {
        const r = await rpc(c.fn, args);
        const body = await r.json().catch(() => ({}));
        if (body && body.code === 'PGRST202') {
          fail(`${c.fn} does not exist in the deployed database with these arguments`,
               body.message);
        } else if (r.status === 404) {
          fail(`${c.fn} returned 404`, body.message || '');
        } else {
          pass(`${c.fn} resolves`);
        }
      } catch (err) {
        warn(`${c.fn} could not be reached: ${err.message}`);
      }
    }

    // tables the browser must not be able to touch
    console.log('\ntables that must be unreachable');
    for (const t of ['users', 'events', 'attendances', 'venues', 'communities', 'client_operations']) {
      const r = await fetch(`${url}/rest/v1/${t}?select=*&limit=1`, {
        headers: { apikey: key, Authorization: 'Bearer ' + key }
      });
      if (r.ok) fail(`${t} is READABLE with the anon key`);
      else pass(`${t} is closed (${r.status})`);
    }

    console.log(`\n${failures} failure${failures === 1 ? '' : 's'}, ${warnings} warning${warnings === 1 ? '' : 's'}\n`);
    process.exit(failures ? 1 : 0);
  })();
} else {
  process.exit(failures ? 1 : 0);
}
