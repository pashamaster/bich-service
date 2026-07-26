-- ════════════════════════════════════════════════════════════════
-- bich.service — events schema for Supabase
--
-- Paste into the Supabase SQL editor and run. Safe to re-run.
--
-- Two ideas shape this file:
--   1. No personal data. Identity is a generated handle plus, later, a
--      passkey public key. There is no email column and there never will be.
--   2. Location is three separate things and they must not overwrite each
--      other: where the photo was taken, which town it belongs to, and
--      where people actually go.
-- ════════════════════════════════════════════════════════════════

create extension if not exists "pgcrypto";

-- ── people ───────────────────────────────────────────────────────
-- A row here is a device or a passkey, never a person we can name.
create table if not exists public.users (
  id           uuid primary key default gen_random_uuid(),
  handle       text not null unique,          -- "slide tem"
  public_key   text unique,                   -- passkey public key, null until saved
  created_at   timestamptz not null default now()
);

-- ── communities ──────────────────────────────────────────────────
-- The wider local scene an event belongs to. Deliberately a table and not
-- free text: left open, extraction will invent "Ericeira", "ericeira" and
-- "Ericeira coast" as three different places within a week.
create table if not exists public.communities (
  slug         text primary key,              -- 'ericeira', 'mallorca'
  name         text not null,                 -- 'Ericeira'
  country      text,                          -- ISO 3166-1 alpha-2, 'PT'
  centre_lat   double precision,
  centre_lng   double precision,
  radius_km    integer default 25,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

insert into public.communities (slug, name, country, centre_lat, centre_lng) values
  ('ericeira', 'Ericeira', 'PT', 38.9634, -9.4162),
  ('mallorca', 'Mallorca', 'ES', 39.6953,  3.0176),
  ('lisboa',   'Lisboa',   'PT', 38.7223, -9.1393)
on conflict (slug) do nothing;

-- ── events ───────────────────────────────────────────────────────
create table if not exists public.events (
  id                uuid primary key default gen_random_uuid(),
  short_id          text not null unique,       -- for bich.app/e/xxxx
  host_id           uuid references public.users(id) on delete set null,

  title             text not null,
  description       text,

  -- WHERE PEOPLE GO. Null until a pin is set. Never filled from photo GPS.
  venue_name        text,
  venue_address     text,
  venue_lat         double precision,
  venue_lng         double precision,
  venue_source      text not null default 'manual'
                    check (venue_source in ('manual','printed_coordinates','printed_address','venue_name_only')),

  -- WHICH TOWN. A hint, good enough for discovery, not for navigation.
  city              text,
  community_slug    text references public.communities(slug),

  -- WHERE THE PHOTO WAS TAKEN. Kept for origin analytics only.
  -- A flyer in a cafe window advertises something happening elsewhere,
  -- so this must never be read as the venue.
  photo_lat         double precision,
  photo_lng         double precision,

  starts_at         timestamptz not null,
  ends_at           timestamptz,
  recurrence        text,                       -- 'every sunday', null for one-offs

  price_value       integer not null default 0, -- smallest unit: cents
  price_currency    text not null default 'EUR',
  capacity          integer,                    -- null = unlimited

  cover_url         text,                       -- points at R2, not stored here
  contact           text,                       -- as printed on the flyer

  source            text not null default 'manual'
                    check (source in ('manual','photo')),
  status            text not null default 'live'
                    check (status in ('live','hidden','deleted')),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint venue_pin_is_complete
    check ((venue_lat is null) = (venue_lng is null)),
  constraint ends_after_starts
    check (ends_at is null or ends_at > starts_at)
);

create index if not exists events_starts_at_idx  on public.events (starts_at) where status = 'live';
create index if not exists events_community_idx  on public.events (community_slug, starts_at) where status = 'live';
create index if not exists events_bbox_idx       on public.events (venue_lat, venue_lng) where status = 'live';
create index if not exists events_host_idx       on public.events (host_id);

-- ── attendance ───────────────────────────────────────────────────
-- 'going' is a soft signal. 'attended' is what feeds the crossed-paths
-- graph, and only after the event has actually happened.
create table if not exists public.attendances (
  event_id      uuid not null references public.events(id) on delete cascade,
  user_id       uuid not null references public.users(id) on delete cascade,
  status        text not null default 'going'
                check (status in ('going','attended','cancelled')),
  joined_at     timestamptz not null default now(),
  confirmed_at  timestamptz,
  primary key (event_id, user_id)
);

create index if not exists attendances_user_idx  on public.attendances (user_id, status);
create index if not exists attendances_event_idx on public.attendances (event_id, status);

-- ── keep updated_at honest ───────────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists events_touch on public.events;
create trigger events_touch before update on public.events
  for each row execute function public.touch_updated_at();

-- ── short ids ────────────────────────────────────────────────────
-- Opaque and non-sequential, so the id never leaks how many events exist.
create or replace function public.gen_short_id()
returns text language plpgsql as $$
declare
  alphabet text := 'abcdefghijkmnopqrstuvwxyz23456789';  -- no l/1/0/o
  out text := '';
begin
  for i in 1..8 loop
    out := out || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return out;
end $$;

alter table public.events alter column short_id set default public.gen_short_id();

-- ── row level security ───────────────────────────────────────────
-- The browser holds the publishable key, so the database itself is the
-- lock. Anyone may read live events. Writes go through the worker using
-- the service role, which bypasses these policies.
alter table public.users       enable row level security;
alter table public.events      enable row level security;
alter table public.attendances enable row level security;
alter table public.communities enable row level security;

drop policy if exists "live events are public" on public.events;
create policy "live events are public"
  on public.events for select
  using (status = 'live');

drop policy if exists "communities are public" on public.communities;
create policy "communities are public"
  on public.communities for select
  using (is_active);

-- Counts only, never a list of who. Attendee identities stay unreadable
-- from the client by design.
drop policy if exists "no direct attendance reads" on public.attendances;

-- ── the feed ─────────────────────────────────────────────────────
-- Exposes going_count without exposing who is going.
create or replace view public.events_public as
  select
    e.id, e.short_id, e.title, e.description,
    e.venue_name, e.venue_lat, e.venue_lng,
    e.city, e.community_slug,
    e.starts_at, e.ends_at, e.recurrence,
    e.price_value, e.price_currency, e.capacity,
    e.cover_url, e.contact, e.source,
    coalesce(a.going_count, 0) as going_count
  from public.events e
  left join (
    select event_id, count(*) as going_count
    from public.attendances
    where status in ('going','attended')
    group by event_id
  ) a on a.event_id = e.id
  where e.status = 'live';

-- ── map queries ──────────────────────────────────────────────────
create or replace function public.events_in_bbox(
  min_lat double precision, min_lng double precision,
  max_lat double precision, max_lng double precision,
  from_ts timestamptz default now()
)
returns setof public.events_public
language sql stable as $$
  select * from public.events_public
  where venue_lat between min_lat and max_lat
    and venue_lng between min_lng and max_lng
    and starts_at >= from_ts
  order by starts_at
  limit 200;
$$;
