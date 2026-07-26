-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 2
-- venues · passkey credentials · the crossed paths graph
-- Run after supabase-schema.sql. Safe to re-run.
-- ════════════════════════════════════════════════════════════════

-- ── venues ───────────────────────────────────────────────────────
-- Your own venue book. Spec 6.3 says never store only a third party id,
-- because coordinates are what make us provider independent. So every
-- venue keeps its own lat/lng whatever found it, and the external id is
-- only a breadcrumb for re-fetching later.
--
-- The point of this table: after fifty events in one town you no longer
-- need anyone's API for the venues that matter. "the organic way" is a
-- row here, not a lookup.
create table if not exists public.venues (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  address       text,
  lat           double precision not null,
  lng           double precision not null,
  city          text,
  community_slug text references public.communities(slug),

  source        text not null default 'manual'
                check (source in ('manual','photo','foursquare','osm','nominatim','locationiq')),
  source_id     text,                       -- breadcrumb only, never the sole identifier

  use_count     integer not null default 0, -- how many events have used it
  verified      boolean not null default false,
  created_at    timestamptz not null default now(),

  unique (source, source_id)
);

-- fuzzy name search, so "organic way" finds "The Organic Way"
create extension if not exists pg_trgm;
create index if not exists venues_name_trgm_idx on public.venues using gin (name gin_trgm_ops);
create index if not exists venues_community_idx on public.venues (community_slug);
create index if not exists venues_geo_idx       on public.venues (lat, lng);

alter table public.events
  add column if not exists venue_id uuid references public.venues(id) on delete set null;

-- Search our own venues first. Cheap, instant, offline, and it gets better
-- every time someone publishes. Only fall through to an external provider
-- when this returns nothing.
create or replace function public.search_venues(
  q text,
  near_lat double precision default null,
  near_lng double precision default null,
  community text default null,
  max_results integer default 8
)
returns table (
  id uuid, name text, address text,
  lat double precision, lng double precision,
  city text, use_count integer, score real
)
language sql stable as $$
  select v.id, v.name, v.address, v.lat, v.lng, v.city, v.use_count,
         similarity(v.name, q)
           -- nudge popular venues up, and nearby ones up harder
           + least(v.use_count, 20) * 0.01
           + case when near_lat is null then 0
                  else greatest(0, 0.3 - (abs(v.lat - near_lat) + abs(v.lng - near_lng))) end
         as score
  from public.venues v
  where v.name % q
    and (community is null or v.community_slug = community)
  order by score desc
  limit max_results;
$$;

-- Keep use_count honest so the venue book self-ranks.
create or replace function public.bump_venue_use()
returns trigger language plpgsql as $$
begin
  if new.venue_id is not null then
    update public.venues set use_count = use_count + 1 where id = new.venue_id;
  end if;
  return new;
end $$;

drop trigger if exists events_bump_venue on public.events;
create trigger events_bump_venue after insert on public.events
  for each row execute function public.bump_venue_use();


-- ── passkey credentials ──────────────────────────────────────────
-- Spec 7.2. One user may hold several passkeys: phone, laptop, a second
-- device added later. The passkey PROVES identity, it does not store data,
-- so all that lives here is a public key and a counter.
create table if not exists public.credentials (
  id             text primary key,           -- credential id, base64url
  user_id        uuid not null references public.users(id) on delete cascade,
  public_key     bytea not null,
  counter        bigint not null default 0,  -- replay protection
  transports     text[],                     -- 'internal', 'hybrid', 'usb'
  device_label   text,                       -- 'phone', user editable, never a name
  backed_up      boolean not null default false,
  created_at     timestamptz not null default now(),
  last_used_at   timestamptz
);

create index if not exists credentials_user_idx on public.credentials (user_id);

alter table public.credentials enable row level security;
-- No client ever reads this table. Only the worker, via the service role.


-- ── the crossed paths graph ──────────────────────────────────────
-- Spec 7.3. Two joins: who did I attend with, and how many of them are
-- going to this. Cheap into the tens of thousands of users; spec 7.4's
-- materialised table stays deferred until something is measurably slow.
--
-- Spec 7.5's privacy guardrails are enforced HERE rather than in the
-- frontend, so no future screen can accidentally leak a small number.
create or replace function public.circle_count(
  viewer uuid,
  event  uuid
)
returns integer
language plpgsql stable as $$
declare
  total   integer;
  circle  integer;
begin
  -- suppress entirely for thinly attended events: with few enough people,
  -- a count is close to naming them
  select count(*) into total
  from public.attendances
  where event_id = event and status in ('going','attended');

  if total < 10 then
    return null;
  end if;

  select count(distinct them.user_id) into circle
  from public.attendances mine
  join public.attendances them
    on them.event_id = mine.event_id
   and them.user_id <> viewer
   and them.status = 'attended'
  where mine.user_id = viewer
    and mine.status = 'attended'
    and them.user_id in (
      select user_id from public.attendances
      where event_id = event and status in ('going','attended')
    );

  -- below the threshold the app says "a few people", never a number
  if circle < 3 then
    return 0;
  end if;

  return circle;
end $$;

-- How many events has this user actually confirmed attending? Drives the
-- cold start rule in Q9: show no signal at all until there are 2.
create or replace function public.attended_count(viewer uuid)
returns integer
language sql stable as $$
  select count(*)::integer from public.attendances
  where user_id = viewer and status = 'attended';
$$;

-- The feed, with the social signal already resolved per viewer.
create or replace function public.feed(
  viewer uuid,
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
language sql stable as $$
  select e.id, e.short_id, e.title, e.description,
         e.venue_name, e.venue_lat, e.venue_lng,
         e.city, e.community_slug,
         e.starts_at, e.price_value, e.price_currency,
         e.cover_url,
         coalesce(a.n, 0) as going_count,
         case when public.attended_count(viewer) < 2 then null
              else public.circle_count(viewer, e.id) end as circle_count
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


-- ── post-event attestation ───────────────────────────────────────
-- Spec 7.8 / Q1: 'going' never feeds the graph, only 'attended' does, and
-- unconfirmed markers decay so nobody can inflate a circle by marking
-- going on everything in town.
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
