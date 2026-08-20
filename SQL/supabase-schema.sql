-- ═══════════════════════════════════════════════════════════════════
-- bich.service — CONSOLIDATED SCHEMA
--
-- One file. Baseline (which already folds in patches 35-38) plus
-- patches 39 and 40. Replaces all seven files for every purpose:
-- fresh install, and re-running against the live database.
--
--   psql -f supabase-schema.sql
--   select * from public.bich_verify() where not ok;   -- expect empty
--
--
-- ── SAFE ON A DATABASE THAT ALREADY HAS ROWS ──────────────────────
--
-- This file is additive and idempotent. It is designed to be run on
-- the CURRENT database, with events, users and attendances in it, and
-- to leave every one of those rows exactly where it was.
--
--   · ONE transaction. begin at the top, commit at the bottom, and
--     PostgreSQL makes DDL transactional — so if any statement fails,
--     the whole thing rolls back and the database is untouched. There
--     is no half-applied state to clean up. A failure costs you an
--     error message and nothing else.
--
--   · every table is `create table if not exists`
--   · every column is `alter table … add column if not exists`
--   · every index is `create index if not exists`
--   · every constraint is `drop constraint if exists` then `add`,
--     with any data migration ordered BEFORE the tightening
--   · every trigger is `drop trigger if exists` then `create`
--   · every function is `create or replace`, except the handful whose
--     return type changed, which are dropped by exact signature first
--     because `create or replace` cannot change a return type
--   · seed rows end in `on conflict do nothing`
--
-- NO statement deletes a row of anybody's data. The only DELETE is
-- against handle_words, removing vocabulary that cannot satisfy the
-- handle rule; the only UPDATEs are the recorded migrations, each
-- described where it stands.
--
--
-- ── THE TWO THINGS THAT DO REMOVE SOMETHING ───────────────────────
--
-- Both are no-ops on a database that has already run this schema, but
-- read them before the first run:
--
--   1. `drop view if exists public.events_public cascade` in part 3.
--      Views hold no data, so no row is at risk. The cascade is the
--      part with history: two earlier migrations dropped this view and
--      silently took update_event and my_hosted with them, because
--      those functions were declared `returns public.events_public`.
--      NOTHING declares that any more — the pattern was removed
--      deliberately, bich_verify() asserts it is still gone, and the
--      cascade now reaches only the view itself. It is recreated
--      immediately below the drop, inside the same transaction.
--
--   2. `alter table public.venues drop column if exists canonical_name,
--      canonical_lat, canonical_lng, match_candidates` in part 1.
--      Superseded by the venue gazetteer in part 4f, which stores
--      positions as observations instead. On a database built from
--      this schema these columns do not exist and the statement does
--      nothing. On an older one it drops four columns nothing reads.
--
--
-- ── IF IT FAILS ───────────────────────────────────────────────────
--
-- The likeliest cause is a CHECK constraint meeting a row written
-- before that constraint existed. The transaction rolls back, nothing
-- changes, and the error names the constraint. Find the offending rows
-- with the constraint's own condition, decide what they should say,
-- then run this file again. Rolling back is the correct outcome, not a
-- fault: a half-migrated schema is far worse than an unmigrated one.
--
--
-- ── ORDER, AND WHY IT IS WHAT IT IS ───────────────────────────────
--
--   1  tables, columns, indexes, constraints
--   2  drop superseded function signatures
--   3  the public view
--   4  functions            4b corrections      (was patch 35)
--                           4c feed ranking     (was patch 36)
--                           4d finished events  (was patch 37)
--                           4e name-first pins  (was patch 38)
--                           4f venue gazetteer  (was patch 39)
--                           4g feed it          (was patch 40)
--   5  triggers
--   6  row level security
--   7  table privileges
--   8  function privileges  ← must be last of the permission parts
--   9  scheduled work
--  10  seed data
--
-- Part 8 revokes EXECUTE across the schema and then grants back a
-- whitelist, because PostgreSQL grants EXECUTE on every new function
-- to PUBLIC and anon inherits PUBLIC. Writing no GRANT is not denying
-- access. That sweep therefore has to run AFTER every function exists.
--
-- This is the one thing consolidation actually changes in behaviour,
-- and it is a fix: as separate files, patches 39 and 40 ran after part
-- 8 had already swept, so age_factor() and observation_weight() kept
-- PostgreSQL's default grant to PUBLIC and were callable with the anon
-- key. Here they are created before the sweep and are private, while
-- resolve_venue_coords — which the browser genuinely needs — is named
-- in the whitelist to survive it.
--
--
-- ── A READING WARNING ─────────────────────────────────────────────
--
-- Several objects are defined TWICE: once in part 4 as they originally
-- stood, then again in part 4b as corrected. adopt_community_at,
-- normalise_venue_source, ensure_community and the users_community_via
-- constraint all work this way, and the second definition is the live
-- one. That shape is deliberate — each correction is kept next to the
-- explanation of what was wrong, which is the record of why the schema
-- is the way it is — but it means GREP FINDS THE WRONG ONE FIRST.
-- Always take the LAST definition in the file.
--
-- ═══════════════════════════════════════════════════════════════════

begin;


set local statement_timeout = '120s';

create extension if not exists pgcrypto  with schema extensions;
create extension if not exists pg_trgm;
create extension if not exists pg_cron;



-- ═══════════════════════════════════════════════════════════════════
-- CONSOLIDATED 2026-08-04. Patches 35 to 38 are folded in here and
-- their separate files are no longer needed:
--
--   35  ensure_community could not insert; the 'view' signal removed;
--       publish_event writes venue_id; normalise_venue_source defaults;
--       community/venue counters; the admin grant
--   36  feed ranking — viewer_circle and feed_ranked
--   37  the recently finished window on feed_ranked
--   38  name-first pins for events that never had coordinates
--
-- Verified by building one database from baseline+35+36+37+38 and
-- another from this file, then diffing every function signature,
-- column, index, trigger, constraint, policy and grant: 441 facts,
-- identical but for two, both deliberate.
--
-- presence_statuses() and unaccent_lite() are NOT granted to anon here,
-- where the patch route left them granted. That is a correction rather
-- than a regression: the patches ran after section 8's blanket revoke,
-- so those two kept PostgreSQL's default EXECUTE-to-PUBLIC, which is
-- exactly the hazard section 8 exists to close. Both are only ever
-- called from inside SECURITY DEFINER functions, which execute as the
-- definer and need no grant — verified by running apply_event_pin and
-- feed_ranked against a database where both are revoked.
-- ═══════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════
-- 1. TABLES
-- ═══════════════════════════════════════════════════════════════════

