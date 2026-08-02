-- ═══════════════════════════════════════════════════════════════════
-- bich.service — CONSOLIDATED BASELINE
--
-- Replaces supabase-schema.sql through supabase-schema-34.sql.
-- Generated from them, in order, keeping only what survived.
--
-- Run this on an empty database and you get the target schema.
-- Run it on the current one and it converges to the same place.
-- Either way, one file describes the whole system.
-- ═══════════════════════════════════════════════════════════════════


-- ── why this exists ───────────────────────────────────────────────
-- Thirty-four migrations, several redefining what earlier ones made,
-- two containing a `drop view … cascade` that deleted live functions in
-- production twice. There was no way to answer "is this database
-- correct?" short of reading all of them in order and simulating.
--
-- Three defects came from exactly that: update_event deleted by a
-- cascade, my_hosted deleted the same way, and a signature drift the
-- frontend called for a week. All three were invisible until somebody
-- hit them.
--
-- Note on the drops below: earlier files created things this one does
-- not, because they were superseded. Those drops are what make this
-- file safe to run on an existing database — without them, an old
-- function with a different signature would sit alongside the new one
-- and PostgREST could resolve to either.


-- ── how it was assembled ──────────────────────────────────────────
-- For each function, the LAST definition across 1–34 wins; that is the
-- one deployed today. Tables carry every column that survived every
-- alter. Superseded work (the venue review queue from 30, the
-- first-100 magic cohort from 15/16) is absent rather than added and
-- removed.
--
-- What this file does NOT do: it is not a data migration. It creates
-- and replaces schema objects. Existing rows are untouched.


begin;

set local statement_timeout = '120s';

create extension if not exists pgcrypto  with schema extensions;
create extension if not exists pg_trgm;
create extension if not exists pg_cron;


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

alter table public.users drop constraint if exists users_community_via_check;
alter table public.users add constraint users_community_via_check
  check (community_via is null or community_via in ('link','photo','publish','view'));

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

create or replace function public.normalise_venue_source(p_source text)
returns text
language sql immutable
as $$
  select case
    when p_source is null then null
    when lower(btrim(p_source)) in
      ('manual','printed_coordinates','printed_address','venue_name_only','matched_venue')
      then lower(btrim(p_source))
    -- anything else was a client-side label, not a fact worth losing an event over
    else 'manual'
  end;
$$;

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
  on conflict (word) do nothing;

  return v_slug;
end $$;

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
  if p_via is null or p_via not in ('link','photo','publish','view') then
    raise exception 'unknown community signal' using errcode = '22023';
  end if;

  v_slug := public.community_for_point(p_lat, p_lng);
  if v_slug is null then
    /* No community covers this point yet. The caller should geocode
       and call ensure_community, then try again. Reported rather than
       returned as a silent null so the client can tell "unknown place"
       apart from "something failed". */
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
    /* The account exists but has never claimed a secret. That is a
       recoverable client state, not a permission problem, and saying
       "not yours" about somebody's own brand new account sent me
       chasing the wrong bug for two rounds. */
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

  insert into public.events (
    short_id, host_id, title, description,
    venue_name, venue_address, venue_lat, venue_lng, venue_source,
    city, community_slug, photo_lat, photo_lng,
    starts_at, ends_at, recurrence,
    price_value, price_currency, capacity,
    cover_url, contact, source, category,
    pin_source, is_backfill, needs_review,
    status, edit_token_hash
  ) values (
    v_short, p_user,
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
     and coalesce(e.ends_at, e.starts_at + interval '3 hours') < now() - grace;
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
    -- the Worker calls these through PostgREST with the anon key, and
    -- both check is_worker() first — which is NOT granted
    'venues_needing_review','apply_venue_match'
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