-- ── communities ───────────────────────────────────────────────────
-- A label for a person, not a directory of approved places. Names come
-- from OpenStreetMap, so there is nothing to moderate and no pending
-- state — a community exists the moment somebody's coordinates land in
-- it.
create table if not exists public.communities (
  slug         text primary key,
  name         text not null,
  country      text,                        -- ISO 3166-1 alpha-2
  centre_lat   double precision,
  centre_lng   double precision,
  radius_km    integer not null default 25,
  kind         text,                        -- hamlet|village|town|city|island|state
  osm_id       text,                        -- the dedupe key; names drift, ids do not
  event_count  integer not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create unique index if not exists communities_osm_idx
  on public.communities (osm_id) where osm_id is not null;


-- ── users ─────────────────────────────────────────────────────────
-- No email, no phone, no password column. There never has been one and
-- adding one is a product decision, not a schema change.
create table if not exists public.users (
  id                   uuid primary key default gen_random_uuid(),
  handle               text not null unique,        -- "slide tem"
  display_name         text,
  device_secret_hash   text,                        -- sha256, never the secret
  public_key           text unique,                 -- legacy, unused
  community_slug       text,
  community_via        text,
  community_updated_at timestamptz,
  magic_enabled        boolean not null default true,
  magic_granted_at     timestamptz,
  magic_source         text,
  is_admin             boolean not null default false,
  signup_index         integer,
  created_at           timestamptz not null default now()
);

alter table public.users
  add column if not exists display_name         text,
  add column if not exists device_secret_hash   text,
  add column if not exists community_slug       text,
  add column if not exists community_via        text,
  add column if not exists community_updated_at timestamptz,
  add column if not exists magic_enabled        boolean not null default true,
  add column if not exists magic_granted_at     timestamptz,
  add column if not exists magic_source         text,
  add column if not exists is_admin             boolean not null default false,
  add column if not exists signup_index         integer;

/* ORDER MATTERS. The constraint below permits three signals; a database
   written before that was narrowed may still hold rows saying 'view'.
   Clear those FIRST or the ALTER fails against its own table.

   Only the provenance is cleared, never the community itself: the slug
   is very likely the right town, and dropping it would put somebody
   back on the fallback, which is a worse answer than a quietly
   unattributed one. The column already permits null. */
update public.users
   set community_via = null
 where community_via = 'view';

alter table public.users drop constraint if exists users_community_via_check;
alter table public.users add constraint users_community_via_check
  /* THREE signals, all of them things somebody DID: opened a shared
     link, published with coordinates, chose a photo carrying GPS.
     'view' was a fourth here for a long time and was never legitimate —
     browsing is not an action, you open far more events than you act
     on, and most are already near you. Part 4b clears it off existing
     rows and re-adds this constraint; declaring it correctly here means
     a fresh database never has the wrong version even briefly. */
  check (community_via is null or community_via in ('link','photo','publish'));

alter table public.users drop constraint if exists users_display_name_check;
alter table public.users add constraint users_display_name_check
  check (display_name is null or length(btrim(display_name)) between 2 and 24);

create unique index if not exists users_signup_index_idx
  on public.users (signup_index) where signup_index is not null;


-- ── handle vocabulary ─────────────────────────────────────────────
-- Lives here, not in index.html, so it grows with an INSERT. Words
-- must be 3–5 lowercase letters or they generate handles the insert
-- rule then refuses.
create table if not exists public.handle_words (
  word   text primary key,
  part   text not null check (part in ('a','b')),
  active boolean not null default true
);


-- ── venues ────────────────────────────────────────────────────────
create table if not exists public.venues (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  address        text,
  lat            double precision not null,
  lng            double precision not null,
  city           text,
  community_slug text references public.communities(slug),
  source         text not null default 'manual',
  source_id      text,
  use_count      integer not null default 0,
  verified       boolean not null default false,
  -- what somebody typed, kept when OSM correction overwrites it
  original_name  text,
  original_lat   double precision,
  original_lng   double precision,
  match_osm_id     text,
  match_confidence real,
  match_status     text not null default 'unchecked',
  match_checked_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.venues
  add column if not exists community_slug   text,
  add column if not exists original_name    text,
  add column if not exists original_lat     double precision,
  add column if not exists original_lng     double precision,
  add column if not exists match_osm_id     text,
  add column if not exists match_confidence real,
  add column if not exists match_status     text not null default 'unchecked',
  add column if not exists match_checked_at timestamptz,
  add column if not exists updated_at       timestamptz not null default now();

-- the review queue from schema 30 never shipped
alter table public.venues
  drop column if exists canonical_name,
  drop column if exists canonical_lat,
  drop column if exists canonical_lng,
  drop column if exists match_candidates;

alter table public.venues drop constraint if exists venues_match_status_check;
alter table public.venues add constraint venues_match_status_check
  check (match_status in ('unchecked','matched','none'));

create unique index if not exists venues_source_idx
  on public.venues (source, source_id) where source_id is not null;
create index if not exists venues_name_trgm on public.venues using gin (name gin_trgm_ops);
create index if not exists venues_match_status_idx
  on public.venues (match_status, match_checked_at nulls first);


-- ── events ────────────────────────────────────────────────────────
create table if not exists public.events (
  id              uuid primary key default gen_random_uuid(),
  short_id        text not null unique,
  host_id         uuid references public.users(id) on delete set null,
  venue_id        uuid references public.venues(id) on delete set null,
  title           text not null,
  description     text,
  venue_name      text,
  venue_address   text,
  venue_lat       double precision,
  venue_lng       double precision,
  venue_source    text not null default 'manual',
  city            text,
  community_slug  text references public.communities(slug),
  -- PRIVATE. Community inference only. Never in a public projection.
  photo_lat       double precision,
  photo_lng       double precision,
  starts_at       timestamptz not null,
  ends_at         timestamptz,
  recurrence      text,
  price_value     integer not null default 0,   -- minor units
  price_currency  text not null default 'EUR',
  capacity        integer,
  cover_url       text,
  contact         text,
  source          text not null default 'manual',
  category        text,                          -- removed from the UI, column kept
  pin_source      text,
  is_backfill     boolean not null default false,
  needs_review    boolean not null default false,
  status          text not null default 'live',
  edit_token_hash text,                          -- legacy pre-schema-13 ownership
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table public.events
  add column if not exists venue_id        uuid references public.venues(id) on delete set null,
  add column if not exists edit_token_hash text,
  add column if not exists category        text,
  add column if not exists pin_source      text,
  add column if not exists is_backfill     boolean not null default false,
  add column if not exists needs_review    boolean not null default false;

alter table public.events drop constraint if exists events_venue_source_check;
alter table public.events add constraint events_venue_source_check
  check (venue_source in
    ('manual','printed_coordinates','printed_address','venue_name_only','matched_venue'));

alter table public.events drop constraint if exists events_pin_source_check;
alter table public.events add constraint events_pin_source_check
  check (pin_source is null or pin_source in ('manual','exif','extracted','venue'));

alter table public.events drop constraint if exists events_status_check;
alter table public.events add constraint events_status_check
  check (status in ('live','hidden','deleted'));

alter table public.events drop constraint if exists events_pin_pair_check;
alter table public.events add constraint events_pin_pair_check
  check ((venue_lat is null) = (venue_lng is null));

alter table public.events drop constraint if exists events_ends_after_starts;
alter table public.events add constraint events_ends_after_starts
  check (ends_at is null or ends_at > starts_at);

create index if not exists events_starts_idx    on public.events (starts_at) where status = 'live';
create index if not exists events_community_idx on public.events (community_slug, starts_at);
create index if not exists events_host_idx      on public.events (host_id);
create index if not exists events_geo_idx       on public.events (venue_lat, venue_lng);


-- ── attendances ───────────────────────────────────────────────────
-- No browser-readable attendee relation anywhere. Counts only.
create table if not exists public.attendances (
  event_id     uuid not null references public.events(id) on delete cascade,
  user_id      uuid not null references public.users(id)  on delete cascade,
  status       text not null default 'going'
               check (status in ('going','attended','cancelled')),
  joined_at    timestamptz not null default now(),
  confirmed_at timestamptz,
  primary key (event_id, user_id)
);

create index if not exists attendances_user_idx  on public.attendances (user_id, status);
create index if not exists attendances_event_idx on public.attendances (event_id, status);


-- ── event_visits ──────────────────────────────────────────────────
-- Deduped per person. The same person opening an event four times is
-- one interested person; counting four would make the number a lie.
create table if not exists public.event_visits (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.users(id)  on delete cascade,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  seen_count integer not null default 1,
  primary key (event_id, user_id)
);

create index if not exists event_visits_event_idx on public.event_visits (event_id);


-- ── client_operations ─────────────────────────────────────────────
-- Idempotency. The database that owns the write owns the replay check.
create table if not exists public.client_operations (
  operation_id   uuid primary key,
  user_id        uuid not null references public.users(id) on delete cascade,
  operation_type text not null,
  result         jsonb not null,
  created_at     timestamptz not null default now()
);

create index if not exists client_operations_user_idx
  on public.client_operations (user_id, created_at desc);


-- ── magic_codes ───────────────────────────────────────────────────
create table if not exists public.magic_codes (
  code       text primary key,
  label      text,
  max_uses   integer,
  used_count integer not null default 0,
  expires_at timestamptz,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);


-- ── credentials ───────────────────────────────────────────────────
-- Shape agreed with the spec, but EMPTY: passkey material lives in
-- Cloudflare KV because the Worker holds no Supabase credential. See
-- D-2 in BACKLOG.md. Aligned now so revisiting that decision does not
-- also require a migration.
create table if not exists public.credentials (
  id           text primary key,
  user_id      uuid references public.users(id) on delete cascade,
  uid          uuid references public.users(id) on delete cascade,
  public_key   text,
  sign_count   bigint not null default 0,
  transports   text[],
  device_label text,
  backed_up    boolean not null default false,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);


-- ── service_config ────────────────────────────────────────────────
create table if not exists public.service_config (
  id                 boolean primary key default true check (id),
  worker_secret_hash text,
  updated_at         timestamptz not null default now()
);

insert into public.service_config (id) values (true) on conflict (id) do nothing;


-- ── reserved_slugs ────────────────────────────────────────────────
-- Short ids that must never be handed out, because /e/<id> would
-- collide with a real path. The column is `word` — gen_short_id()
-- queries it by that name, and schema 8 created it that way.
--
-- I transcribed it as `slug` when assembling this baseline, from
-- memory rather than from schema 8. Every publish then failed with
-- `column "word" does not exist`, raised from inside gen_short_id()
-- where no interface check could see it.
create table if not exists public.reserved_slugs (word text primary key);

/* For a database created by the earlier draft of this file, which
   named the column slug. */
do $reserved$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'reserved_slugs'
                and column_name = 'slug')
     and not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'reserved_slugs'
                        and column_name = 'word')
  then
    execute 'alter table public.reserved_slugs rename column slug to word';
  end if;
end
$reserved$;


-- ═══════════════════════════════════════════════════════════════════
-- 2. DROP SUPERSEDED FUNCTIONS
--
-- Signatures that changed across migrations. Without these drops an old
-- overload survives beside the new one and PostgREST — which resolves
-- by ARGUMENT NAME — can bind to either. That is the update_event_as
-- failure, and it took a week to find.
-- ═══════════════════════════════════════════════════════════════════

drop function if exists public.update_event_as(text, uuid, text, jsonb);
drop function if exists public.cancel_event_as(text, uuid, text);
drop function if exists public.set_my_community(uuid, text, text, text);
drop function if exists public.set_attendance(text, uuid, text, text);
drop function if exists public.my_going(uuid, uuid[]);
drop function if exists public.my_hosted(uuid, text);
drop function if exists public.my_events(text[]);
drop function if exists public.my_events_as(uuid, text);
drop function if exists public.events_in_bbox(double precision, double precision, double precision, double precision, timestamptz);
drop function if exists public.recent_auto_attended(uuid, interval);
drop function if exists public.get_my_account(uuid, text);
drop function if exists public.search_venues(text, double precision, double precision, text, integer);
drop function if exists public.may_use_magic(uuid, integer);
drop function if exists public.may_use_magic_as(uuid, text, integer);
drop function if exists public.cohort_status(integer);
drop function if exists public.unattend(uuid, uuid);
drop function if exists public.venue_suggestions(uuid, text);
drop function if exists public.resolve_venue_suggestion(uuid, text, uuid, boolean);
drop function if exists public.venue_display_name(public.venues);


-- ═══════════════════════════════════════════════════════════════════
-- 3. THE PUBLIC VIEW
--
-- The only table-shaped thing the browser may read. It excludes
-- photo_lat, photo_lng, host_id and edit_token_hash — which is why the
-- events TABLE itself is unreachable further down. The view hid them
-- all along; the table did not.
-- ═══════════════════════════════════════════════════════════════════

drop view if exists public.events_public cascade;

create view public.events_public as
  select
    e.id, e.short_id, e.title, e.description,
    e.venue_name, e.venue_address, e.venue_lat, e.venue_lng,
    e.city, e.community_slug,
    e.starts_at, e.ends_at, e.recurrence,
    e.price_value, e.price_currency, e.capacity,
    e.cover_url, e.contact, e.source, e.category,
    u.handle as host_handle,
    coalesce(a.going_count, 0) as going_count
  from public.events e
  left join public.users u on u.id = e.host_id
  left join (
    select event_id, count(*) as going_count
      from public.attendances
     where status in ('going','attended')
     group by event_id
  ) a on a.event_id = e.id
  where e.status = 'live';

drop view if exists public.community_reach cascade;
create view public.community_reach as
  select slug, name, country, kind, centre_lat, centre_lng, radius_km,
         event_count, true as may_widen, radius_km * 3 as max_radius_km
    from public.communities;


-- ═══════════════════════════════════════════════════════════════════
-- 4. FUNCTIONS
--
-- Ordered so each is defined before anything that calls it.
--
-- Two rules every one of these follows, both learned the hard way:
--
--   · SECURITY DEFINER + `set search_path = public, extensions`
--     whenever it hashes. pgcrypto lives in `extensions` on Supabase,
--     so `search_path = public` alone makes digest() unresolvable —
--     which silently disabled the entire ownership model for weeks.
--
--   · never `returns public.events_public`. A cascade drop of that view
--     deletes any function returning its type. jsonb has no such
--     dependency.
-- ═══════════════════════════════════════════════════════════════════

-- ── building blocks ───────────────────────────────────────────

create or replace function public.bich_hash(p_text text)
returns text
language sql immutable
security definer
set search_path = public, extensions
as $$
  select encode(digest(p_text, 'sha256'), 'hex');
$$;

create or replace function public.gen_short_id()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet  text := 'abcdefghijkmnopqrstuvwxyz23456789';  -- no l/1/0/o
  candidate text;
  len       int := 5;
  tries     int := 0;
begin
  loop
    candidate := '';
    for i in 1..len loop
      candidate := candidate ||
        substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;

    exit when
      not exists (select 1 from public.events         where short_id = candidate)
      and not exists (select 1 from public.reserved_slugs where word = candidate);

    tries := tries + 1;
    -- crowded at this length: take another character
    if tries % 4 = 0 and len < 7 then
      len := len + 1;
    end if;
    if tries > 40 then
      raise exception 'could not allocate a short id after % attempts', tries;
    end if;
  end loop;

  return candidate;
end $$;

create or replace function public.default_radius_for(kind text)
returns integer language sql immutable as $$
  select case lower(coalesce(kind, ''))
    when 'hamlet'       then 3
    when 'village'      then 6
    when 'suburb'       then 6
    when 'town'         then 15
    when 'city'         then 25
    when 'municipality' then 25
    when 'island'       then 60
    when 'state'        then 80
    when 'region'       then 80
    else 15
  end;
$$;

/* normalise_venue_source was defined here as it originally stood, then corrected in
   part 4b. Only the corrected definition remains, so grep finds
   the live one. Identical signature, so no orphan is left behind
   in a database that ran the older files. */

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create or replace function public.guard_event_defaults()
returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.updated_at := now();
  if new.short_id is null then
    new.short_id := public.gen_short_id();
  end if;
  return new;
end $$;

create or replace function public.guard_venue_counters()
returns trigger language plpgsql as $$
begin
  new.use_count := 0;
  new.verified  := false;
  return new;
end $$;

create or replace function public.bump_venue_use()
returns trigger language plpgsql as $$
begin
  if new.venue_id is not null then
    update public.venues set use_count = use_count + 1 where id = new.venue_id;
  end if;
  return new;
end $$;

create or replace function public.bump_community_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.community_slug is null then return new; end if;
  update public.communities c
     set event_count = (
       select count(*) from public.events e
       where e.community_slug = c.slug and e.status = 'live')
   where c.slug = new.community_slug;
  return new;
end $$;

create or replace function public.assign_signup_index()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.signup_index is null then
    select coalesce(max(signup_index), 0) + 1 into new.signup_index from public.users;
  end if;
  return new;
end $$;

-- ── identity ──────────────────────────────────────────────────

create or replace function public.pick_handle()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_try text;
  i     integer := 0;
begin
  while i < 12 loop
    select a.word || ' ' || b.word into v_try
    from (select word from public.handle_words where part = 'a' and active
           order by random() limit 1) a,
         (select word from public.handle_words where part = 'b' and active
           order by random() limit 1) b;

    if v_try is null then return null; end if;

    if not exists (select 1 from public.users where handle = v_try) then
      return v_try;
    end if;
    i := i + 1;
  end loop;

  -- Every random attempt collided, so the pool is crowded. Ask for a
  -- free one directly rather than guessing again.
  select a.word || ' ' || b.word into v_try
  from public.handle_words a, public.handle_words b
  where a.part = 'a' and b.part = 'b' and a.active and b.active
    and not exists (
      select 1 from public.users u where u.handle = a.word || ' ' || b.word)
  order by random()
  limit 1;

  return v_try;   -- null only when literally every combination is taken
end $$;

create or replace function public.create_account()
returns table (id uuid, handle text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text;
  v_id     uuid;
begin
  v_handle := public.pick_handle();
  if v_handle is null then
    raise exception 'no handles left — add words to public.handle_words'
      using errcode = '23505';
  end if;

  insert into public.users (handle) values (v_handle)
  returning users.id into v_id;

  return query select v_id, v_handle;
end $$;

create or replace function public.account_exists(p_user uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.users u where u.id = p_user);
$$;

create or replace function public.claim_device_secret(p_user uuid, p_secret text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare existing text;
begin
  if p_secret is null or length(p_secret) < 24 then
    raise exception 'secret too short' using errcode = '22023';
  end if;

  select device_secret_hash into existing from public.users where id = p_user;
  if not found then return false; end if;

  -- already claimed: succeed only if it is the same secret, so a second
  -- device cannot silently take over an account
  if existing is not null then
    return existing = public.bich_hash(p_secret);
  end if;

  update public.users set device_secret_hash = public.bich_hash(p_secret)
   where id = p_user;
  return true;
end $$;

create or replace function public.owns_event(p_event public.events, p_user uuid, p_secret text)
returns boolean
language plpgsql stable security definer set search_path = public, extensions
as $$
declare want text;
begin
  if p_user is null or p_secret is null then return false; end if;
  if p_event.host_id is distinct from p_user then return false; end if;
  select device_secret_hash into want from public.users where id = p_user;
  return want is not null and want = public.bich_hash(p_secret);
end $$;

create or replace function public.get_my_account(p_user uuid, p_secret text)
returns table (
  uid            uuid,
  handle         text,
  display_name   text,
  magic_enabled  boolean,
  is_admin       boolean,
  community_slug text,
  community_via  text
)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then return; end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    return;
  end if;

  return query
    select u.id, u.handle, u.display_name, u.magic_enabled, u.is_admin,
           u.community_slug, u.community_via
      from public.users u where u.id = p_user;
end $$;

create or replace function public.my_profile(p_user uuid, p_secret text)
returns table (handle text, display_name text, magic_enabled boolean)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then return; end if;
  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then return; end if;

  return query
    select u.handle, u.display_name, u.magic_enabled
    from public.users u where u.id = p_user;
end $$;

create or replace function public.set_display_name(
  p_user uuid, p_secret text, p_name text
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_clean text;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  v_clean := nullif(btrim(coalesce(p_name, '')), '');

  -- Clearing it is allowed and returns to handle-only.
  if v_clean is null then
    update public.users set display_name = null where id = p_user;
    return null;
  end if;

  if length(v_clean) < 2 or length(v_clean) > 24 then
    raise exception 'a name is 2 to 24 characters' using errcode = '22023';
  end if;

  /* No newlines or control characters. This string is rendered in other
     people's feeds, so it must not be able to carry layout with it. */
  if v_clean ~ '[\n\r\t]' then
    raise exception 'one line only' using errcode = '22023';
  end if;

  update public.users set display_name = v_clean where id = p_user;
  return v_clean;
end $$;

create or replace function public.is_admin(p_user uuid, p_secret text)
returns boolean
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text; v_admin boolean;
begin
  if p_user is null or p_secret is null then return false; end if;
  select device_secret_hash, is_admin into v_hash, v_admin
    from public.users where id = p_user;
  if not found or v_hash is null then return false; end if;
  if v_hash <> public.bich_hash(p_secret) then return false; end if;
  return coalesce(v_admin, false);
end $$;

-- ── idempotency ───────────────────────────────────────────────

create or replace function public.op_replay(p_operation_id uuid, p_user uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select o.result from public.client_operations o
   where o.operation_id = p_operation_id and o.user_id = p_user;
$$;

create or replace function public.op_record(
  p_operation_id uuid, p_user uuid, p_type text, p_result jsonb
)
returns void
language sql security definer set search_path = public
as $$
  insert into public.client_operations (operation_id, user_id, operation_type, result)
  values (p_operation_id, p_user, p_type, p_result)
  on conflict (operation_id) do nothing;
$$;

-- ── communities ───────────────────────────────────────────────

/* ensure_community was defined here as it originally stood, then corrected in
   part 4b. Only the corrected definition remains, so grep finds
   the live one. Identical signature, so no orphan is left behind
   in a database that ran the older files. */

create or replace function public.community_lookup(p_slug text default null)
returns table (
  slug        text,
  name        text,
  country     text,
  kind        text,
  centre_lat  double precision,
  centre_lng  double precision,
  radius_km   integer,
  event_count integer
)
language sql stable security definer set search_path = public
as $$
  select c.slug, c.name, c.country, c.kind,
         c.centre_lat, c.centre_lng, c.radius_km::integer, c.event_count
    from public.communities c
   where p_slug is null or c.slug = p_slug
   order by c.event_count desc
   limit 500;
$$;

create or replace function public.community_for_point(
  p_lat double precision, p_lng double precision
)
returns text
language sql stable security definer set search_path = public
as $$
  select c.slug
    from public.communities c
   where p_lat is not null and p_lng is not null
     and c.centre_lat is not null and c.centre_lng is not null
     and (
       111.0 * sqrt(
         pow(c.centre_lat - p_lat, 2) +
         pow((c.centre_lng - p_lng) * cos(radians(p_lat)), 2)
       )
     ) <= c.radius_km
   order by c.radius_km asc
   limit 1;
$$;

/* adopt_community_at was defined here as it originally stood, then corrected in
   part 4b. Only the corrected definition remains, so grep finds
   the live one. Identical signature, so no orphan is left behind
   in a database that ran the older files. */

create or replace function public.set_my_community(
  p_user uuid, p_secret text, p_slug text, p_via text,
  p_operation_id uuid default null
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_prior jsonb;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  if p_operation_id is not null then
    v_prior := public.op_replay(p_operation_id, p_user);
    if v_prior is not null then return v_prior->>'slug'; end if;
  end if;

  if p_slug is not null and not exists (
       select 1 from public.communities c where c.slug = p_slug) then
    raise exception 'no such community' using errcode = 'P0002';
  end if;
  if p_via is not null and p_via not in ('link','photo','publish') then
    raise exception 'unknown community signal' using errcode = '22023';
  end if;

  update public.users u
     set community_slug = p_slug,
         community_via = p_via,
         community_updated_at = now()
   where u.id = p_user;

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'community.set',
      jsonb_build_object('slug', p_slug, 'via', p_via));
  end if;
  return p_slug;
end $$;

-- ── venues ────────────────────────────────────────────────────

create or replace function public.search_venues(
  q            text,
  near_lat     double precision default null,
  near_lng     double precision default null,
  community    text default null,
  max_results  integer default 6
)
returns table (
  id        uuid,
  name      text,
  address   text,
  lat       double precision,
  lng       double precision,
  city      text,
  use_count integer,
  score     real
)
language plpgsql stable
security definer
set search_path = public
as $$
declare v_q text;
begin
  v_q := btrim(coalesce(q, ''));
  if length(v_q) < 2 then return; end if;

  return query
    select v.id, v.name, v.address, v.lat, v.lng, v.city,
           coalesce(v.use_count, 0)::integer,
           (
             (case when lower(v.name) like lower(v_q) || '%' then 2.0 else 1.0 end)
             + least(coalesce(v.use_count, 0), 10) * 0.1
             - (case when near_lat is null then 0
                     else least(
                       111.0 * sqrt(pow(v.lat - near_lat, 2)
                                  + pow((v.lng - near_lng) * cos(radians(near_lat)), 2)),
                       50.0) * 0.02 end)
           )::real
      from public.venues v
     where lower(v.name) like '%' || lower(v_q) || '%'
       /* Local by nature. Offering somebody in Ericeira a bar in
          Canggu is the noise that made this field feel like a search
          engine rather than a shortcut. */
       and (community is null or v.community_slug is null or v.community_slug = community)
     order by 8 desc
     limit greatest(1, least(coalesce(max_results, 6), 20));
end $$;

create or replace function public.ensure_venue(
  p_payload      jsonb,
  p_user         uuid,
  p_secret       text,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash   text;
  v_prior  jsonb;
  v_id     uuid;
  v_name   text;
  v_lat    double precision;
  v_lng    double precision;
  v_source text;
  v_osm    text;
  v_result jsonb;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  if p_operation_id is not null then
    v_prior := public.op_replay(p_operation_id, p_user);
    if v_prior is not null then return v_prior; end if;
  end if;

  v_name   := btrim(coalesce(p_payload->>'name', ''));
  v_lat    := (nullif(p_payload->>'lat', ''))::double precision;
  v_lng    := (nullif(p_payload->>'lng', ''))::double precision;
  v_source := lower(coalesce(nullif(p_payload->>'source', ''), 'manual'));
  v_osm    := nullif(p_payload->>'osm_id', '');

  if length(v_name) not between 1 and 200 then
    raise exception 'a venue needs a name' using errcode = '22023';
  end if;
  if v_lat is null or v_lng is null
     or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'those coordinates are not on earth' using errcode = '22023';
  end if;
  if v_source not in ('manual', 'photo', 'osm') then
    raise exception 'unknown venue source' using errcode = '22023';
  end if;
  /* A place from the map must carry its OSM id, because that is what
     makes unique(source, source_id) deduplicate — with a null id
     Postgres permits unlimited duplicates and the same bar collects a
     fresh row on every publish. */
  if v_source = 'osm' and (v_osm is null or length(v_osm) not between 3 and 64) then
    raise exception 'a venue from the map needs its osm id' using errcode = '22023';
  end if;

  -- already known?
  if v_osm is not null then
    select v.id into v_id from public.venues v
     where v.source = v_source and v.source_id = v_osm;
  end if;
  if v_id is null then
    select v.id into v_id from public.venues v
     where lower(v.name) = lower(v_name)
       and abs(v.lat - v_lat) < 0.003            -- ~300m
       and abs(v.lng - v_lng) < 0.003
     limit 1;
  end if;

  if v_id is null then
    insert into public.venues (name, address, lat, lng, city, source, source_id)
    values (v_name,
            nullif(btrim(coalesce(p_payload->>'address', '')), ''),
            v_lat, v_lng,
            nullif(p_payload->>'city', ''),
            v_source, v_osm)
    returning id into v_id;
  end if;

  v_result := jsonb_build_object('id', v_id, 'name', v_name);
  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'venue.ensure', v_result);
  end if;
  return v_result;
end $$;

create or replace function public.is_worker(p_secret text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select exists (
    select 1 from public.service_config c
     where c.worker_secret_hash is not null
       and c.worker_secret_hash = public.bich_hash(p_secret));
$$;

create or replace function public.set_worker_secret(p_secret text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if p_secret is null or length(p_secret) < 32 then
    raise exception 'the worker secret must be at least 32 characters'
      using errcode = '22023';
  end if;
  update public.service_config
     set worker_secret_hash = public.bich_hash(p_secret), updated_at = now()
   where id = true;
  return true;
end $$;

create or replace function public.venues_needing_review(
  p_secret text, p_limit integer default 10
)
returns table (
  id        uuid,
  name      text,
  lat       double precision,
  lng       double precision,
  city      text,
  use_count integer
)
language plpgsql stable security definer set search_path = public, extensions
as $$
begin
  if not public.is_worker(p_secret) then
    raise exception 'not the worker' using errcode = '42501';
  end if;

  return query
    select v.id, v.name, v.lat, v.lng, v.city, v.use_count
      from public.venues v
     where v.source <> 'osm'
       and v.lat is not null and v.lng is not null
       and v.match_status = 'unchecked'
       /* A venue OSM had nothing for will not have gained an entry by
          next week. Checked once, then left alone for a month. */
       and (v.match_checked_at is null or v.match_checked_at < now() - interval '30 days')
     order by v.created_at desc
     limit greatest(1, least(coalesce(p_limit, 10), 50));
end $$;

create or replace function public.apply_venue_match(
  p_secret text, p_venue uuid, p_match jsonb
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_venue public.venues;
  v_conf  real;
  v_name  text;
  v_lat   double precision;
  v_lng   double precision;
  v_dist  double precision;
  v_moved integer;
begin
  if not public.is_worker(p_secret) then
    raise exception 'not the worker' using errcode = '42501';
  end if;

  select * into v_venue from public.venues where id = p_venue;
  if not found then return 'gone'; end if;

  -- No candidate worth acting on. Record that we looked; change nothing.
  if p_match is null or p_match->>'name' is null then
    update public.venues
       set match_status = 'none', match_checked_at = now()
     where id = p_venue;
    return 'none';
  end if;

  v_conf := coalesce((nullif(p_match->>'confidence', ''))::real, 0);
  v_name := btrim(p_match->>'name');
  v_lat  := (nullif(p_match->>'lat', ''))::double precision;
  v_lng  := (nullif(p_match->>'lng', ''))::double precision;

  if length(v_name) not between 1 and 200
     or v_lat is null or v_lng is null
     or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'that is not a usable match' using errcode = '22023';
  end if;

  /* The 300m rule, enforced here rather than trusted from the caller.
     Flat approximation — accurate to well under a metre at this scale
     and no PostGIS required. */
  v_dist := 111000 * sqrt(
    pow(v_lat - v_venue.lat, 2) +
    pow((v_lng - v_venue.lng) * cos(radians(v_venue.lat)), 2));

  if v_dist > 300 or v_conf < 0.6 then
    update public.venues
       set match_status = 'none', match_checked_at = now()
     where id = p_venue;
    return 'none';
  end if;

  /* Keep what was typed. Nothing reads these columns and no interface
     shows them — but a silent automatic rewrite with no record of what
     it replaced cannot be undone if the matching ever proves wrong. */
  update public.venues
     set original_name    = coalesce(original_name, name),
         original_lat     = coalesce(original_lat, lat),
         original_lng     = coalesce(original_lng, lng),
         name             = v_name,
         lat              = v_lat,
         lng              = v_lng,
         match_osm_id     = nullif(p_match->>'osm_id', ''),
         match_confidence = v_conf,
         match_status     = 'matched',
         match_checked_at = now(),
         updated_at       = now()
   where id = p_venue;

  /* Events carry a copy of the venue name and pin taken at publish
     time, so correcting the venue alone would leave every existing
     event still showing the old text on the old spot.

     The pin moves only where it CAME from the venue. pin_source
     'manual' means somebody deliberately dragged it, 'exif' means it
     came off their photo — in both cases they placed it more precisely
     than a venue centroid and overruling that would be worse than the
     typo we are fixing. The NAME is corrected either way. */
  update public.events e
     set venue_name = v_name,
         venue_lat  = case when coalesce(e.pin_source, 'venue') = 'venue'
                           then v_lat else e.venue_lat end,
         venue_lng  = case when coalesce(e.pin_source, 'venue') = 'venue'
                           then v_lng else e.venue_lng end,
         updated_at = now()
   where e.venue_id = p_venue and e.status = 'live';
  get diagnostics v_moved = row_count;

  return 'matched:' || v_moved;
end $$;

-- ── events ────────────────────────────────────────────────────

create or replace function public.event_json(p_short_id text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select to_jsonb(p) from public.events_public p where p.short_id = p_short_id;
$$;

/* publish_event was defined here as it originally stood, then corrected in
   part 4b. Only the corrected definition remains, so grep finds
   the live one. Identical signature, so no orphan is left behind
   in a database that ran the older files. */

create or replace function public.update_event_as(
  p_short_id     text,
  p_user         uuid,
  p_secret       text,
  p_patch        jsonb,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target    public.events;
  v_prior   jsonb;
  new_start timestamptz;
  others    integer;
  v_result  jsonb;
begin
  /* Replay first, before ownership or validation. A retry of an edit
     that already committed must return the original answer — not be
     re-judged against rules the event may no longer satisfy. */
  if p_operation_id is not null and p_user is not null then
    v_prior := public.op_replay(p_operation_id, p_user);
    if v_prior is not null then return v_prior || jsonb_build_object('replayed', true); end if;
  end if;

  select * into target from public.events e
   where e.short_id = p_short_id and e.status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  new_start := coalesce((nullif(p_patch->>'starts_at', ''))::timestamptz, target.starts_at);
  if new_start < now() - interval '90 days' then
    raise exception 'events may not be moved more than 90 days into the past'
      using errcode = '22023';
  end if;

  /* The host's own attendance never locks their own date — otherwise a
     host is locked out the moment they publish, since publish_event
     marks them going in the same transaction. */
  if new_start <> target.starts_at then
    select count(*) into others from public.attendances a
     where a.event_id = target.id and a.status in ('going','attended')
       and a.user_id is distinct from target.host_id;
    if others > 0 then
      raise exception 'cannot move an event once % other people are going', others
        using errcode = '23514';
    end if;
  end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((nullif(p_patch->>'venue_lat', ''))::double precision, e.venue_lat),
    venue_lng      = coalesce((nullif(p_patch->>'venue_lng', ''))::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (nullif(p_patch->>'ends_at', ''))::timestamptz else e.ends_at end,
    recurrence     = case when p_patch ? 'recurrence'
                          then p_patch->>'recurrence' else e.recurrence end,
    price_value    = coalesce((nullif(p_patch->>'price_value', ''))::integer, e.price_value),
    price_currency = coalesce(p_patch->>'price_currency', e.price_currency),
    capacity       = case when p_patch ? 'capacity'
                          then (nullif(p_patch->>'capacity', ''))::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    updated_at     = now()
  where e.id = target.id;

  /* Deliberately NOT patchable, whatever the client sends: host_id,
     photo_lat, photo_lng, edit_token_hash, status, short_id, is_backfill.
     An allowlist, not a denylist — a key absent from the SET above
     cannot be written no matter what arrives in the payload. */

  v_result := public.event_json(p_short_id);
  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'event.patch', v_result);
  end if;
  return v_result;
end $$;

create or replace function public.cancel_event_as(
  p_short_id text, p_user uuid, p_secret text, p_operation_id uuid default null
)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target  public.events;
  v_prior jsonb;
begin
  if p_operation_id is not null and p_user is not null then
    v_prior := public.op_replay(p_operation_id, p_user);
    if v_prior is not null then return true; end if;
  end if;

  select * into target from public.events e where e.short_id = p_short_id;
  if not found then return false; end if;
  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours to cancel' using errcode = '42501';
  end if;

  -- soft delete: the share link still resolves and explains itself
  update public.events set status = 'deleted', updated_at = now()
   where id = target.id;

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'event.cancel',
      jsonb_build_object('short_id', p_short_id, 'cancelled', true));
  end if;
  return true;
end $$;

create or replace function public.update_event(
  p_short_id text, p_token text, p_patch jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target    public.events;
  new_start timestamptz;
  others    integer;
begin
  select * into target from public.events
   where short_id = p_short_id and status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if target.edit_token_hash is null
     or target.edit_token_hash <> public.bich_hash(p_token) then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  new_start := coalesce((nullif(p_patch->>'starts_at', ''))::timestamptz, target.starts_at);
  if new_start < now() - interval '90 days' then
    raise exception 'events may not be moved more than 90 days into the past'
      using errcode = '22023';
  end if;

  -- the host's own attendance never locks their own date
  if new_start <> target.starts_at then
    select count(*) into others from public.attendances
     where event_id = target.id and status in ('going','attended')
       and user_id is distinct from target.host_id;
    if others > 0 then
      raise exception 'cannot move an event once % other people are going', others
        using errcode = '23514';
    end if;
  end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((nullif(p_patch->>'venue_lat', ''))::double precision, e.venue_lat),
    venue_lng      = coalesce((nullif(p_patch->>'venue_lng', ''))::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (nullif(p_patch->>'ends_at', ''))::timestamptz else e.ends_at end,
    price_value    = coalesce((nullif(p_patch->>'price_value', ''))::integer, e.price_value),
    capacity       = case when p_patch ? 'capacity'
                          then (nullif(p_patch->>'capacity', ''))::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    updated_at     = now()
  where e.id = target.id;

  return public.event_json(p_short_id);
end $$;

create or replace function public.cancel_event(p_short_id text, p_token text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;
  if target.edit_token_hash is null
     or target.edit_token_hash <> public.bich_hash(p_token) then
    raise exception 'not yours to cancel' using errcode = '42501';
  end if;
  update public.events set status = 'deleted', updated_at = now() where id = target.id;
  return true;
end $$;

create or replace function public.public_event(p_short_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_event public.events;
  v_json  jsonb;
begin
  select * into v_event from public.events e where e.short_id = p_short_id;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  if v_event.status = 'live' then
    select to_jsonb(p) into v_json
      from public.events_public p where p.short_id = p_short_id;
    return jsonb_build_object('found', true, 'status', 'live', 'event', v_json);
  end if;

  /* Cancelled or hidden. Return only what a stranger needs to
     understand why the link led nowhere — the title and when it would
     have been. No venue, no pin, no host, no counts: this event is not
     happening and nobody needs directions to it. */
  return jsonb_build_object(
    'found',  true,
    'status', v_event.status,
    'event',  jsonb_build_object(
      'short_id',  v_event.short_id,
      'title',     v_event.title,
      'starts_at', v_event.starts_at
    )
  );
end $$;

create or replace function public.my_hosted(p_user uuid, p_secret text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
  want text;
  rows jsonb;
begin
  if p_user is null or p_secret is null then return '[]'::jsonb; end if;

  select u.device_secret_hash into want from public.users u where u.id = p_user;
  if want is null or want <> public.bich_hash(p_secret) then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.starts_at desc), '[]'::jsonb)
    into rows
    from public.events_public p
    join public.events e on e.short_id = p.short_id
   where e.host_id = p_user;

  return rows;
end $$;

create or replace function public.my_events(p_hashes text[])
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.starts_at desc), '[]'::jsonb)
    from public.events_public p
    join public.events e on e.short_id = p.short_id
   where e.edit_token_hash = any(coalesce(p_hashes, array[]::text[]));
$$;

create or replace function public.my_events_as(p_user uuid, p_secret text)
returns jsonb
language sql stable security definer set search_path = public, extensions
as $$
  select public.my_hosted(p_user, p_secret);
$$;

create or replace function public.events_in_bbox(
  min_lat double precision, min_lng double precision,
  max_lat double precision, max_lng double precision,
  from_ts timestamptz default now()
)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.starts_at), '[]'::jsonb)
    from public.events_public p
   where p.venue_lat between min_lat and max_lat
     and p.venue_lng between min_lng and max_lng
     and p.starts_at >= from_ts;
$$;

/* Ahead of feed and feed_near: those are `language sql`, which
   resolves references at CREATE time, so a forward reference is
   a hard failure rather than a runtime one. */
create or replace function public.attended_count(viewer uuid)
returns integer
language sql stable
security definer
set search_path = public
as $$
  select count(*)::integer from public.attendances
  where user_id = viewer and status = 'attended';
$$;

create or replace function public.circle_count(viewer uuid, event uuid)
returns integer
language plpgsql stable
security definer
set search_path = public
as $$
declare
  total  integer;
  circle integer;
begin
  if viewer is null then return null; end if;

  select count(*) into total
  from public.attendances
  where event_id = event and status in ('going', 'attended');

  if total < 10 then return null; end if;

  select count(*) into circle from (
    select them.user_id
    from public.attendances mine
    join public.attendances them
      on them.event_id = mine.event_id
     and them.user_id <> viewer
     and them.status = 'attended'
    where mine.user_id = viewer
      and mine.status = 'attended'
      and them.user_id in (
        select user_id from public.attendances
        where event_id = event and status in ('going', 'attended')
      )
    group by them.user_id
    having count(distinct mine.event_id) >= 2      -- ← was >= 1
  ) paired;

  if circle < 3 then return 0; end if;
  return circle;
end $$;

create or replace function public.feed(
  viewer uuid default null,
  community text default null,
  from_ts timestamptz default now(),
  max_results integer default 50
)
returns table (
  id uuid, short_id text, title text, description text,
  venue_name text, venue_lat double precision, venue_lng double precision,
  city text, community_slug text,
  starts_at timestamptz, price_value integer, price_currency text,
  cover_url text, going_count bigint, circle_count integer
)
language sql stable
security definer
set search_path = public
as $$
  select e.id, e.short_id, e.title, e.description,
         e.venue_name, e.venue_lat, e.venue_lng,
         e.city, e.community_slug,
         e.starts_at, e.price_value, e.price_currency,
         e.cover_url,
         coalesce(a.n, 0) as going_count,
         case
           when viewer is null then null
           when public.attended_count(viewer) < 2 then null   -- cold start, Q9
           else public.circle_count(viewer, e.id)
         end as circle_count
  from public.events e
  left join (
    select event_id, count(*) as n from public.attendances
    where status in ('going','attended') group by event_id
  ) a on a.event_id = e.id
  where e.status = 'live'
    and e.starts_at >= from_ts
    and (community is null or e.community_slug = community)
  order by e.starts_at
  limit max_results;
$$;

create or replace function public.feed_near(
  viewer       uuid             default null,
  near_lat     double precision default null,
  near_lng     double precision default null,
  radius_km    double precision default 25,
  community    text             default null,
  from_ts      timestamptz      default now(),
  max_results  integer          default 60
)
returns table (
  id uuid, short_id text, title text, description text,
  venue_name text, venue_lat double precision, venue_lng double precision,
  city text, community_slug text,
  starts_at timestamptz, ends_at timestamptz, recurrence text,
  price_value integer, price_currency text, capacity integer, contact text,
  cover_url text, going_count bigint, circle_count integer,
  distance_km double precision
)
language sql stable
security definer
set search_path = public
as $$
  with box as (
    select
      near_lat - (radius_km / 111.0)                                          as min_lat,
      near_lat + (radius_km / 111.0)                                          as max_lat,
      near_lng - (radius_km / (111.0 * greatest(cos(radians(near_lat)), 0.01))) as min_lng,
      near_lng + (radius_km / (111.0 * greatest(cos(radians(near_lat)), 0.01))) as max_lng
  ),
  candidates as (
    select e.*,
           case when near_lat is null or e.venue_lat is null then null
           else 6371 * acos(least(1, greatest(-1,
                  sin(radians(near_lat)) * sin(radians(e.venue_lat)) +
                  cos(radians(near_lat)) * cos(radians(e.venue_lat)) *
                  cos(radians(e.venue_lng - near_lng))
                ))) end as dist
    from public.events e, box
    where e.status = 'live'
      and e.starts_at >= from_ts
      and (
        -- inside the box, so events_bbox_idx can be used
        (e.venue_lat between box.min_lat and box.max_lat
         and e.venue_lng between box.min_lng and box.max_lng)
        -- or explicitly in this community, which keeps events that
        -- were published without a pin from disappearing entirely
        or (community is not null and e.community_slug = community)
      )
  )
  select c.id, c.short_id, c.title, c.description,
         c.venue_name, c.venue_lat, c.venue_lng,
         c.city, c.community_slug,
         c.starts_at, c.ends_at, c.recurrence,
         c.price_value, c.price_currency, c.capacity, c.contact,
         c.cover_url,
         coalesce(a.n, 0) as going_count,
         case
           when viewer is null then null
           when public.attended_count(viewer) < 2 then null   -- cold start, Q9
           else public.circle_count(viewer, c.id)
         end as circle_count,
         c.dist as distance_km
  from candidates c
  left join (
    select event_id, count(*) as n from public.attendances
    where status in ('going','attended') group by event_id
  ) a on a.event_id = c.id
  -- the box is a square, the radius is a circle; this trims the corners
  where c.dist is null
     or c.dist <= radius_km
     or (community is not null and c.community_slug = community)
  order by c.starts_at
  limit max_results;
$$;

/* A per-host publishing quota was sketched in schema 9 and never
   enabled — it lived entirely inside a comment. My extractor took its
   `create` line and left the body commented, producing a statement
   with no terminator, which is what broke this file at that point.
   Removed rather than revived: no quota has been asked for. */

create or replace function public.adopt_orphan_events(
  p_user uuid, p_secret text, p_handle text default null
)
returns integer
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_target uuid;
  n integer;
begin
  -- Only an admin may do this: it hands over other people's events.
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  if p_handle is null then
    v_target := p_user;
  else
    select id into v_target from public.users where handle = p_handle;
    if not found then
      raise exception 'no user with handle %', p_handle using errcode = 'P0002';
    end if;
  end if;

  update public.events set host_id = v_target, updated_at = now()
   where host_id is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ── attendance ────────────────────────────────────────────────

create or replace function public.set_attendance(
  p_short_id     text,
  p_user         uuid,
  p_secret       text,
  p_status       text,
  p_operation_id uuid default null
)
returns table (
  short_id    text,
  status      text,
  going_count integer
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_event public.events;
  v_now   integer;
begin
  if p_status is null or p_status not in ('going', 'cancelled') then
    raise exception 'status must be going or cancelled' using errcode = '22023';
  end if;
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  /* Every column below is qualified. RETURNS TABLE makes short_id,
     status and going_count into VARIABLES in this body, so an
     unqualified `status` is ambiguous with events.status — which is
     exactly the 42702 this function shipped with. */
  select * into v_event from public.events e
   where e.short_id = p_short_id and e.status = 'live';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  insert into public.attendances as att (event_id, user_id, status, joined_at)
  values (v_event.id, p_user, p_status, now())
  on conflict (event_id, user_id) do update
    set status = excluded.status,
        confirmed_at = case when excluded.status = 'going'
                            then null else att.confirmed_at end;

  select count(*)::integer into v_now
    from public.attendances a
   where a.event_id = v_event.id and a.status in ('going', 'attended');

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'attendance.set',
      jsonb_build_object('short_id', p_short_id, 'status', p_status, 'going_count', v_now));
  end if;

  return query select p_short_id, p_status, v_now;
end $$;

create or replace function public.my_going(p_viewer uuid, p_event_ids text[] default null)
returns table (short_id text, status text)
language sql stable security definer set search_path = public
as $$
  select e.short_id, a.status
  from public.attendances a
  join public.events e on e.id = a.event_id
  where a.user_id = p_viewer
    and a.status in ('going','attended')
    and (p_event_ids is null or e.short_id = any(p_event_ids))
$$;

create or replace function public.record_visit(p_short_id text, p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_event uuid;
begin
  if p_user is null then return; end if;

  select id into v_event from public.events
   where short_id = p_short_id and status = 'live';
  if not found then return; end if;

  insert into public.event_visits (event_id, user_id)
  values (v_event, p_user)
  on conflict (event_id, user_id) do update
    set last_seen  = now(),
        seen_count = public.event_visits.seen_count + 1;
end $$;

create or replace function public.event_stats(
  p_short_id text, p_user uuid, p_secret text
)
returns table (
  visitors      integer,   -- distinct people who opened it
  going         integer,   -- currently marked going
  attended      integer,   -- promoted after the event ended
  cancelled     integer,   -- said going, then changed their mind
  repeat_visits integer    -- opened it more than once: real interest
)
language plpgsql stable security definer set search_path = public
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return; end if;

  -- host only. owns_event() checks host_id AND the device secret.
  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  return query
  select
    (select count(*)::integer from public.event_visits v where v.event_id = target.id),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'going'),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'attended'),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'cancelled'),
    (select count(*)::integer from public.event_visits v
      where v.event_id = target.id and v.seen_count > 1);
end $$;

create or replace function public.promote_attendance(grace interval default interval '3 hours')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  update public.attendances a
     set status = 'attended', confirmed_at = now()
    from public.events e
   where e.id = a.event_id
     and a.status = 'going'
     and e.status = 'live'
     /* THREE HOURS AFTER IT STARTED, not after it ended.
        This used to read
          coalesce(e.ends_at, e.starts_at + interval '3 hours') < now() - grace
        which waited for the END and then added the grace on top — so a
        21:00 gig listed as finishing at 02:00 did not confirm until
        05:00, and one with no finish time waited six hours from the
        start. Somebody who said they were going and whose event began
        three hours ago was there; that is the whole signal.
        Deliberately independent of ends_at: a five hour party confirms
        while it is still going on, which is correct — they are at it. */
     and e.starts_at < now() - grace;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.recent_auto_attended(
  p_user uuid, p_since interval default interval '7 days'
)
returns table (
  event_id   uuid,
  short_id   text,
  title      text,
  starts_at  timestamptz,
  venue_name text
)
language sql stable security definer set search_path = public
as $$
  select e.id, e.short_id, e.title, e.starts_at, e.venue_name
  from public.attendances a
  join public.events e on e.id = a.event_id
  where a.user_id = p_user
    and a.status = 'attended'
    and a.confirmed_at is not null
    and a.confirmed_at > now() - p_since
  order by e.starts_at desc
  limit 10;
$$;

create or replace function public.unattend_as(
  p_user uuid, p_secret text, p_event uuid
)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  update public.attendances
     set status = 'cancelled', confirmed_at = null
   where user_id = p_user and event_id = p_event and status = 'attended';
  return found;
end $$;





create or replace function public.decay_unconfirmed(older_than interval default '7 days')
returns integer
language sql as $$
  with done as (
    update public.attendances a
    set status = 'cancelled'
    from public.events e
    where a.event_id = e.id
      and a.status = 'going'
      and e.starts_at < now() - older_than
    returning 1
  )
  select count(*)::integer from done;
$$;

-- ── magic ─────────────────────────────────────────────────────

create or replace function public.may_use_magic_as(p_user uuid, p_secret text)
returns table (allowed boolean, granted_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_on   boolean;
  v_at   timestamptz;
begin
  if p_user is null or p_secret is null then
    return query select false, null::timestamptz; return;
  end if;

  select device_secret_hash, magic_enabled, magic_granted_at
    into v_hash, v_on, v_at
  from public.users where id = p_user;

  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    return query select false, null::timestamptz; return;
  end if;

  return query select coalesce(v_on, false), v_at;
end $$;

create or replace function public.my_magic(p_user uuid, p_secret text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select coalesce((select allowed from public.may_use_magic_as(p_user, p_secret)), false);
$$;

create or replace function public.redeem_magic_code(
  p_user uuid, p_secret text, p_code text
)
returns table (ok boolean, reason text)
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_row  public.magic_codes;
  v_norm text;
begin
  if p_user is null or p_secret is null or p_code is null then
    return query select false, 'missing details'; return;
  end if;

  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    -- identical answer to a bad code, so this cannot probe accounts
    return query select false, 'that code did not work'; return;
  end if;

  -- case and spacing should never be why a code fails
  v_norm := lower(regexp_replace(btrim(p_code), '\s+', '', 'g'));

  select * into v_row from public.magic_codes where code = v_norm and active = true;

  if not found
     or (v_row.expires_at is not null and v_row.expires_at < now())
     or (v_row.max_uses   is not null and v_row.used_count >= v_row.max_uses) then
    return query select false, 'that code did not work'; return;
  end if;

  update public.users
     set magic_enabled = true,
         magic_granted_at = coalesce(magic_granted_at, now()),
         magic_source = coalesce(magic_source, v_norm)
   where id = p_user;

  update public.magic_codes set used_count = used_count + 1 where code = v_norm;

  return query select true, 'magic is on';
end $$;

-- ── admin ─────────────────────────────────────────────────────

create or replace function public.admin_all_events(
  p_user uuid, p_secret text, p_limit integer default 200
)
returns table (
  short_id     text,
  title        text,
  status       text,
  starts_at    timestamptz,
  venue_name   text,
  city         text,
  community    text,
  host_handle  text,
  source       text,
  needs_review boolean,
  created_at   timestamptz
)
language plpgsql stable security definer set search_path = public, extensions
as $$
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  return query
    select e.short_id, e.title, e.status, e.starts_at, e.venue_name,
           e.city, e.community_slug, u.handle, e.source, e.needs_review, e.created_at
    from public.events e
    left join public.users u on u.id = e.host_id
    order by e.created_at desc
    limit greatest(1, least(coalesce(p_limit, 200), 1000));
end $$;

create or replace function public.admin_update_event(
  p_user uuid, p_secret text, p_short_id text, p_patch jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  select * into target from public.events where short_id = p_short_id;
  if not found then raise exception 'no such event' using errcode = 'P0002'; end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((nullif(p_patch->>'venue_lat', ''))::double precision, e.venue_lat),
    venue_lng      = coalesce((nullif(p_patch->>'venue_lng', ''))::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = coalesce((nullif(p_patch->>'starts_at', ''))::timestamptz, e.starts_at),
    ends_at        = case when p_patch ? 'ends_at'
                          then (nullif(p_patch->>'ends_at', ''))::timestamptz else e.ends_at end,
    price_value    = coalesce((nullif(p_patch->>'price_value', ''))::integer, e.price_value),
    capacity       = case when p_patch ? 'capacity'
                          then (nullif(p_patch->>'capacity', ''))::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    needs_review   = false,      -- an admin has now looked at it
    status         = coalesce(p_patch->>'status', e.status),
    updated_at     = now()
  where e.id = target.id;

  return public.event_json(p_short_id);
end $$;

create or replace function public.admin_cancel_event(
  p_user uuid, p_secret text, p_short_id text, p_hard boolean default false
)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;

  if p_hard then
    -- Only for genuine rubbish. Attendances and visits go with it.
    delete from public.events where id = target.id;
  else
    update public.events set status = 'deleted', updated_at = now()
     where id = target.id;
  end if;
  return true;
end $$;

-- ── the self-check ────────────────────────────────────────────────
-- One query that answers "does this database match what the frontend
-- calls?". It checks SIGNATURES, not names: a client calling
-- update_event_as with five arguments against a four-argument
-- function passed name-only verification and broke production.

create or replace function public.bich_verify()
returns table (check_name text, ok boolean, detail text)
language plpgsql stable security definer set search_path = public
as $$
declare
  r record;
  sig text;
  /* name(argument types) — the actual contract the frontend calls.
     The previous version checked names alone, which is why a client
     calling update_event_as with five arguments against a four
     argument function passed verification and failed in production. */
  needed text[] := array[
    'create_account()',
    'get_my_account(uuid,text)',
    'account_exists(uuid)',
    'claim_device_secret(uuid,text)',
    'publish_event(jsonb,uuid,text,uuid)',
    'update_event_as(text,uuid,text,jsonb,uuid)',
    'cancel_event_as(text,uuid,text,uuid)',
    'set_attendance(text,uuid,text,text,uuid)',
    'set_my_community(uuid,text,text,text,uuid)',
    'ensure_venue(jsonb,uuid,text,uuid)',
    'ensure_community(text,text,text,text,double precision,double precision)',
    'community_lookup(text)',
    'public_event(text)',
    'event_json(text)',
    'event_stats(text,uuid,text)',
    'my_going(uuid,text[])',
    'my_hosted(uuid,text)',
    'search_venues(text,double precision,double precision,text,integer)',
    'promote_attendance(interval)',
    'circle_count(uuid,uuid)',
    'op_replay(uuid,uuid)',
    'op_record(uuid,uuid,text,jsonb)',
    'bich_hash(text)',
    'pick_handle()',
    'may_use_magic_as(uuid,text)',
    'is_admin(uuid,text)'
  ];
begin
  /* to_regprocedure() resolves a signature string to an oid, or null.
     It is the one thing in Postgres built to answer exactly this
     question, and it handles type aliases — int4 and integer, float8
     and double precision — which a string comparison does not.

     The previous version compared against
     pg_get_function_identity_arguments(), which returns
     "p_user uuid, p_secret text" — WITH parameter names and a space
     after each comma. Comparing that to "uuid,text" never matched, so
     every function taking arguments was reported missing while all of
     them worked. Twenty-four false failures. */
  foreach sig in array needed loop
    return query select
      ('rpc ' || sig)::text,
      to_regprocedure('public.' || sig) is not null,
      'signature must match what the frontend calls'::text;
  end loop;

  /* feed and feed_near vary by schema version; check the name only. */
  foreach sig in array array['feed','feed_near'] loop
    return query select ('rpc ' || sig)::text,
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = sig), ''::text;
  end loop;

  for r in
    select p.proname::text as nm from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and pg_get_function_result(p.oid) like '%events_public%'
  loop
    return query select ('cascade risk: ' || r.nm)::text, false,
      'returns events_public — a view rebuild deletes this function'::text;
  end loop;

  for r in
    select t.table_name::text as tn,
           string_agg(distinct t.privilege_type, ', ')::text as privs
      from information_schema.role_table_grants t
     where t.grantee = 'anon' and t.table_schema = 'public'
       and t.table_name in ('users','events','attendances','venues',
                            'communities','credentials','client_operations')
     group by t.table_name
  loop
    return query select ('anon still has grants on ' || r.tn)::text, false, r.privs;
  end loop;

  return query select 'attendances has no select policy'::text,
    not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'attendances'
                   and cmd in ('SELECT','ALL')), ''::text;

  return query select 'events_public hides private columns'::text,
    not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'events_public'
                   and column_name in ('photo_lat','photo_lng','host_id','edit_token_hash')),
    'photo gps and ownership must never reach a public projection'::text;

  begin
    perform public.bich_hash('x');
    return query select 'bich_hash works'::text, true, ''::text;
  exception when others then
    return query select 'bich_hash works'::text, false, sqlerrm::text;
  end;

  begin
    return query select 'promote_attendance is scheduled'::text,
      exists (select 1 from cron.job where jobname = 'bich-promote-attendance'),
      'enable pg_cron and re-run schema 12 if false'::text;
  exception when others then
    return query select 'promote_attendance is scheduled'::text, false,
      'pg_cron is not installed'::text;
  end;
end $$;

grant execute on function public.bich_verify() to anon;



-- ═══════════════════════════════════════════════════════════════════
-- 4b. CORRECTIONS  (was patch 35)
-- ═══════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- 1. ensure_community could never insert a row
--
-- The insert ended `on conflict (word) do nothing`. communities has no
-- `word` column — its primary key is `slug`. `word` is the column on
-- reserved_slugs, and this looks like it was carried across from the
-- rename guard that sits directly above it in the baseline.
--
-- plpgsql plans statements on first execution, not at CREATE, so the
-- function was created without complaint and raised
--   column "word" does not exist
-- only when somebody published in a town no community covered yet.
-- Every other path stayed green, which is why the communities table
-- looked merely empty rather than broken.
--
-- Rewritten below with an UNTARGETED `on conflict do nothing` — not
-- `on conflict (slug)`, which would fix the crash but catch only the
-- primary key and let the osm_id race through as an exception. The
-- reasoning is at the statement itself. Everything else in the
-- body is unchanged from the baseline.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.ensure_community(
  p_osm_id  text,
  p_name    text,
  p_kind    text,
  p_country text,
  p_lat     double precision,
  p_lng     double precision
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slug text;
begin
  if p_osm_id is null or btrim(p_osm_id) = '' then return null; end if;
  if p_lat is null or p_lng is null then return null; end if;
  if p_lat not between -90 and 90 then return null; end if;
  if p_lng not between -180 and 180 then return null; end if;
  if p_name is null or length(btrim(p_name)) = 0 then return null; end if;

  select slug into v_slug from public.communities where osm_id = p_osm_id;
  if v_slug is not null then return v_slug; end if;

  -- slugify, then de-collide. Two Santa Marias in two countries are two
  -- communities and must not fight over one primary key.
  v_slug := lower(btrim(p_name));
  v_slug := translate(v_slug,
              'áàâãäåéèêëíìîïóòôõöúùûüçñý',
              'aaaaaaeeeeiiiiooooouuuucny');
  v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
  v_slug := btrim(v_slug, '-');
  if v_slug = '' then return null; end if;

  if exists (select 1 from public.communities where slug = v_slug) then
    v_slug := v_slug || '-' || lower(coalesce(nullif(btrim(p_country), ''), 'xx'));
  end if;
  if exists (select 1 from public.communities where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(p_osm_id), 1, 4);
  end if;

  insert into public.communities
    (slug, name, country, centre_lat, centre_lng, radius_km, kind, osm_id, is_active)
  values
    (v_slug, btrim(p_name),
     upper(nullif(btrim(coalesce(p_country, '')), '')),
     p_lat, p_lng,
     public.default_radius_for(p_kind),
     lower(nullif(btrim(coalesce(p_kind, '')), '')),
     p_osm_id, true)
  /* Untargeted, and that is deliberate. `on conflict (slug)` would fix
     the crash but catch only the primary key — communities also carries
     a PARTIAL unique index, communities_osm_idx on (osm_id) where
     osm_id is not null. Two devices reaching a new town in the same
     second collide on THAT, not on slug, and a targeted clause would
     let the unique violation through as a raised exception.
     A bare `do nothing` covers every constraint on the table. */
  on conflict do nothing;   -- ← was `on conflict (word)`, a column that does not exist

  /* Two callers racing on the same new town: the loser's insert does
     nothing and v_slug is still the name it built, which is now
     somebody else's row or no row at all. Read back by osm_id, the
     stable key, and return what is actually there. */
  select slug into v_slug from public.communities where osm_id = p_osm_id;
  return v_slug;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 2. The 'view' community signal was never legitimate
--
-- FIRST DIAGNOSIS WAS WRONG, recorded because the correction is the
-- interesting part. I saw that users_community_via_check and
-- adopt_community_at both allow four signals while set_my_community
-- allows three, and treated the three as the outlier — so the first
-- version of this file WIDENED set_my_community to accept 'view'.
--
-- That would have made a broken thing work reliably. There are exactly
-- three signals, and all three are things somebody DID:
--
--   link      opened a shared event link
--   publish   published an event carrying venue coordinates
--   photo     chose a photo with GPS while creating an event
--
-- The latest valid signal replaces the previous community. Browsing is
-- not on that list and must not be: you open far more events than you
-- act on, and most of them are already near you. A person tapping
-- around another town's pins has not moved.
--
-- So the three-value list was correct all along and the fourth value is
-- the defect. Tightened everywhere instead of widened.
--
-- The client half of this is in index.html: openDetail no longer sends
-- a signal at all, and adoptCommunity() refuses an unrecognised one
-- before it can reach the outbox.
--
-- ORDER MATTERS BELOW. Existing rows are migrated BEFORE the constraint
-- is tightened, or the ALTER fails against its own table.
-- ═══════════════════════════════════════════════════════════════════

/* Anybody carrying via = 'view' got there through adopt_community_at,
   which accepted it. Their community_slug is kept: it is very likely
   the right town, and clearing it drops them back to the fallback,
   which is a worse answer than a quietly unattributed one. Only the
   provenance is cleared, and the column already permits null. */
update public.users
   set community_via = null
 where community_via = 'view';

alter table public.users drop constraint if exists users_community_via_check;
alter table public.users add constraint users_community_via_check
  check (community_via is null or community_via in ('link','photo','publish'));

/* adopt_community_at is where 'view' actually entered the database —
   set_my_community was already refusing it, which is why the outbox
   filled with permanent failures while rows still got written by the
   other path. Narrowed to the same three. Body otherwise unchanged
   from the baseline. */
create or replace function public.adopt_community_at(
  p_user uuid, p_secret text,
  p_lat double precision, p_lng double precision,
  p_via text,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_slug text;
  v_name text;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;
  -- three signals, matching users_community_via_check and set_my_community
  if p_via is null or p_via not in ('link','photo','publish') then
    raise exception 'unknown community signal' using errcode = '22023';
  end if;

  v_slug := public.community_for_point(p_lat, p_lng);
  if v_slug is null then
    return jsonb_build_object('found', false, 'reason', 'no community covers that point');
  end if;

  select c.name into v_name from public.communities c where c.slug = v_slug;

  update public.users u
     set community_slug = v_slug,
         community_via = p_via,
         community_updated_at = now()
   where u.id = p_user;

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'community.set',
      jsonb_build_object('slug', v_slug, 'via', p_via));
  end if;

  return jsonb_build_object('found', true, 'slug', v_slug, 'name', v_name, 'via', p_via);
end $$;

/* set_my_community is left EXACTLY as the baseline has it. It was
   right. Recorded here so the next person to notice the asymmetry
   between the two functions does not "fix" it in the wrong direction
   the way I did. */


-- ═══════════════════════════════════════════════════════════════════
-- 3. events.venue_id is NULL on every row ever published
--
-- This started as "bump_venue_use is defined but never attached", which
-- is true — the baseline creates the function in section 4 and no
-- trigger for it in section 5. Attaching it changed nothing, which is
-- how the bigger fault surfaced.
--
-- publish_event does not write venue_id. It is absent from the INSERT
-- column list entirely, and the client never sends it: the create form
-- computes draft.venueId through ensureVenue(), carries it as far as
-- spec.venueId, and then drops it — p_payload has no such key. So the
-- column is NULL on every event in the database.
--
-- Three things fail from that one omission, all silently:
--
--   · bump_venue_use tests `new.venue_id is not null` and returns
--     early forever, so venues.use_count never leaves zero and the
--     `least(use_count, 10) * 0.1` term in search_venues() is dead.
--     A venue fifty people used ranks like one nobody has.
--
--   · apply_venue_match ends with
--         update public.events … where e.venue_id = p_venue
--     which matches ZERO ROWS, ALWAYS. The Worker's whole venue
--     canonicalisation pipeline — the scheduled sweep, the Overpass
--     round trips, the 300m and 0.6-confidence rules, the careful
--     pin_source logic about not overruling a hand-placed pin —
--     corrects the venues table and never reaches a single event.
--     Nobody has ever seen a corrected venue name on an event.
--
--   · ensure_venue's dedupe still works, so the venues table fills up
--     correctly. That is why this looked healthy from the database
--     side: the rows are all there and all correct, just unreferenced.
--
-- Fixed at the source. publish_event now reads venue_id from the
-- payload, and index.html sends it. The insert body is otherwise
-- byte-identical to the baseline.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.publish_event(
  p_payload      jsonb,
  p_user         uuid,
  p_secret       text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash   text;
  v_prior  jsonb;
  v_short  text;
  v_id     uuid;
  v_venue  uuid;
  v_start  timestamptz;
  v_end    timestamptz;
  v_result jsonb;
begin
  if p_user is null or p_secret is null or p_operation_id is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found then
    raise exception 'no account on this device' using errcode = '42501';
  end if;
  if v_hash is null then
    raise exception 'this device has not claimed its account yet' using errcode = '42501';
  end if;
  if v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  v_prior := public.op_replay(p_operation_id, p_user);
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if coalesce(btrim(p_payload->>'title'), '') = '' then
    raise exception 'a title is required' using errcode = '22023';
  end if;
  if length(p_payload->>'title') > 200 then
    raise exception 'that title is too long' using errcode = '22023';
  end if;
  if coalesce(btrim(p_payload->>'venue_name'), '') = '' then
    raise exception 'a venue name is required' using errcode = '22023';
  end if;

  v_start := (nullif(p_payload->>'starts_at', ''))::timestamptz;
  if v_start is null then
    raise exception 'a date and time are required' using errcode = '22023';
  end if;
  if v_start < now() - interval '90 days' then
    raise exception 'that date is more than 90 days ago' using errcode = '22023';
  end if;
  if v_start > now() + interval '2 years' then
    raise exception 'that date is too far ahead' using errcode = '22023';
  end if;

  v_end := (nullif(p_payload->>'ends_at', ''))::timestamptz;
  if v_end is not null and v_end <= v_start then
    raise exception 'the finish must be after the start' using errcode = '22023';
  end if;

  if (p_payload->>'venue_lat') is not null
     and ((nullif(p_payload->>'venue_lat', ''))::double precision not between -90 and 90
       or (nullif(p_payload->>'venue_lng', ''))::double precision not between -180 and 180) then
    raise exception 'those coordinates are not on earth' using errcode = '22023';
  end if;

  v_short := public.gen_short_id();

  /* Looked up rather than trusted. A malformed uuid would raise 22P02
     and a well-formed one for a deleted venue would raise a foreign key
     violation — both of which lose somebody's event over a field that
     is only ever a ranking hint. Unknown means null, and null is the
     state every event is in today, so this cannot be worse. */
  v_venue := (select v.id from public.venues v
               where v.id = (nullif(p_payload->>'venue_id', ''))::uuid);

  insert into public.events (
    short_id, host_id, venue_id, title, description,
    venue_name, venue_address, venue_lat, venue_lng, venue_source,
    city, community_slug, photo_lat, photo_lng,
    starts_at, ends_at, recurrence,
    price_value, price_currency, capacity,
    cover_url, contact, source, category,
    pin_source, is_backfill, needs_review,
    status, edit_token_hash
  ) values (
    v_short, p_user, v_venue,
    btrim(p_payload->>'title'),
    nullif(btrim(coalesce(p_payload->>'description', '')), ''),
    btrim(p_payload->>'venue_name'),
    nullif(btrim(coalesce(p_payload->>'venue_address', '')), ''),
    (nullif(p_payload->>'venue_lat', ''))::double precision,
    (nullif(p_payload->>'venue_lng', ''))::double precision,
    public.normalise_venue_source(p_payload->>'venue_source'),
    nullif(p_payload->>'city', ''),
    nullif(p_payload->>'community_slug', ''),
    (nullif(p_payload->>'photo_lat', ''))::double precision,
    (nullif(p_payload->>'photo_lng', ''))::double precision,
    v_start, v_end,
    nullif(p_payload->>'recurrence', ''),
    coalesce((nullif(p_payload->>'price_value', ''))::integer, 0),
    coalesce(nullif(p_payload->>'price_currency', ''), 'EUR'),
    (nullif(p_payload->>'capacity', ''))::integer,
    nullif(p_payload->>'cover_url', ''),
    nullif(p_payload->>'contact', ''),
    coalesce(nullif(p_payload->>'source', ''), 'manual'),
    nullif(p_payload->>'category', ''),
    nullif(p_payload->>'pin_source', ''),
    coalesce((nullif(p_payload->>'is_backfill', ''))::boolean, v_start < now() - interval '1 hour'),
    coalesce((nullif(p_payload->>'needs_review', ''))::boolean, false),
    'live',
    nullif(p_payload->>'edit_token_hash', '')
  )
  returning id into v_id;

  insert into public.attendances (event_id, user_id, status, joined_at)
  values (v_id, p_user, 'going', now())
  on conflict (event_id, user_id) do nothing;

  v_result := jsonb_build_object(
    'short_id', v_short, 'id', v_id, 'event', public.event_json(v_short));

  perform public.op_record(p_operation_id, p_user, 'event.create', v_result);
  return v_result;
end $$;

drop trigger if exists events_bump_venue_use on public.events;
create trigger events_bump_venue_use after insert on public.events
  for each row execute function public.bump_venue_use();

/* Recount rather than trust the counter, so re-running this file does
   not inflate it. Every existing event has venue_id null, so this sets
   the world to zero today and starts counting truthfully from the next
   publish. Historical events cannot be linked back reliably — matching
   them on name and proximity would be a guess written into data. */
update public.venues v
   set use_count = coalesce(n.c, 0)
  from (select vv.id,
               (select count(*) from public.events e where e.venue_id = vv.id) as c
          from public.venues vv) n
 where n.id = v.id
   and v.use_count is distinct from n.c;


-- ═══════════════════════════════════════════════════════════════════
-- 4. communities.event_count only ever went up
--
-- events_bump_community fired `after insert` alone. Cancelling an event
-- sets status = 'deleted' — an UPDATE — so the count kept the cancelled
-- event forever. bump_community_count() recounts from scratch rather
-- than incrementing, so simply widening the trigger to UPDATE is enough
-- and cannot double-count.
--
-- Restricted to the two columns that can change the answer, so ordinary
-- edits do not trigger a recount on every keystroke-sized patch.
--
-- Note it recounts NEW.community_slug only. An event MOVED between
-- communities leaves the old one high until something else there
-- changes. Recorded in review.md rather than fixed here: the fix needs
-- OLD as well, and moving an event between communities is not a thing
-- the interface currently does.
-- ═══════════════════════════════════════════════════════════════════

drop trigger if exists events_bump_community_upd on public.events;
create trigger events_bump_community_upd after update of status, community_slug
  on public.events
  for each row execute function public.bump_community_count();

-- one-off reconciliation for the drift already accumulated
update public.communities c
   set event_count = coalesce(n.c, 0)
  from (select cm.slug,
               (select count(*) from public.events e
                 where e.community_slug = cm.slug and e.status = 'live') as c
          from public.communities cm) n
 where n.slug = c.slug
   and c.event_count is distinct from n.c;


-- ═══════════════════════════════════════════════════════════════════
-- 5. publish_event hard-failed when venue_source was absent
--
-- Found by running a publish against a scratch database rather than by
-- reading, because both live callers happen to mask it.
--
-- events.venue_source is `not null default 'manual'`. publish_event
-- inserts public.normalise_venue_source(p_payload->>'venue_source'),
-- and that helper returns NULL for a NULL input. An explicit NULL in an
-- INSERT does NOT fall back to the column default — it is a not-null
-- violation. So a payload with no venue_source key dies with
--   null value in column "venue_source" violates not-null constraint
-- rather than defaulting to 'manual'.
--
-- Nothing is broken in production TODAY: publishSpec() sends
-- `spec.venueSource || null`, and both builders that feed it always
-- terminate in 'manual' — the create form at index.html:7058 and the
-- magic ternary at :4612. Every other field in that insert is written
-- defensively with coalesce; this one was not, so the whole publish
-- path rests on two client expressions continuing to be exhaustive.
--
-- Fixed in the helper rather than in publish_event: one line, in a tiny
-- immutable function whose only caller is publish_event, instead of
-- replacing the largest write in the schema. The helper's own comment
-- already says an unrecognised label is "not a fact worth losing an
-- event over" — a missing label is the same case.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.normalise_venue_source(p_source text)
returns text
language sql immutable
as $$
  select case
    -- was `when p_source is null then null`, which the not-null column
    -- then rejected instead of defaulting
    when p_source is null or btrim(p_source) = '' then 'manual'
    when lower(btrim(p_source)) in
      ('manual','printed_coordinates','printed_address','venue_name_only','matched_venue')
      then lower(btrim(p_source))
    -- anything else was a client-side label, not a fact worth losing an event over
    else 'manual'
  end;
$$;


-- ═══════════════════════════════════════════════════════════════════
-- 6. Admin: 'lark north', and nobody else
--
-- No admin exists in the baseline. users.is_admin is `not null default
-- false` and no statement anywhere sets it true, so admin_all_events,
-- admin_update_event, admin_cancel_event and adopt_orphan_events are
-- currently unreachable by everyone — is_admin() returns false for
-- every account. That is safe, and also means the admin screen has
-- never been usable.
--
-- Granted here by handle rather than by uuid so this file stays
-- readable and carries no identifier that means anything outside the
-- database. 'lark' is a part-a word and 'north' is a part-b word in the
-- seeded handle_words, so this is a handle the generator can really
-- produce.
--
-- Written as a full reassignment, not an addition: everyone else is
-- demoted in the same statement, so re-running this file can never
-- leave two admins behind, and changing the handle above is enough to
-- move the role.
-- ═══════════════════════════════════════════════════════════════════

do $$
declare
  v_handle constant text := 'lark north';
  v_id     uuid;
begin
  select id into v_id from public.users where handle = v_handle;

  if v_id is null then
    /* WARNING, not EXCEPTION. Aborting the whole patch over a missing
       account would block five unrelated bug fixes, and the account may
       simply not have been created on this database yet. But it is a
       warning rather than a notice because a silent no-op here is
       exactly the failure mode that hides bugs in this project — you
       would believe you had an admin and have none. Re-run the grant
       on its own once the handle exists. */
    raise warning 'no account with handle % — admin NOT granted. Everyone remains non-admin.', v_handle;
    return;
  end if;

  update public.users
     set is_admin = (id = v_id)
   where is_admin is distinct from (id = v_id);

  raise notice 'admin granted to % (%)', v_handle, v_id;
end $$;


-- ═══════════════════════════════════════════════════════════════════
-- 4c. FEED RANKING  (was patch 36)
-- ═══════════════════════════════════════════════════════════════════



-- ═══════════════════════════════════════════════════════════════════
-- 1. What counts as having been somewhere
--
-- 'going' and 'attended' are the SAME evidence. Somebody who says they
-- are going has told you where they will be, and that is the whole
-- signal — waiting for promote_attendance to relabel it adds nothing
-- except delay.
--
-- It also removes a dependency that was quietly fatal. attended only
-- exists after a cron job runs, Supabase pauses cron on sleeping free
-- projects, and the baseline says so itself. On a quiet project
-- attended_count stayed 0 for every account forever, so circle_count
-- returned null for everyone no matter how much real activity there
-- was. Counting 'going' makes the signal self-sustaining.
--
-- 'attended' remains a distinct status because it is the CONFIRMED
-- one — promote_attendance proposes it, recent_auto_attended shows it
-- back to the person, unattend_as lets them correct it. That
-- correction is what 'cancelled' records, and cancelled is the one
-- state that must never count as evidence of presence.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.presence_statuses()
returns text[] language sql immutable parallel safe as $$
  select array['going','attended']::text[]
$$;

comment on function public.presence_statuses() is
  'The attendance statuses that count as evidence somebody was/will be there. '
  'going and attended are equivalent for this purpose; cancelled never counts.';


-- ═══════════════════════════════════════════════════════════════════
-- 2. viewer_circle — the people you keep running into
--
-- ONCE PER VIEWER, not once per event. circle_count() was called for
-- every row of every feed, so one feed load ran sixty multi-joins over
-- attendances. That is already the heaviest thing in the schema and it
-- degrades quadratically with the size of the community. This computes
-- the circle a single time and the feed joins against it.
--
-- WEIGHTING. Letting 'going' count makes pairs cheap — it is free to
-- declare, so two people who both tapped going on a 400-person
-- festival would otherwise look exactly like two people who both went
-- to a 12-person poetry night. The answer is not to trust 'going' less
-- than 'attended'; it is to weight the shared EVENT by how selective
-- it was:
--
--     1 / log2(2 + attendees)
--
-- A 12-person night is worth ~0.28, a 400-person festival ~0.12. Two
-- people who keep turning up at the same small things accumulate real
-- affinity; two people who both attend the town's biggest events
-- barely register. (Adamic-Adar, in the usual form.)
--
-- TWO ANTI-GAMING FLOORS, because inverse popularity is exploitable at
-- the bottom — a 2-person event would otherwise score highest of all:
--
--   · a shared event needs >= 3 people before it is evidence of
--     anything, so inventing a private event with one accomplice
--     forges nothing
--   · at most 5 shared events count toward any one pair, so marking
--     going on everything somebody else does cannot manufacture an
--     unbounded bond. The 5 SMALLEST are taken, which is the
--     conservative direction: it keeps the strongest evidence and
--     discards the crowd events.
--
-- And a pair still needs >= 2 shared events to exist at all, which is
-- the rule the baseline already used.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.viewer_circle(p_viewer uuid)
returns table (peer_id uuid, affinity real)
language sql stable
security definer
set search_path = public
as $$
  with mine as (
    select a.event_id
      from public.attendances a
     where a.user_id = p_viewer
       and a.status = any (public.presence_statuses())
  ),
  sized as (
    select m.event_id, count(*)::integer as head
      from mine m
      join public.attendances a
        on a.event_id = m.event_id
       and a.status = any (public.presence_statuses())
     group by m.event_id
    having count(*) >= 3          -- forged-pair floor
  ),
  shared as (
    select them.user_id as peer,
           (1.0 / log(2.0, (2 + s.head)::numeric))::real as w,
           row_number() over (partition by them.user_id order by s.head asc) as rn
      from sized s
      join public.attendances them
        on them.event_id = s.event_id
       and them.user_id <> p_viewer
       and them.status = any (public.presence_statuses())
  )
  select peer, sum(w)::real
    from shared
   where rn <= 5                  -- cap per pair
   group by peer
  having count(*) >= 2            -- a pair needs two shared events
$$;

revoke all on function public.viewer_circle(uuid) from public;
-- internal: the feed calls it. Exposing it directly would let anyone
-- enumerate who a given account keeps running into.


-- ═══════════════════════════════════════════════════════════════════
-- 3. feed_ranked  (defined in section 4d below, with the past window)
--
--   score = tau * (1 + wS*sigma + wP*pi + wD*delta + wA*alpha + wF*phi)
--
-- tau  TIME, and it MULTIPLIES rather than adds. exp(-hours/72). This
--      is the one term that must never be outvoted: nothing should
--      outrank tonight by being popular. An event already running gets
--      the full 1.0.
--
-- sigma SOCIAL. Summed affinity of your circle who are going, over 3.
--      The dominant additive term.
--
-- pi   POPULARITY, normalised against the MAX IN THIS RESULT SET
--      rather than an absolute number. So it means "busy for around
--      here" — a 40-person night in Ericeira scores like a 400-person
--      one in Lisbon, instead of small communities permanently
--      reading as dead. Deliberately the weakest weight: popularity
--      is the signal that most easily becomes a feedback loop.
--
-- delta PROXIMITY. 1 - dist/radius. This was free the whole time —
--      feed_near already computed distance_km, returned it, and
--      nothing ever used it for anything.
--
-- alpha AFFINITY with the place and the person. Have you been to this
--      venue before, or to something this host put on.
--
-- phi  FRESHNESS. A decaying boost over the first 48 hours after
--      publish. Without it ranking is rich-get-richer: an event with
--      no attendees never surfaces, so it never gets attendees, and in
--      a small community that kills it outright. phi is what gives
--      every new event a window in which to be seen.
--
-- ── CONFIDENCE, instead of cold-start branches ────────────────────
--
-- The baseline gates the social signal behind three hard cliffs
-- (< 2 attended -> null, < 10 going -> null, < 3 circle -> 0), and
-- those cliffs are exactly why the feature feels dead: on a young
-- database every one of them is tripped, permanently.
--
-- Weights are scaled by how much the data can support instead:
--
--     conf_social = least(1, my_presence_count / 5)
--     conf_pop    = least(1, candidates_in_scope / 20)
--
-- so it degrades smoothly and nobody ever sees the feed reorder itself
-- as a threshold is crossed:
--
--   new user, empty community -> both ~0, score collapses to
--     tau * (1 + wD*delta): chronological, nearest first, which is
--     the right answer and roughly what the app does today
--   busy community, new user  -> popularity and proximity carry it,
--     social stays quiet until it has something to say
--   established user          -> social leads
-- ═══════════════════════════════════════════════════════════════════




-- ═══════════════════════════════════════════════════════════════════
-- 4. Indexes
--
-- viewer_circle walks attendances twice by user and once by event.
-- Partial on the two statuses that count, because cancelled rows are
-- never read by any of this.
-- ═══════════════════════════════════════════════════════════════════

create index if not exists attendances_presence_user_idx
  on public.attendances (user_id, event_id)
  where status in ('going','attended');

create index if not exists attendances_presence_event_idx
  on public.attendances (event_id, user_id)
  where status in ('going','attended');

create index if not exists events_live_starts_idx
  on public.events (starts_at)
  where status = 'live';


-- ═══════════════════════════════════════════════════════════════════
-- 4d. RECENTLY FINISHED EVENTS  (was patch 37)
-- ═══════════════════════════════════════════════════════════════════



-- ═══════════════════════════════════════════════════════════════════
-- WHY THIS IS A SERVER CHANGE AND NOT A CLIENT ONE
--
-- The client already had a "keep finished events on the map" filter.
-- It could never fire, because no feed has ever returned a finished
-- event:
--
--     feed()        where e.starts_at >= from_ts   -- default now()
--     feed_near()   where e.starts_at >= from_ts
--     feed_ranked() where e.starts_at >= from_ts
--
-- events_public itself has NO date filter — it is `where status =
-- 'live'` and nothing else — so the rows were sitting there the whole
-- time, visible to a direct read and invisible to every feed. Measured
-- on a seeded database: 4 finished events present in events_public, 0
-- returned by feed_ranked or feed_near.
--
-- So the map filter was correct and starved. Widening the window here
-- is what actually puts the events on the map.
--
-- THEY MUST NOT LEAK INTO THE LISTS. A finished event in "coming up"
-- is just wrong, and bundleFor() would put it there, because its
-- fallback bucket is 'personal'. The is_past flag below exists so the
-- client can put these on the map and keep them out of the feed with
-- one test rather than by re-deriving the rule in two places.
-- ═══════════════════════════════════════════════════════════════════

/* Adding a parameter creates an OVERLOAD rather than replacing the
   function, and two candidates of the same name is exactly the
   ambiguity PostgREST cannot resolve. Drop, then create. */
drop function if exists public.feed_ranked(
  uuid, double precision, double precision, double precision, text,
  timestamptz, integer, real, real, real, real, real, real);

create or replace function public.feed_ranked(
  viewer       uuid             default null,
  near_lat     double precision default null,
  near_lng     double precision default null,
  radius_km    double precision default 25,
  community    text             default null,
  from_ts      timestamptz      default now(),
  max_results  integer          default 60,
  w_social     real             default 1.0,
  w_pop        real             default 0.4,
  w_near       real             default 0.6,
  w_affinity   real             default 0.5,
  w_fresh      real             default 0.3,
  decay_hours  real             default 72.0,
  /* How long a finished event stays visible. For the map: somebody
     opening it to work out what has been going on in the community
     benefits from seeing last night as well as tonight.

     36 hours, so at any moment it covers "yesterday evening and
     today". Set to 0 to switch the behaviour off entirely and get
     exactly the pre-patch result set. */
  past_hours   real             default 36.0
)
returns table (
  id uuid, short_id text, title text, description text,
  venue_name text, venue_lat double precision, venue_lng double precision,
  city text, community_slug text,
  starts_at timestamptz, ends_at timestamptz, recurrence text,
  price_value integer, price_currency text, capacity integer, contact text,
  cover_url text, going_count bigint, circle_count integer,
  distance_km double precision,
  score real,
  is_past boolean
)
language sql stable
security definer
set search_path = public
as $$
  with circle as (
    select c.peer_id, c.affinity
      from public.viewer_circle(viewer) c
     where viewer is not null
  ),
  my_history as (
    select count(*)::integer as presence_count
      from public.attendances a
     where viewer is not null
       and a.user_id = viewer
       and a.status = any (public.presence_statuses())
  ),
  my_venues as (
    select distinct e.venue_id
      from public.attendances a
      join public.events e on e.id = a.event_id
     where viewer is not null and a.user_id = viewer
       and a.status = any (public.presence_statuses())
       and e.venue_id is not null
  ),
  my_hosts as (
    select distinct e.host_id
      from public.attendances a
      join public.events e on e.id = a.event_id
     where viewer is not null and a.user_id = viewer
       and a.status = any (public.presence_statuses())
       and e.host_id is not null
  ),
  box as (
    select
      near_lat - (radius_km / 111.0) as min_lat,
      near_lat + (radius_km / 111.0) as max_lat,
      near_lng - (radius_km / (111.0 * greatest(cos(radians(near_lat)), 0.01))) as min_lng,
      near_lng + (radius_km / (111.0 * greatest(cos(radians(near_lat)), 0.01))) as max_lng
  ),
  candidates as (
    select e.*,
           /* One definition of "over", used by the window test, the
              flag and the ranking. Without a finish time, three hours,
              which matches promote_attendance's own assumption. */
           coalesce(e.ends_at, e.starts_at + interval '3 hours') as fin,
           case when near_lat is null or e.venue_lat is null then null
           else 6371 * acos(least(1, greatest(-1,
                  sin(radians(near_lat)) * sin(radians(e.venue_lat)) +
                  cos(radians(near_lat)) * cos(radians(e.venue_lat)) *
                  cos(radians(e.venue_lng - near_lng))
                ))) end as dist
      from public.events e, box
     where e.status = 'live'
       and (
         e.starts_at >= from_ts
         /* or it finished recently enough to still be worth seeing */
         or (coalesce(past_hours, 0) > 0
             and coalesce(e.ends_at, e.starts_at + interval '3 hours')
                 >= now() - make_interval(mins => (past_hours * 60)::integer)
             and coalesce(e.ends_at, e.starts_at + interval '3 hours') < now())
       )
       and (
         near_lat is null
         or (e.venue_lat between box.min_lat and box.max_lat
             and e.venue_lng between box.min_lng and box.max_lng)
         or (community is not null and e.community_slug = community)
       )
  ),
  trimmed as (
    select c.* from candidates c
     where near_lat is null
        or c.dist is null
        or c.dist <= radius_km
        or (community is not null and c.community_slug = community)
  ),
  counted as (
    select t.*,
           coalesce(g.n, 0) as going_n,
           coalesce(cc.aff, 0)::real as circle_aff,
           coalesce(cc.people, 0)::integer as circle_people
      from trimmed t
      left join (
        select a.event_id, count(*) as n
          from public.attendances a
         where a.status = any (public.presence_statuses())
         group by a.event_id
      ) g on g.event_id = t.id
      left join (
        select a.event_id,
               sum(ci.affinity)::real as aff,
               count(*)              as people
          from public.attendances a
          join circle ci on ci.peer_id = a.user_id
         where a.status = any (public.presence_statuses())
         group by a.event_id
      ) cc on cc.event_id = t.id
  ),
  scoped as (
    select c.*,
           (c.fin < now()) as over_now,
           max(c.going_n) over ()   as max_going,
           count(*)      over ()    as n_scope
      from counted c
  ),
  scored as (
    select s.*,
           (
             /* tau. An event that has already finished decays from the
                moment it ENDED rather than from its start, and over
                past_hours rather than decay_hours — it is on borrowed
                time and should fade over exactly the window it was
                granted. It can never outrank a live one regardless:
                the ORDER BY sorts on over_now first. */
             case when s.over_now then
               exp( - greatest(0, extract(epoch from (now() - s.fin)) / 3600.0)
                    / greatest(coalesce(past_hours, 36.0), 1.0) )
             else
               exp( - greatest(0, extract(epoch from (s.starts_at - now())) / 3600.0)
                    / greatest(coalesce(decay_hours, 72.0), 1.0) )
             end
             * (
               1.0
               + w_social
                 * least(1.0, (select presence_count from my_history) / 5.0)
                 * least(1.0, s.circle_aff / 3.0)
               + w_pop
                 * least(1.0, s.n_scope / 20.0)
                 * (ln(1 + s.going_n) / greatest(ln(1 + s.max_going), 1e-6))
               + w_near
                 * case when s.dist is null or radius_km is null or radius_km <= 0
                        then 0
                        else 1.0 - least(1.0, s.dist / radius_km) end
               + w_affinity * (
                   case when s.venue_id is not null
                         and exists (select 1 from my_venues v where v.venue_id = s.venue_id)
                        then 0.5 else 0 end
                 + case when s.host_id is not null
                         and exists (select 1 from my_hosts h where h.host_id = s.host_id)
                        then 0.5 else 0 end)
               /* No freshness boost for something already over. The
                  point of phi is to give a new event a window in which
                  to be discovered; that window has closed. */
               + case when s.over_now then 0 else
                   w_fresh
                   * exp( - greatest(0, extract(epoch from (now() - s.created_at)) / 3600.0) / 48.0 )
                 end
             )
           )::real as rank_score
      from scoped s
  )
  select r.id, r.short_id, r.title, r.description,
         r.venue_name, r.venue_lat, r.venue_lng,
         r.city, r.community_slug,
         r.starts_at, r.ends_at, r.recurrence,
         r.price_value, r.price_currency, r.capacity, r.contact,
         r.cover_url,
         r.going_n::bigint,
         case when viewer is null then null else r.circle_people end,
         r.dist,
         r.rank_score,
         r.over_now
    from scored r
   /* over_now first, unconditionally. Whatever the weights are tuned
      to, something that has already happened sorts below everything
      that has not. */
   order by r.over_now asc, r.rank_score desc, r.starts_at asc
   limit greatest(1, least(coalesce(max_results, 60), 200));
$$;

revoke all on function public.feed_ranked(
  uuid, double precision, double precision, double precision, text,
  timestamptz, integer, real, real, real, real, real, real, real) from public;
grant execute on function public.feed_ranked(
  uuid, double precision, double precision, double precision, text,
  timestamptz, integer, real, real, real, real, real, real, real) to anon;


/* The recently-finished window reaches events by their END, so the
   live-events index on starts_at alone no longer covers the lookup. */
create index if not exists events_live_ends_idx
  on public.events (ends_at, starts_at)
  where status = 'live';


-- ═══════════════════════════════════════════════════════════════════
-- 4e. NAME FIRST PINS  (was patch 38)
-- ═══════════════════════════════════════════════════════════════════



-- ═══════════════════════════════════════════════════════════════════
-- WHY
--
-- The existing canonicalisation pipeline is COORDINATE anchored. It
-- asks "what is near this point and spelled like this" — the Overpass
-- query is around:300,lat,lng — so a venue with no point cannot enter
-- it at all:
--
--   · ensureVenue() returns null before calling anything when lat is
--     null, and ensure_venue() would refuse it anyway: "those
--     coordinates are not on earth"
--   · so no venues row is created, and events.venue_id stays null
--   · venues_needing_review() selects `where v.lat is not null`, so
--     nothing is queued
--   · apply_venue_match() updates `where e.venue_id = p_venue`, which
--     matches nothing
--
-- Result: an event published with a venue name and no pin never gets
-- coordinates, never appears on the map, and never gets a maps link.
-- Permanently. Measured on a seeded database: 0 rows queued, 0 venues
-- created.
--
-- That was defensible while every event had a pin. It stopped being
-- defensible when the mini map picker turned out to have no height and
-- silently accepted no taps, which put EVERY event published so far
-- into exactly this state.
--
-- This adds the other lookup: "where is this name, in this town".
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. remember what has been tried ────────────────────────────────
-- Without this the queue returns the same unfindable venue every ten
-- minutes forever. Nullable and with no default, so adding it rewrites
-- no rows.

alter table public.events
  add column if not exists pin_checked_at timestamptz;

create index if not exists events_pinless_idx
  on public.events (pin_checked_at)
  where status = 'live' and venue_lat is null;


-- ── 2. the queue ───────────────────────────────────────────────────

/* Dropped first. `create or replace` cannot change a return type —
   it fails with "cannot change return type of existing function" — so
   without this, re-running the file after any change to the returns
   table leaves the OLD definition in place and every later statement
   appears to work while the queue quietly does not. */
drop function if exists public.events_needing_pin(text, integer);

create function public.events_needing_pin(
  p_secret text,
  p_limit  integer default 10
)
returns table (
  short_id      text,
  venue_name    text,
  city          text,
  community     text,
  centre_lat    double precision,
  centre_lng    double precision,
  /* integer, matching the column. Declaring it double precision made
     the RETURN QUERY fail outright with "structure of query does not
     match function result type" — plpgsql does not widen for you. */
  radius_km     integer
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_worker(p_secret) then
    raise exception 'not the worker' using errcode = '42501';
  end if;

  return query
    select e.short_id, e.venue_name, e.city,
           c.slug, c.centre_lat, c.centre_lng, c.radius_km
      from public.events e
      join public.communities c on c.slug = e.community_slug
     where e.status = 'live'
       and e.venue_lat is null
       and coalesce(btrim(e.venue_name), '') <> ''
       /* A community is the anchor. Without one there is no town to
          search in, and a bare name geocoded against the whole planet
          is how you pin a Lisbon gig to a same-named bar in Brazil. */
       and c.centre_lat is not null
       /* Not tried in the last 7 days. A place Nominatim does not know
          today may exist next week — OSM is edited constantly — but
          retrying every ten minutes forever is just noise. */
       and (e.pin_checked_at is null
            or e.pin_checked_at < now() - interval '7 days')
       /* Skip events already over: a pin cannot help somebody attend
          something that has finished. */
       and e.starts_at > now() - interval '1 day'
     order by e.pin_checked_at asc nulls first, e.starts_at asc
     limit greatest(1, least(coalesce(p_limit, 10), 50));
end $$;

revoke all on function public.events_needing_pin(text, integer) from public;
grant execute on function public.events_needing_pin(text, integer) to anon;


-- ── 3. apply a match ───────────────────────────────────────────────
--
-- The worker proposes; this decides. Both tests are recomputed HERE
-- rather than trusted from the caller, exactly as apply_venue_match
-- recomputes its own distance:
--
--   SIMILARITY — the found name must actually look like the typed one.
--     pg_trgm is already installed and is the right tool: it compares
--     trigrams, so "Bar Central" against "Bar Central Ericeira" scores
--     well while "Bar Central" against "Cafe Luna" does not.
--
--   INSIDE THE TOWN — the found point must sit within the community's
--     own radius. That is what "in the same town or city" means here,
--     and it scales properly: a town allows 15km, an island 60.
--
-- A pin that is wrong is worse than no pin, because a wrong one is
-- believed and navigated to. When either test fails the event is
-- stamped as checked and left pinless.

create or replace function public.apply_event_pin(
  p_secret   text,
  p_short_id text,
  p_match    jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_event  public.events;
  v_name   text;
  v_lat    double precision;
  v_lng    double precision;
  v_km     double precision;
  v_sim    real;
  v_slug   text;
  v_c      public.communities;
  v_venue  uuid;
begin
  if not public.is_worker(p_secret) then
    raise exception 'not the worker' using errcode = '42501';
  end if;

  select * into v_event from public.events where short_id = p_short_id;
  if not found then return 'no such event'; end if;

  /* Somebody may have dropped a pin themselves while this was in
     flight. Theirs wins, always. */
  if v_event.venue_lat is not null then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    return 'already pinned';
  end if;

  -- nothing found: remember that we looked
  if p_match is null or p_match = 'null'::jsonb or (p_match->>'lat') is null then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    return 'none';
  end if;

  v_name := btrim(coalesce(p_match->>'name', ''));
  v_lat  := (nullif(p_match->>'lat', ''))::double precision;
  v_lng  := (nullif(p_match->>'lng', ''))::double precision;

  if v_name = '' or v_lat is null or v_lng is null
     or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    return 'invalid';
  end if;

  select * into v_c from public.communities where slug = v_event.community_slug;
  if not found or v_c.centre_lat is null then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    return 'no community';
  end if;

  -- inside the town? haversine, not the flat approximation — at 60km
  -- the flat one is off by enough to matter.
  v_km := 6371 * acos(least(1, greatest(-1,
            sin(radians(v_c.centre_lat)) * sin(radians(v_lat)) +
            cos(radians(v_c.centre_lat)) * cos(radians(v_lat)) *
            cos(radians(v_lng - v_c.centre_lng)))));

  if v_km > coalesce(v_c.radius_km, 25) then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    /* format() has no %.1f — that is printf, not this. round() to a
       numeric first and let %s print it. */
    return format('outside %s (%skm)', v_c.slug, round(v_km::numeric, 1));
  end if;

  /* Name similarity. Compared lower case and unaccented so "Café" and
     "Cafe" are the same word, which they are.

     0.35 rather than something higher because the real world adds
     words: OSM holds "Bar Central Ericeira" where the flyer said "Bar
     Central", and a strict threshold rejects the correct answer.
     Combined with the radius test above, a wrong place has to be both
     similarly named AND in the same town, which is a much narrower
     opening than either alone. */
  v_sim := similarity(
    lower(public.unaccent_lite(v_event.venue_name)),
    lower(public.unaccent_lite(v_name)));

  if v_sim < 0.35 then
    update public.events set pin_checked_at = now() where short_id = p_short_id;
    return format('name mismatch (%s: %s vs %s)',
                  round(v_sim::numeric, 2), v_event.venue_name, v_name);
  end if;

  /* Accepted. Create the venue row too, so this place joins the
     EXISTING 300m canonicalisation from now on — the whole point is to
     get these events out of the name-only limbo, not to give them a
     pin and leave them outside the pipeline. */
  begin
    /* Look before writing. venues has unique(source, source_id) and
       source_id is null here, and Postgres permits unlimited nulls in a
       unique constraint — so without this lookup every event resolving
       to the same place minted its own venue row. Four events off one
       flyer produced four "Bar Central"s, each with one observation and
       therefore each stuck at the confidence floor, when they should
       have been one venue with four.

       Same test as ensure_venue() and link_event_venue(): same name
       within about 300m. Three paths can create a venue and they must
       agree on what counts as the same one. */
    select v.id into v_venue
      from public.venues v
     where lower(v.name) = lower(v_name)
       and v.lat is not null
       and abs(v.lat - v_lat) < 0.003
       and abs(v.lng - v_lng) < 0.003
     limit 1;

    if v_venue is null then
      insert into public.venues (name, lat, lng, city, community_slug, source, use_count)
      values (v_name, v_lat, v_lng, coalesce(v_event.city, v_c.name),
              /* 'geocode', not 'manual'. Nobody stood here and placed
                 this: it came from the gazetteer or from Nominatim, by
                 name. Calling it 'manual' put a claim in the data that
                 was simply untrue, and venues_needing_review() reads
                 this column to decide what still needs checking. It
                 stays <> 'osm', so Overpass will still look at it. */
              v_c.slug, 'geocode', 0)
      returning id into v_venue;
    end if;
  exception when others then
    v_venue := null;      -- a venue is a bonus; the pin is the point
  end;

  update public.events
     set venue_lat  = v_lat,
         venue_lng  = v_lng,
         venue_name = v_name,
         venue_id   = coalesce(v_venue, venue_id),
         /* 'venue' means the pin came from the venue rather than from a
            person or a photo, which is exactly what apply_venue_match
            requires before it will ever move a pin again. A hand placed
            pin stays untouchable; this one stays correctable. */
         pin_source = 'venue',
         pin_checked_at = now()
   where short_id = p_short_id;

  return format('pinned (sim %s, %skm)',
                round(v_sim::numeric, 2), round(v_km::numeric, 1));
end $$;

revoke all on function public.apply_event_pin(text, text, jsonb) from public;
grant execute on function public.apply_event_pin(text, text, jsonb) to anon;


/* Accents off, cheaply. The unaccent extension is not installed on
   this project and needs superuser, so this covers the letters that
   actually appear in venue names around here. */
create or replace function public.unaccent_lite(p text)
returns text language sql immutable parallel safe as $$
  select translate(coalesce(p, ''),
    'áàâãäåéèêëíìîïóòôõöúùûüçñýÁÀÂÃÄÅÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑÝ',
    'aaaaaaeeeeiiiiooooouuuucnyAAAAAAEEEEIIIIOOOOOUUUUCNY')
$$;

-- ═══════════════════════════════════════════════════════════════════
-- 4f. VENUE GAZETTEER  (was patch 39)
--
-- venues held ONE position, last write wins, so the fiftieth person to
-- publish somewhere taught it nothing. Positions are now a consensus
-- over separate observations, weighted by what each kind of evidence
-- is worth, damped per reporter, and decayed with age.
-- ═══════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════
-- THE IDEA
--
-- venues holds ONE position per venue, last write wins. So the fiftieth
-- person to publish at a place teaches it nothing, and a single bad pin
-- overwrites fifty good ones with no trace.
--
-- Separate the OBSERVATIONS from the VENUE. Every publish is somebody
-- saying "I think this place is here". The venue's coordinates become a
-- consensus over those statements, weighted by how much each one is
-- worth, and it converges as the town uses the app.
--
-- No third party required and no per-lookup cost: the data is produced
-- as a side effect of people using it for something else.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. observations ────────────────────────────────────────────────

create table if not exists public.venue_observations (
  id          uuid primary key default extensions.gen_random_uuid(),
  venue_id    uuid not null references public.venues(id) on delete cascade,
  user_id     uuid references public.users(id) on delete set null,
  event_id    uuid references public.events(id) on delete set null,
  name_seen   text,
  lat         double precision not null,
  lng         double precision not null,
  source      text not null,
  created_at  timestamptz not null default now(),
  constraint venue_obs_latlng_check
    check (lat between -90 and 90 and lng between -180 and 180),
  /* Null Island again. A zeroed GPS writes 0,0 and it is a real
     coordinate in the Gulf of Guinea; one of those in the pool drags
     the consensus into the ocean. */
  constraint venue_obs_not_null_island_check
    check (abs(lat) > 0.0001 or abs(lng) > 0.0001),
  constraint venue_obs_source_check check (source in
    ('printed_coords','manual_pin','osm_match','geocode','exif')),
  /* One observation per event per venue. A person editing an event
     five times is still one opinion about where it is.

     NULLS NOT DISTINCT because event_id is nullable and Postgres
     otherwise treats every NULL as unique — so the rule this constraint
     exists to state had a hole in it exactly where an observation
     carries no event. */
  constraint venue_obs_event_uniq unique nulls not distinct (venue_id, event_id)
);

/* Tighten the constraint on a database that already carries the loose
   version — `create table if not exists` above does nothing when the
   table is already there. Guarded, because ADD CONSTRAINT fails if
   duplicates already exist, and rolling the whole schema back over a
   handful of rows nobody has ever written would be absurd. */
do $obsuniq$
declare dupes integer;
begin
  select count(*) into dupes from (
    select venue_id from public.venue_observations
     where event_id is null group by venue_id having count(*) > 1) d;
  if dupes > 0 then
    raise notice '[bich] % venue(s) carry duplicate event-less observations; leaving venue_obs_event_uniq loose. Clean them, then re-run.', dupes;
  else
    alter table public.venue_observations drop constraint if exists venue_obs_event_uniq;
    alter table public.venue_observations
      add constraint venue_obs_event_uniq unique nulls not distinct (venue_id, event_id);
  end if;
end $obsuniq$;

create index if not exists venue_obs_venue_idx on public.venue_observations (venue_id);
create index if not exists venue_obs_user_idx  on public.venue_observations (venue_id, user_id);

alter table public.venue_observations enable row level security;
-- no policies: reachable only through the SECURITY DEFINER functions below

alter table public.venues
  add column if not exists confidence        real    not null default 0,
  add column if not exists spread_m          real,
  add column if not exists observation_count integer not null default 0,
  add column if not exists distinct_reporters integer not null default 0;

alter table public.events
  add column if not exists pin_confidence real not null default 0;


-- ── 2. what each kind of evidence is worth ─────────────────────────
--
-- NOTE what is absent: a pin somebody got by PICKING an existing venue
-- from the suggestion list. That pin IS the venue's current position,
-- so recording it would feed the estimate back into itself — the
-- position stops moving and any early error becomes self confirming and
-- permanent. It must never be recorded, which is why there is no
-- 'picked_existing' value in the source check above.

create or replace function public.observation_weight(p_source text)
returns real language sql immutable parallel safe as $$
  select case p_source
    when 'printed_coords' then 1.0    -- the flyer states it
    when 'manual_pin'     then 0.9    -- somebody stood there and placed it
    when 'osm_match'      then 0.8    -- the 300m sweep agreed
    when 'geocode'        then 0.5    -- nominatim, by name
    when 'exif'           then 0.3    -- where the PHOTO was, not the event
    else 0.0
  end::real
$$;


/* Age. Venues relocate, and without this a bar that moved two years ago
   stays anchored by the observations at its old address — they
   outnumber the new ones for as long as it takes the town to notice.

   NINETY DAYS AT FULL WEIGHT, then exponential decay on a 180 DAY TIME
   CONSTANT. Note that is not a 180 day half life: 180 is the e-folding
   time, the divisor inside exp(), and halving takes ln(2) x 180 ~ 125
   days. The table below used to read 0.50 / 0.25 / 0.09, which is the
   curve you get if you assume it halves every 180 days. It does not.
       today .. 90d   1.00
       180d           0.61
       270d           0.37
       450d           0.14
       2 years        0.03
   The 0.02 floor is reached at about day 794.
   Nothing is ever deleted. A dormant venue simply becomes less certain,
   which is true — and if it reopens, a handful of fresh observations
   at full weight outvote a decade of faded ones immediately.

   That is also what makes a relocation self correcting: the new address
   accumulates full weight observations while the old one fades, and the
   consensus crosses over without anybody filing a correction. */
create or replace function public.age_factor(p_created timestamptz)
returns real language sql immutable parallel safe as $$
  select greatest(0.02, exp(- greatest(0.0,
           extract(epoch from (now() - p_created)) / 86400.0 - 90.0) / 180.0
         ))::real
$$;


-- ── 3. the consensus ───────────────────────────────────────────────
--
-- Three steps, and the order is the point:
--
--   1. WEIGHTED MEDIAN of lat and lng, independently. A mean would be
--      dragged anywhere by one wrong pin; a median finds where the
--      cluster actually is. At venue scale lat/lng are effectively
--      planar, so per axis is fine and far cheaper than a geometric
--      median.
--
--   2. REJECT OUTLIERS beyond max(50m, 3 x MAD) of that median. MAD
--      rather than a fixed radius because it adapts: a venue whose
--      observations agree within 20m gets a tight gate, one that is
--      genuinely spread out gets a loose one, and neither needs tuning.
--
--   3. WEIGHTED MEAN of the survivors. The median found the right
--      cluster; the mean extracts the precision from inside it.
--
-- PER REPORTER DAMPING. A host publishing twenty events at their own
-- bar is ONE opinion, not twenty. Effective weight is divided by the
-- square root of that reporter's own observation count for the venue,
-- so twenty becomes about four and a half. Independent agreement
-- outweighs repetition — the same reasoning as the Adamic-Adar
-- weighting in the feed ranking.

create or replace function public.recompute_venue(p_venue uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lat double precision; v_lng double precision;
  v_conf real; v_spread double precision;
  v_n integer; v_people integer; v_name text;
begin
  /* One statement, chained CTEs. An earlier version staged this in a
     temp table, which logged "relation _obs already exists" on every
     call after the first within a transaction and left correctness
     resting on remembering to DELETE from it first. CTEs cannot leak
     between calls at all. */
  with obs as (
    select o.lat, o.lng, o.name_seen, o.user_id,
           public.observation_weight(o.source)
             * public.age_factor(o.created_at)
             / sqrt(greatest(1, count(*) over (partition by o.user_id))) as w
      from public.venue_observations o
     where o.venue_id = p_venue
       and public.observation_weight(o.source) > 0
  ),
  med as (
    select
      (select lat from (select lat, sum(w) over (order by lat rows unbounded preceding) cw,
                               sum(w) over () tw from obs) t
        where cw >= tw/2 order by cw limit 1) as mlat,
      (select lng from (select lng, sum(w) over (order by lng rows unbounded preceding) cw,
                               sum(w) over () tw from obs) t
        where cw >= tw/2 order by cw limit 1) as mlng
  ),
  dist as (
    select o.*, 111320.0 * sqrt(power(o.lat - m.mlat, 2) +
                power((o.lng - m.mlng) * cos(radians(m.mlat)), 2)) as d,
           m.mlat, m.mlng
      from obs o, med m
  ),
  mad as (
    select percentile_cont(0.5) within group (order by d) as mad_m from dist
  ),
  kept as (
    select d.* from dist d, mad
     where d.d <= greatest(50.0, 3.0 * coalesce(mad.mad_m, 0))
  )
  select
    coalesce((select sum(lat*w)/nullif(sum(w),0) from kept), (select mlat from med)),
    coalesce((select sum(lng*w)/nullif(sum(w),0) from kept), (select mlng from med)),
    (select count(*) from obs),
    (select coalesce(mad_m, 0) from mad),
    (select name_seen from (select name_seen, sum(w) tot from obs
       where coalesce(btrim(name_seen),'') <> '' group by name_seen) t
      order by tot desc limit 1)
  into v_lat, v_lng, v_n, v_spread, v_name;

  if coalesce(v_n, 0) = 0 then
    update public.venues
       set confidence = 0, observation_count = 0, distinct_reporters = 0
     where id = p_venue;
    return;
  end if;

  select count(distinct o.user_id) into v_people
    from public.venue_observations o
   where o.venue_id = p_venue and o.user_id is not null;

  /* Confidence, and every part has to be earned:
       · three INDEPENDENT reporters for full marks on that term,
         because one person agreeing with themselves is not agreement
       · tight agreement: 120m is the scale over which spread stops
         being reassuring
       · a floor of 0.15 so a lone observation still beats nothing,
         which is what the resolution layer compares against */
  v_conf := least(1.0, greatest(coalesce(v_people,0), 1) / 3.0)
          * exp(- coalesce(v_spread, 0) / 120.0);
  v_conf := greatest(0.15, least(0.95, v_conf));

  update public.venues v
     set lat = v_lat, lng = v_lng,
         /* the name converges too, unless OSM has confirmed one */
         name = case when v.match_status = 'matched' then v.name
                     else coalesce(v_name, v.name) end,
         confidence = v_conf,
         spread_m = v_spread::real,
         observation_count = v_n,
         distinct_reporters = coalesce(v_people, 0)
   where v.id = p_venue;
end $$;

revoke all on function public.recompute_venue(uuid) from public;


-- ── 3b. push a settled position out to the SIBLING events ──────────
--
-- Case A above fixes the ONE event somebody corrected. This is what
-- reaches the other three: the same venue name, the same community, no
-- pin of their own.
--
-- Name matching rather than venue_id, precisely because the events
-- this is for have no venue_id — that is the whole problem. 0.45 is
-- the same floor resolve_venue_coords() uses for "the same place at
-- all", so the two layers cannot disagree.

create or replace function public.adopt_pinless_events(p_venue uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v public.venues;
  v_n integer := 0;
begin
  select * into v from public.venues where id = p_venue;
  /* confidence > 0 means at least one observation exists. A venue row
     with no observations has no position worth handing anybody. */
  if not found or v.lat is null or coalesce(v.confidence, 0) <= 0 then
    return 0;
  end if;

  with target as (
    select e.id
      from public.events e
     where e.status = 'live'
       and e.venue_lat is null          -- never touch a pin somebody placed
       and e.venue_id is null
       and e.community_slug is not distinct from v.community_slug
       and coalesce(btrim(e.venue_name), '') <> ''
       and similarity(lower(public.unaccent_lite(e.venue_name)),
                      lower(public.unaccent_lite(v.name))) >= 0.45
     /* Bounded. This runs inside a trigger, and a venue with a
        thousand pinless events must not turn one publish into a table
        scan. Anything past the cap is picked up by the /events/pin
        sweep, which is what it is for. */
     limit 200
  ), moved as (
    update public.events e
       set venue_lat      = v.lat,
           venue_lng      = v.lng,
           venue_id       = v.id,
           pin_source     = 'venue',
           pin_confidence = v.confidence,
           pin_checked_at = now()
      from target t
     where e.id = t.id
    returning 1
  )
  select count(*) into v_n from moved;

  return v_n;
end $$;

revoke all on function public.adopt_pinless_events(uuid) from public;


-- ── 4. record one ──────────────────────────────────────────────────

create or replace function public.record_venue_observation(
  p_venue uuid, p_user uuid, p_event uuid,
  p_name text, p_lat double precision, p_lng double precision,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_venue is null or p_lat is null or p_lng is null then return; end if;
  if public.observation_weight(p_source) <= 0 then return; end if;
  if abs(p_lat) < 0.0001 and abs(p_lng) < 0.0001 then return; end if;

  insert into public.venue_observations
    (venue_id, user_id, event_id, name_seen, lat, lng, source)
  values (p_venue, p_user, p_event, nullif(btrim(coalesce(p_name,'')),''),
          p_lat, p_lng, p_source)
  /* An edit is the same opinion restated, not a new one — but it is a
     BETTER statement of it, so let it replace the earlier row rather
     than being dropped. */
  on conflict (venue_id, event_id) do update
    set lat = excluded.lat, lng = excluded.lng,
        source = excluded.source, name_seen = excluded.name_seen,
        created_at = now();

  perform public.recompute_venue(p_venue);
  /* And push the improved answer back out to the events that use this
     venue. Deliberately AFTER the recompute, so an event is only ever
     moved to a position the new observation has already been folded
     into. */
  perform public.recalibrate_venue_events(p_venue);
  /* Then the events that never had a venue_id to be found BY — the
     other three off the same flyer, matched on the venue name instead.
     Without this line, correcting one event corrects one event. */
  perform public.adopt_pinless_events(p_venue);
end $$;

revoke all on function public.record_venue_observation(uuid,uuid,uuid,text,double precision,double precision,text) from public;


-- ── 4b. RECALIBRATION ──────────────────────────────────────────────
--
-- The consensus reaches back and corrects the events that fed it.
--
-- This reverses the old rule that a hand placed pin was untouchable.
-- It was never a claim that the host is infallible, only that we had
-- nothing better to compare against. Now we do: a venue five locals
-- have independently agreed on IS better evidence than one person
-- tapping a map once, possibly in a hurry, possibly on the wrong side
-- of the street.
--
-- The important part is that this is NOT an override. The manual pin
-- was recorded as an observation at weight 0.9, so it is inside the
-- consensus, pulling it. If everyone else agrees with that host, the
-- consensus sits on their pin and nothing moves. It only moves when
-- the weight of independent evidence genuinely points elsewhere — the
-- host is outvoted, not overruled.
--
-- THE CONFIDENCE LADDER, which is what decides who wins:
--
--   printed on the flyer   0.85   the flyer states it, but flyers lie
--   VENUE CONSENSUS        0.15 to 0.95, earned
--   manual pin             0.70   one person, one tap
--   nominatim by name      0.50
--   photo exif             0.30
--
-- So a venue with three independent reporters (about 0.94) takes a
-- manual pin. A venue with one observation (0.33) does not, and must
-- not — that would be one stranger's guess replacing the host's.
--
-- The 0.10 margin stops flapping. Without it two sources sitting either
-- side of equal swap the pin back and forth on every sweep, rewriting
-- rows forever and making updated_at meaningless.

create or replace function public.pin_confidence_for(p_source text)
returns real language sql immutable parallel safe as $$
  select case p_source
    when 'extracted' then 0.85   -- coordinates printed on the flyer
    when 'manual'    then 0.70   -- somebody tapped the map
    when 'venue'     then 0.60   -- from a venue, before it had a consensus
    when 'geocode'   then 0.50
    when 'exif'      then 0.30
    else 0.0
  end::real
$$;

create or replace function public.recalibrate_venue_events(p_venue uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v public.venues;
  v_n integer := 0;
begin
  select * into v from public.venues where id = p_venue;
  if not found or v.lat is null then return 0; end if;

  /* Only ever forward: an event is moved when the venue is more certain
     than whatever put the pin there, by a clear margin. coalesce covers
     rows written before pin_confidence existed — they are treated as
     whatever their pin_source is worth. */
  with moved as (
    update public.events e
       set venue_lat = v.lat,
           venue_lng = v.lng,
           venue_id  = coalesce(e.venue_id, p_venue),
           pin_source = 'venue',
           pin_confidence = v.confidence
     where e.venue_id = p_venue
       and e.status = 'live'
       and v.confidence > greatest(
             coalesce(nullif(e.pin_confidence, 0),
                      public.pin_confidence_for(e.pin_source)), 0) + 0.10
       /* Do not rewrite a row to the value it already holds. Without
          this every sweep touches every event and updated_at stops
          meaning anything. */
       and (e.venue_lat is distinct from v.lat
         or e.venue_lng is distinct from v.lng)
    returning 1)
  select count(*) into v_n from moved;

  return v_n;
end $$;

revoke all on function public.recalibrate_venue_events(uuid) from public;
revoke all on function public.pin_confidence_for(text) from public;


-- ── 5. THE RESOLUTION LAYER ────────────────────────────────────────
--
-- The missing middle of the ladder. Before this, an event with a venue
-- name and no pin fell straight past everything the app already knew
-- and out to Nominatim — or nowhere.
--
--   printed on the flyer   0.85
--   manual pin             0.70
--   THIS LAYER             = venue.confidence, 0.15 to 0.95
--   from a venue, no consensus yet
--                          0.60
--   nominatim by name      0.50
--   photo exif             0.30
--
-- Those are pin_confidence_for()'s actual numbers, above. An earlier
-- draft of this block said "manual pin 1.00 locked, printed 0.95
-- locked", which contradicted both the function and the whole argument
-- for recalibration four sections up — the point of that section is
-- precisely that a hand placed pin is NOT locked.
--
-- No network. One indexed query. And it improves on its own: as a
-- venue's confidence rises, matches that were previously too weak start
-- passing, so old pinless events acquire pins with nobody doing
-- anything.
--
-- Note this is deliberately LOOSER than linkKnownVenue, which required
-- name equality — so "Bar Central" never matched the venue stored as
-- "Bar Central Ericeira", which is exactly the spelling OSM returns.

create or replace function public.resolve_venue_coords(
  p_name      text,
  p_community text,
  p_bias_lat  double precision default null,
  p_bias_lng  double precision default null
)
returns table (
  venue_id uuid, lat double precision, lng double precision,
  confidence real, matched_name text
)
language sql stable
security definer
set search_path = public, extensions
as $$
  with cand as (
    select v.id, v.lat, v.lng, v.confidence, v.name,
           similarity(lower(public.unaccent_lite(v.name)),
                      lower(public.unaccent_lite(p_name))) as sim,
           case when p_bias_lat is null or v.lat is null then 1.0
                else 1.0 / (1.0 + (111.32 * sqrt(
                       power(v.lat - p_bias_lat, 2) +
                       power((v.lng - p_bias_lng) * cos(radians(p_bias_lat)), 2)
                     )) / 10.0)
           end as near
      from public.venues v
     where v.lat is not null
       and coalesce(btrim(p_name), '') <> ''
       and (p_community is null or v.community_slug = p_community)
  )
  select id, lat, lng, (confidence * sim * near)::real, name
    from cand
   /* 0.45 on the raw name similarity is the floor for being the same
      place at all; the product below then also demands that the venue
      be settled enough and near enough to be worth using. */
   where sim >= 0.45 and confidence * sim * near >= 0.25
   order by confidence * sim * near desc
   limit 1;
$$;

revoke all on function public.resolve_venue_coords(text,text,double precision,double precision) from public;
grant execute on function public.resolve_venue_coords(text,text,double precision,double precision) to anon;

-- ═══════════════════════════════════════════════════════════════════
-- 4g. FEED THE GAZETTEER  (was patch 40)
--
-- 4f built the machinery and nothing fills it: venues.confidence
-- defaults to 0, resolve_venue_coords needs confidence * sim * near
-- >= 0.25, and zero times anything is zero. This records observations
-- by trigger and backfills from the events already published.
-- ═══════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════
-- 1. Record on publish and on edit
--
-- A trigger rather than edits to publish_event and update_event_as.
-- Those two are the largest functions in the schema and every change
-- to them risks something unrelated; a trigger catches BOTH paths plus
-- anything added later, and cannot be forgotten by a new caller.
--
-- WHAT DOES NOT GET RECORDED, and this is the important part:
--
--   · pin_source 'venue' — that pin CAME from a venue. Recording it
--     would feed the estimate back into itself, the position would stop
--     moving, and any early error would become self confirming and
--     permanent. This is the same rule as the missing
--     'picked_existing' source in patch 39, enforced here at the only
--     place that could break it.
--
--   · anything with no venue_id, since there is no venue to inform.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.observe_event_pin()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_source text;
begin
  if new.venue_id is null or new.venue_lat is null or new.venue_lng is null then
    return new;
  end if;
  if new.status <> 'live' then return new; end if;

  /* Map the event's pin_source onto an observation source. 'venue' is
     absent on purpose — see above. */
  v_source := case new.pin_source
    when 'extracted' then 'printed_coords'
    when 'manual'    then 'manual_pin'
    when 'geocode'   then 'geocode'
    when 'exif'      then 'exif'
    else null
  end;
  if v_source is null then return new; end if;

  /* Only when the pin actually changed. An edit to the title must not
     restamp the observation and reset its age, or nothing would ever
     decay for an event somebody keeps tidying up. */
  if tg_op = 'UPDATE'
     and old.venue_lat is not distinct from new.venue_lat
     and old.venue_lng is not distinct from new.venue_lng
     and old.venue_id  is not distinct from new.venue_id then
    return new;
  end if;

  perform public.record_venue_observation(
    new.venue_id, new.host_id, new.id, new.venue_name,
    new.venue_lat, new.venue_lng, v_source);

  return new;
end $$;

revoke all on function public.observe_event_pin() from public;

drop trigger if exists events_observe_pin on public.events;
create trigger events_observe_pin
  after insert or update of venue_lat, venue_lng, venue_id on public.events
  for each row execute function public.observe_event_pin();


-- ═══════════════════════════════════════════════════════════════════
-- 2. Backfill
--
-- Every event already published with a pin is an observation nobody
-- recorded. Without this the gazetteer starts empty and needs weeks of
-- new events before it can answer anything — with it, it is useful the
-- moment this file finishes.
--
-- Observations are dated from the EVENT, not from now, so the decay
-- curve in patch 39 sees the real age. Backfilling everything as
-- "today" would give a five year old pin the same weight as one placed
-- this morning.
-- ═══════════════════════════════════════════════════════════════════

insert into public.venue_observations
  (venue_id, user_id, event_id, name_seen, lat, lng, source, created_at)
select e.venue_id, e.host_id, e.id, e.venue_name, e.venue_lat, e.venue_lng,
       case e.pin_source
         when 'extracted' then 'printed_coords'
         when 'manual'    then 'manual_pin'
         when 'geocode'   then 'geocode'
         when 'exif'      then 'exif'
         else 'manual_pin'      -- pre-dating pin_source; a person put it there
       end,
       coalesce(e.created_at, now())
  from public.events e
 where e.venue_id is not null
   and e.venue_lat is not null
   and e.venue_lng is not null
   and e.status = 'live'
   /* 'venue' pins are excluded for the same reason the trigger excludes
      them: they came FROM a venue and must not be fed back into it. */
   and coalesce(e.pin_source, 'manual') <> 'venue'
   and not (abs(e.venue_lat) < 0.0001 and abs(e.venue_lng) < 0.0001)
on conflict (venue_id, event_id) do nothing;

-- one recompute per venue touched, rather than one per observation
do $$
declare r record;
begin
  for r in select distinct venue_id from public.venue_observations loop
    perform public.recompute_venue(r.venue_id);
    perform public.recalibrate_venue_events(r.venue_id);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════
-- 4h. A VENUE'S POSITION REACHES ITS OTHER EVENTS  (patch 41)
--
-- The gazetteer in 4f/4g learns a position and hands it to events that
-- arrive LATER. Two things it could not do, and both are the ordinary
-- way somebody uses the app:
--
--   A. Upload four events off one flyer for a venue nobody has pinned
--      yet, then correct the pin on ONE of them. Nothing happened to
--      the other three.
--
--      Because: publishing with a name and no coordinates leaves
--      events.venue_id NULL — ensure_venue() refuses a venue with no
--      position, which is correct. Then the manual correction went in
--      through update_event_as, which writes venue_lat/venue_lng and
--      NOT venue_id. So observe_event_pin() hit its first line,
--      `if new.venue_id is null then return new`, and recorded
--      nothing. No venue row, no observation, an empty gazetteer, and
--      three events that stayed pinless for ever. The correction
--      pinned exactly one event and taught the system nothing.
--
--   B. Upload four events for a venue the database ALREADY knows.
--      Nothing looked. bulkCreate() takes coordinates only when the
--      flyer printed them; it never asks the gazetteer, so all four
--      published pinless and waited for the background sweep to find
--      what was already sitting in the venues table.
--
-- Both are fixed here, and by TRIGGER rather than by editing
-- publish_event or update_event_as — the same reasoning as 4g. Those
-- two are the largest writes in the schema, there are five separate
-- code paths that edit an event, and a trigger catches every one of
-- them plus whatever gets added later.
--
-- THE RULES THIS MUST NOT BREAK, all enforced below:
--   · never overwrite a pin a person placed        (only ever fills a NULL)
--   · a pin taken FROM a venue is marked pin_source='venue', which
--     observe_event_pin() skips — so a venue can never be fed its own
--     estimate back and freeze
--   · venue_lat and venue_lng move together        (events_pin_pair_check)
--   · bounded work: no trigger may walk the whole events table
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. link, or resolve, on the way in ─────────────────────────────
--
-- BEFORE the row lands, so it can fill NEW itself with no second
-- write, and so observe_event_pin() — which is AFTER — sees a
-- venue_id that is already populated.

create or replace function public.link_event_venue()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text := nullif(btrim(coalesce(new.venue_name, '')), '');
  v_id   uuid;
  v_hit  record;
begin
  if new.status is distinct from 'live' or v_name is null then
    return new;
  end if;

  /* CASE A — there is a pin but no venue row behind it.
     This is the manual correction. Find the venue or create it, so the
     pin becomes an observation and the place enters the gazetteer. */
  if new.venue_lat is not null and new.venue_lng is not null
     and new.venue_id is null then

    /* Same dedupe as ensure_venue(): same name within about 300m.
       Identical on purpose — two paths that disagree about what
       counts as "the same place" produce duplicate venues. */
    select v.id into v_id
      from public.venues v
     where lower(v.name) = lower(v_name)
       and v.lat is not null
       and abs(v.lat - new.venue_lat) < 0.003
       and abs(v.lng - new.venue_lng) < 0.003
     limit 1;

    if v_id is null then
      begin
        insert into public.venues (name, lat, lng, city, community_slug, source, use_count)
        values (v_name, new.venue_lat, new.venue_lng,
                new.city, new.community_slug, 'manual', 0)
        returning id into v_id;
      exception when others then
        v_id := null;    -- a venue is a bonus; the person's pin is the point
      end;
    end if;

    new.venue_id := coalesce(v_id, new.venue_id);

    /* A pin with no stated provenance was put there BY HAND, and it
       has to say so or the whole chain stops here.

       The edit sheet sends venue_source='manual' — a different column,
       describing where the venue NAME came from. It never sends
       pin_source. So an event published off a flyer with no printed
       coordinates carries pin_source NULL, kept NULL through the
       correction, and observe_event_pin() maps NULL to no observation
       source and returns without recording anything. The venue row
       above would be created and then never hear about the pin that
       created it.

       publish_event's own client already defaults this to 'manual' for
       the same reason; the edit path simply never did. */
    new.pin_source := coalesce(new.pin_source, 'manual');

    return new;
  end if;

  /* CASE B — no pin, but we may already know where this is.
     Ask the gazetteer by name inside the community. Costs one indexed
     query, no network, and answers at publish time instead of waiting
     for the sweep. */
  if new.venue_lat is null and new.community_slug is not null then
    select * into v_hit
      from public.resolve_venue_coords(v_name, new.community_slug, null, null);

    if found and v_hit.lat is not null then
      new.venue_lat      := v_hit.lat;
      new.venue_lng      := v_hit.lng;
      new.venue_id       := coalesce(new.venue_id, v_hit.venue_id);
      /* 'venue' is what stops the feedback loop, and it is also honest
         in the interface: this pin is the venue's, not a statement
         anybody made about this event. */
      new.pin_source     := 'venue';
      new.pin_confidence := coalesce(v_hit.confidence, 0);
      new.pin_checked_at := now();
    end if;
  end if;

  return new;
end $$;

revoke all on function public.link_event_venue() from public;

drop trigger if exists events_link_venue on public.events;
create trigger events_link_venue
  before insert or update of venue_name, venue_lat, venue_lng, venue_id, community_slug
  on public.events
  for each row execute function public.link_event_venue();





-- ── 2. catch up the events already published ───────────────────────
--
-- Everything above works from the next write onwards. This is the
-- backlog: events sitting pinless right now beside a venue that has
-- had a known position all along. Same tests as adopt_pinless_events,
-- run once, for every venue that has one.

do $adopt$
declare r record; n integer; total integer := 0;
begin
  for r in select id from public.venues
            where lat is not null and coalesce(confidence, 0) > 0
  loop
    n := public.adopt_pinless_events(r.id);
    total := total + coalesce(n, 0);
  end loop;
  raise notice '[bich] adopted % pinless events onto known venues', total;
end $adopt$;

-- ═══════════════════════════════════════════════════════════════════
-- 4i. MARK AN EVENT TO CANCEL  (patch 42)
--
-- Anybody may flag an event as one that should not be happening. It is
-- a VOTE, not an action: nothing about the event changes, no feed
-- hides it, no count is shown to anyone. The row lands in a table an
-- admin reads by hand in the Supabase table editor, and the admin then
-- uses the cancel path that already exists.
--
-- Deliberately NOT built, because they were not asked for:
--   · no admin interface — the table is the interface
--   · no notification of any kind
--   · no threshold that auto-hides or auto-cancels anything
--   · no notice to the host that their event was marked
--
-- The host keeps their own cancel_event_as(), untouched. This is the
-- other direction: everyone else, saying so.
--
-- ── THE TABLE IS THE INTERFACE ─────────────────────────────────────
--
-- Because an admin reads this raw, the row carries its own context:
-- the handle, the short_id and the title are copied in at write time
-- rather than left as a join. Opening the table editor and
-- understanding what you are looking at, with no query, is the whole
-- point. They are a SNAPSHOT of the moment it was marked — if the
-- event is renamed afterwards, the mark still says what was reported.
--
-- ── ON THE FREE TEXT ───────────────────────────────────────────────
--
-- `reason` is whatever the person typed, prefilled with the common
-- case. It is the one field in this schema written by a stranger ABOUT
-- somebody else, so unlike every other free-text column here it can
-- contain anything at all.
--
-- THIRTY-SEVEN CHARACTERS. Short enough that the column reads as a
-- column in the table editor rather than wrapping into paragraphs, and
-- short enough that it cannot become a place to write an essay about
-- another person. A sentence fragment is all this needs to be useful:
-- "event will not be happening" is 27 of them.
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.event_cancel_votes (
  event_id    uuid not null references public.events(id) on delete cascade,
  user_id     uuid not null references public.users(id)  on delete cascade,
  /* Snapshot columns — see above. Not foreign keys, on purpose. */
  handle      text,
  short_id    text,
  event_title text,
  reason      text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  /* One vote per person per event. Marking again rewrites the reason
     rather than adding a row, so ten changes of mind are still one
     vote and the table stays countable. */
  primary key (event_id, user_id),
  constraint event_cancel_votes_reason_check
    check (length(btrim(reason)) between 1 and 37)
);

create index if not exists event_cancel_votes_event_idx
  on public.event_cancel_votes (event_id);
create index if not exists event_cancel_votes_created_idx
  on public.event_cancel_votes (created_at desc);

alter table public.event_cancel_votes enable row level security;
-- no policies: unreachable with the anon key, in either direction. The
-- admin reads it through the dashboard, which uses the service role.


/* Record one vote.

   Returns jsonb rather than void so the client can tell "recorded"
   from "you had already marked this" and say something accurate. */
create or replace function public.mark_event_to_cancel(
  p_short_id     text,
  p_user         uuid,
  p_secret       text,
  p_reason       text,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash   text;
  v_handle text;
  v_event  public.events;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_today  integer;
  v_prior  boolean;
  v_result jsonb;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash, u.handle into v_hash, v_handle
    from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  /* Replay protection, same as every other mutation. A retry after a
     lost response returns the recorded answer instead of counting
     twice. */
  if p_operation_id is not null then
    v_result := public.op_replay(p_operation_id, p_user);
    if v_result is not null then return v_result; end if;
  end if;

  if length(v_reason) = 0 then
    raise exception 'say why' using errcode = '22023';
  end if;
  /* Truncate rather than refuse. The client caps the field at 37 too,
     so reaching this means a crafted request, and silently trimming one
     is friendlier than an error nobody will see. */
  if length(v_reason) > 37 then
    v_reason := left(v_reason, 37);
  end if;

  select * into v_event from public.events where short_id = p_short_id;
  if not found then
    raise exception 'no such event' using errcode = '22023';
  end if;
  if v_event.status = 'deleted' then
    return jsonb_build_object('ok', true, 'already_off', true);
  end if;

  /* A generous ceiling, and it is not about the person — it is about
     the table staying readable. One device looping over a town could
     put thousands of rows in front of whoever opens the editor, and
     then the feature has destroyed its own only interface. */
  select count(*) into v_today
    from public.event_cancel_votes
   where user_id = p_user and created_at > now() - interval '1 day';
  if v_today >= 20 then
    raise exception 'that is a lot of reports for one day'
      using errcode = '22023';
  end if;

  select true into v_prior
    from public.event_cancel_votes
   where event_id = v_event.id and user_id = p_user;

  insert into public.event_cancel_votes
    (event_id, user_id, handle, short_id, event_title, reason)
  values (v_event.id, p_user, v_handle, v_event.short_id, v_event.title, v_reason)
  on conflict (event_id, user_id) do update
    set reason = excluded.reason,
        event_title = excluded.event_title,
        updated_at = now();

  v_result := jsonb_build_object(
    'ok', true,
    'short_id', v_event.short_id,
    'updated', coalesce(v_prior, false));

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'event.mark_cancel', v_result);
  end if;
  return v_result;
end $$;

revoke all on function public.mark_event_to_cancel(text, uuid, text, text, uuid) from public;


/* Which events THIS person has already marked, so the button can say
   so on a second visit instead of inviting a duplicate. Returns only
   the caller's own rows — it is not a way to read anybody else's. */
create or replace function public.my_cancel_votes(p_user uuid, p_secret text)
returns table (short_id text, reason text, created_at timestamptz)
language plpgsql stable
security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  return query
    select v.short_id, v.reason, v.created_at
      from public.event_cancel_votes v
     where v.user_id = p_user
     order by v.created_at desc
     limit 200;
end $$;

revoke all on function public.my_cancel_votes(uuid, text) from public;


/* The admin's review list. Feeds the "review" filter on the Me screen,
   which sits beside going / attended / hosting and renders only for an
   admin.

   Returns one row per EVENT, not per vote — the Me lists render events,
   and an event marked by four people is one thing to look at, not four.
   The reasons come back as an array so the admin can see what was
   actually said without a second query.

   is_admin() first, and is_admin() itself is never granted to anon, so
   this cannot be used to discover whether somebody is an admin. */
create or replace function public.admin_events_to_review(
  p_user uuid, p_secret text, p_limit integer default 100
)
returns table (
  short_id    text,
  title       text,
  starts_at   timestamptz,
  status      text,
  votes       integer,
  reasons     text[],
  handles     text[],
  last_marked timestamptz
)
language plpgsql stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  return query
    select e.short_id, e.title, e.starts_at, e.status,
           count(*)::integer,
           array_agg(v.reason order by v.created_at desc),
           array_agg(v.handle  order by v.created_at desc),
           max(v.created_at)
      from public.event_cancel_votes v
      join public.events e on e.id = v.event_id
     /* A cancelled event needs no review — it is already off. */
     where e.status <> 'deleted'
     group by e.short_id, e.title, e.starts_at, e.status
     order by max(v.created_at) desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

revoke all on function public.admin_events_to_review(uuid, text, integer) from public;

-- ═══════════════════════════════════════════════════════════════════
-- 5. TRIGGERS
-- ═══════════════════════════════════════════════════════════════════

drop trigger if exists events_touch_updated_at on public.events;
create trigger events_touch_updated_at before update on public.events
  for each row execute function public.touch_updated_at();

drop trigger if exists venues_touch_updated_at on public.venues;
create trigger venues_touch_updated_at before update on public.venues
  for each row execute function public.touch_updated_at();

drop trigger if exists events_bump_community on public.events;
create trigger events_bump_community after insert on public.events
  for each row execute function public.bump_community_count();

drop trigger if exists users_assign_signup_index on public.users;
create trigger users_assign_signup_index before insert on public.users
  for each row execute function public.assign_signup_index();


-- ═══════════════════════════════════════════════════════════════════
-- 6. ROW LEVEL SECURITY
--
-- Enabled everywhere. Almost no policies, deliberately: with RLS on and
-- no policy the default is deny, and every path in is a SECURITY
-- DEFINER function that checks the device secret first.
--
-- Grants and policies are DIFFERENT GATES and both must pass. A missing
-- grant gives "permission denied for table x"; a missing policy gives
-- "new row violates row-level security policy". Same error code,
-- opposite fixes.
-- ═══════════════════════════════════════════════════════════════════

alter table public.users             enable row level security;
alter table public.events            enable row level security;
alter table public.attendances       enable row level security;
alter table public.event_visits      enable row level security;
alter table public.venues            enable row level security;
alter table public.communities       enable row level security;
alter table public.credentials       enable row level security;
alter table public.client_operations enable row level security;
alter table public.magic_codes       enable row level security;
alter table public.service_config    enable row level security;
alter table public.handle_words      enable row level security;

-- Every policy any earlier migration created. None survive.
drop policy if exists "handles are readable"                  on public.users;
drop policy if exists "anyone may claim a handle"              on public.users;
drop policy if exists "events are public"                      on public.events;
drop policy if exists "anyone may publish a well formed event" on public.events;
drop policy if exists "anyone may mark going"                  on public.attendances;
drop policy if exists "anyone may change their own going"      on public.attendances;
drop policy if exists "venues are public"                      on public.venues;
drop policy if exists "anyone may add a venue"                 on public.venues;
drop policy if exists "communities are public"                 on public.communities;
drop policy if exists "words are public"                       on public.handle_words;

/* handle_words is the single exception: a word list, readable so the
   client can keep an offline fallback. Nothing sensitive. */
create policy "words are public" on public.handle_words
  for select to anon using (true);


-- ═══════════════════════════════════════════════════════════════════
-- 7. TABLE PRIVILEGES
--
-- The browser reaches no table. Reads go through events_public;
-- writes go through RPCs that verify the device secret.
-- ═══════════════════════════════════════════════════════════════════

/* Revoke from EVERY table in the schema, by loop, rather than from a
   list I maintain by hand.

   The list version left three tables readable — event_visits,
   magic_codes and reserved_slugs — because I forgot them. And they
   were readable in the first place because schema 19 contained:

       alter default privileges in schema public
         grant select on tables to anon;

   which I wrote, with the comment "make sure anything added later
   inherits the same treatment". It does the opposite of what is wanted:
   every table created after it is readable by anon on creation. The
   default below reverses it. */

do $revoke$
declare r record;
begin
  for r in
    select c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
  loop
    execute format('revoke all on public.%I from anon', r.relname);
  end loop;
end
$revoke$;

alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
revoke all on all sequences in schema public from anon;

/* The two exceptions, granted back explicitly:
     handle_words   a word list, so the client can keep an offline
                    fallback for handle generation. Nothing sensitive.
     events_public  the view. Not a table — it is the sanctioned read
                    path and excludes photo_lat, photo_lng, host_id and
                    edit_token_hash. */
grant select on public.handle_words  to anon;
grant select on public.events_public to anon;


-- ═══════════════════════════════════════════════════════════════════
-- 8. FUNCTION PRIVILEGES
--
-- PostgreSQL grants EXECUTE on every new function to PUBLIC. Writing no
-- GRANT is not denying access — anon inherits PUBLIC. Nineteen
-- functions believed to be internal were callable with the anon key
-- that ships in config.js, including set_worker_secret, which gates the
-- venue-correction path.
--
-- So: revoke across the schema, then grant back a whitelist. The next
-- function anybody writes is private unless they say otherwise.
--
-- Extensions are excluded. pg_trgm installs 28 functions here and
-- stripping EXECUTE from them disables the % operator and every index
-- built on it.
-- ═══════════════════════════════════════════════════════════════════

do $priv$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and not exists (select 1 from pg_depend d
                        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon', r.sig);
  end loop;
end
$priv$;

do $grant$
declare
  r record;
  wanted text[] := array[
    -- identity
    'create_account','get_my_account','account_exists','claim_device_secret',
    -- events
    'publish_event','update_event_as','cancel_event_as','update_event','cancel_event',
    'public_event','event_json','my_hosted','my_events','my_events_as',
    'feed','feed_near','events_in_bbox',
    -- attendance
    'set_attendance','my_going','event_stats','record_visit',
    'recent_auto_attended','unattend_as','circle_count',
    -- places
    'search_venues','ensure_venue','ensure_community','community_lookup',
    'community_for_point','adopt_community_at','set_my_community',
    -- magic
    'may_use_magic_as','my_magic','redeem_magic_code',
    -- admin; each verifies is_admin() itself
    'is_admin','admin_all_events','admin_update_event','admin_cancel_event',
    -- diagnostics
    'bich_verify',
    -- ranking (was patch 36/37). feed_ranked is what the client calls
    -- for the home feed; viewer_circle is NOT granted, or anyone could
    -- enumerate who a given account keeps running into.
    'feed_ranked',
    -- the Worker calls these through PostgREST with the anon key, and
    -- every one checks is_worker() first — which is NOT granted
    'venues_needing_review','apply_venue_match',
    'events_needing_pin','apply_event_pin',
    -- the gazetteer read (was patch 39). BOTH the browser and the
    -- Worker call this one, and it is the only part of the venue
    -- consensus anybody outside the database may touch. It takes no
    -- secret because it needs none: it reads positions that are
    -- already public on events_public and writes nothing.
    --
    -- It MUST be in this list. Patch 39 granted it on its own line,
    -- which worked only because the revoke sweep above had already run
    -- in an earlier file. Here the sweep runs after everything, so a
    -- grant made further up is stripped again and the venue lookup in
    -- the create sheet would 403 on every keystroke.
    'resolve_venue_coords',
    -- marking an event to cancel (was patch 42). Both verify the device
    -- secret themselves; my_cancel_votes returns only the caller's rows.
    'mark_event_to_cancel','my_cancel_votes','admin_events_to_review'
  ];
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any(wanted)
       and not exists (select 1 from pg_depend d
                        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('grant execute on function %s to anon', r.sig);
  end loop;
end
$grant$;

/* Deliberately unreachable from a browser:
     set_worker_secret, is_worker          the Worker's gate
     op_record, op_replay                  idempotency internals
     owns_event, bich_hash                 building blocks
     promote_attendance, decay_unconfirmed cron only
     adopt_orphan_events, set_display_name, my_profile   SQL editor
     pick_handle, gen_short_id, and the trigger functions

   Triggers need no grant: they execute as the table owner. */


-- ═══════════════════════════════════════════════════════════════════
-- 9. SCHEDULED WORK
-- ═══════════════════════════════════════════════════════════════════

/* going → attended, a few hours after an event ends. Server side
   because the crossed-paths graph needs BOTH halves of a pair
   promoted; somebody who never reopens the app would otherwise stay
   invisible in everyone else's crossings forever.

   pg_cron only fires while the project is awake. A Supabase free
   project sleeps after 7 days idle and this silently stops. */
select cron.unschedule('bich-promote-attendance')
 where exists (select 1 from cron.job where jobname = 'bich-promote-attendance');

select cron.schedule('bich-promote-attendance', '17 * * * *',
                     $cron$select public.promote_attendance()$cron$);


-- ═══════════════════════════════════════════════════════════════════
-- 10. SEED DATA
-- ═══════════════════════════════════════════════════════════════════

-- Handle vocabulary. 3–5 lowercase letters only.
insert into public.handle_words (word, part) values
  ('slide','a'),('oak','a'),('wisp','a'),('bram','a'),('linen','a'),
  ('clove','a'),('flint','a'),('moss','a'),('rye','a'),('sage','a'),
  ('vale','a'),('dusk','a'),('reed','a'),('dune','a'),('ivy','a'),
  ('silk','a'),('wren','a'),('plume','a'),('tide','a'),('cove','a'),
  ('elm','a'),('fawn','a'),('glen','a'),('heath','a'),('jade','a'),
  ('lark','a'),('marsh','a'),('nook','a'),('onyx','a'),('pine','a'),
  ('birch','a'),('gorse','a'),('kelp','a'),('loam','a'),('slate','a'),
  ('thyme','a'),('umber','a'),('yarn','a'),('zest','a'),('brine','a'),
  ('chalk','a'),('drift','a'),('ember','a'),('frost','a'),('grove','a'),
  ('husk','a'),('inlet','a'),('juno','a'),('kiln','a'),
  ('tem','b'),('fern','b'),('toad','b'),('lin','b'),('star','b'),
  ('blue','b'),('hum','b'),('low','b'),('dim','b'),('spar','b'),
  ('tune','b'),('wave','b'),('rest','b'),('glow','b'),('flow','b'),
  ('cast','b'),('hush','b'),('arc','b'),('vow','b'),('peak','b'),
  ('calm','b'),('wild','b'),('soft','b'),('near','b'),('far','b'),
  ('quill','b'),('myrrh','b'),('seam','b'),('flax','b'),('amber','b'),
  ('bloom','b'),('crest','b'),('dawn','b'),('echo','b'),('fold','b'),
  ('gale','b'),('haze','b'),('iris','b'),('jetty','b'),('lull','b'),
  ('mist','b'),('north','b'),('opal','b'),('pearl','b'),('quiet','b'),
  ('reef','b'),('shade','b'),('trace','b'),('verve','b')
on conflict (word) do nothing;

-- anything that cannot satisfy the handle rule would generate a name
-- the insert path then refuses
delete from public.handle_words where word !~ '^[a-z]{3,5}$';

insert into public.reserved_slugs (word) values
  ('admin'),('api'),('app'),('www'),('bich'),('event'),('events'),
  ('new'),('edit'),('map'),('me'),('settings'),('help'),('about')
on conflict (word) do nothing;


commit;


-- ═══════════════════════════════════════════════════════════════════
-- AFTERWARDS — run each of these
-- ═══════════════════════════════════════════════════════════════════
--
-- 1. Everything the app needs, present and correctly shaped:
--      select * from public.bich_verify() where not ok;
--    Empty means correct.
--
-- 2. pg_trgm survived the revoke — a number, not an error:
--      select similarity('mill', 'the mill');
--
-- 3. No table is reachable by anon:
--      select table_name, privilege_type
--        from information_schema.role_table_grants
--       where grantee = 'anon' and table_schema = 'public'
--       order by 1;
--    Expect only handle_words and events_public.
--
-- 4. Nothing sensitive is callable. set_worker_secret, op_record,
--    op_replay, bich_hash and owns_event must NOT appear:
--      select p.proname
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and has_function_privilege('anon', p.oid, 'execute')
--         and not exists (select 1 from pg_depend d
--                          where d.objid = p.oid and d.deptype = 'e')
--       order by 1;
--
-- 5. Nothing depends on the view type:
--      select p.proname, pg_get_function_result(p.oid)
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and pg_get_function_result(p.oid) like '%events_public%';
--    Expect zero rows.
--
-- 6. From the APP CONSOLE, not the SQL editor — the editor runs as
--    postgres and bypasses all of this, which is exactly how a missing
--    policy hid for weeks:
--      bichCheck()
--
-- 7. And from the repo:
--      node tools/contract-check.js --live
--
-- Only after 1–7 pass, set the Worker secret:
--      select public.set_worker_secret('<32+ random characters>');

--
-- ── 8. the venue gazetteer (part 4f) ──────────────────────────────
--
-- 1. Watch a venue converge. Three people pin the same place from
--    slightly different spots, one of them badly:
--      select public.record_venue_observation(v,u1,e1,'Bar Central',38.9634,-9.4172,'manual_pin');
--      select public.record_venue_observation(v,u2,e2,'Bar Central',38.9635,-9.4171,'manual_pin');
--      select public.record_venue_observation(v,u3,e3,'Bar Central',38.9800,-9.4500,'exif');
--      select lat, lng, confidence, spread_m, distinct_reporters
--        from public.venues where id = v;
--    The third is 3km out and weighted 0.3; it must not move the answer.
--
-- 2. The resolution layer answers:
--      select * from public.resolve_venue_coords('bar central','ericeira');
--    Deliberately loose on spelling: "bar central" finds a venue stored
--    as "Bar Central Ericeira".
--
-- 3. Confidence rises with independent agreement, not repetition:
--      one reporter, five events   -> stays near 0.33
--      three reporters, one each   -> approaches 0.95
--
-- 4. Nothing sensitive is exposed:
--      select has_function_privilege('anon','public.resolve_venue_coords(text,text,double precision,double precision)','execute');  -- true
--      select has_function_privilege('anon','public.recompute_venue(uuid)','execute');                                              -- false
--      select has_function_privilege('anon','public.record_venue_observation(uuid,uuid,uuid,text,double precision,double precision,text)','execute'); -- false
--
-- ── 9. the gazetteer is actually being fed (part 4g) ──────────────
--
-- 1. The gazetteer has something in it:
--      select count(*) as observations from public.venue_observations;
--      select name, round(confidence::numeric,2) as conf, distinct_reporters,
--             round(spread_m::numeric,0) as spread_m, observation_count
--        from public.venues where observation_count > 0
--       order by confidence desc limit 20;
--
-- 2. The resolution layer can now answer. Before this file it could
--    not, because every venue had confidence 0:
--      select * from public.resolve_venue_coords('bar central','<your slug>');
--
-- 3. Publishing records an observation by itself:
--      select count(*) from public.venue_observations;   -- note it
--      -- publish an event with a pin from the app, then
--      select count(*) from public.venue_observations;   -- one more
--
-- 4. Nothing recorded a pin that came FROM a venue:
--      select count(*) as must_be_zero
--        from public.venue_observations o
--        join public.events e on e.id = o.event_id
--       where e.pin_source = 'venue';
--
-- ── 10. the consolidation itself ──────────────────────────────────
--
-- Nothing kept PostgreSQL's default grant to PUBLIC by being defined
-- after the sweep in part 8. Both of these were true as separate
-- patch files and are false now:
--      select has_function_privilege('anon','public.age_factor(timestamptz)','execute');        -- false
--      select has_function_privilege('anon','public.observation_weight(text)','execute');       -- false
--    and the one the browser needs survived it:
--      select has_function_privilege('anon','public.resolve_venue_coords(text,text,double precision,double precision)','execute');  -- true
