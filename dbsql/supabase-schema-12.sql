-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 12
--
--   1. communities stop being three hardcoded rows and create
--      themselves from coordinates
--   2. 'going' becomes 'attended' on a schedule, which is the input
--      the crossed paths graph has never had
--   3. two people need TWO shared events, not one
--   4. events say who made them
--
-- Idempotent. Paste the whole thing into the Supabase SQL editor.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. communities that create themselves ─────────────────────────
-- Until now: three rows, ericeira / mallorca / lisboa, inserted by
-- hand. Anything published outside those circles resolved to null and
-- belonged nowhere — an event in Coimbra is 176km from the Lisboa
-- centre point, so it had no community at all.
--
-- A community is a LABEL FOR A PERSON, not a directory of approved
-- places. That distinction decides the whole design. The name never
-- comes from a user — it comes from OpenStreetMap — so there is no
-- junk to moderate and no reason to hold a new place in a pending
-- state before letting anyone belong to it. It exists the moment
-- somebody's coordinates land inside it.

alter table public.communities
  add column if not exists osm_id      text,
  add column if not exists kind        text,
  add column if not exists event_count integer not null default 0;

-- The dedupe key. Names drift — "Coimbra", "Coïmbra", a pin 3km down
-- the road, the same town spelled two ways by two geocoders — but the
-- OSM place id does not. Uniqueness hangs off that, never the name.
create unique index if not exists communities_osm_idx
  on public.communities (osm_id) where osm_id is not null;

-- Everything existing stays visible. is_active is left alone rather
-- than dropped, so older schema files that reference it still run.
update public.communities set is_active = true where is_active is not true;

-- Radius by what kind of place it is. A village given a 25km circle
-- swallows its neighbours; an island needs far more than 25. These are
-- the radii used for "near me" fallback, not administrative truth.
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

grant execute on function public.default_radius_for(text) to anon;

-- Called after the worker reverse geocodes a coordinate. Returns the
-- slug to use. security definer because anon has no insert rights on
-- this table and should not: this function is the only way in, and it
-- validates everything it writes.
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
  on conflict (slug) do nothing;

  return v_slug;
end $$;

grant execute on function public.ensure_community(text, text, text, text, double precision, double precision) to anon;

-- Keeps event_count honest so the app can tell a lively place from one
-- that has been touched once. Used for display only — nobody is
-- excluded from a community for it being quiet.
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

drop trigger if exists events_bump_community on public.events;
create trigger events_bump_community after insert on public.events
  for each row execute function public.bump_community_count();

-- What the app reads. Recreated because older files defined it.
drop view if exists public.community_reach cascade;
create view public.community_reach as
  select slug, name, country, kind,
         centre_lat, centre_lng, radius_km,
         event_count,
         true          as may_widen,
         radius_km * 3 as max_radius_km
  from public.communities;

grant select on public.community_reach to anon;


-- ── 2. 'going' becomes 'attended' ─────────────────────────────────
-- Nothing in this system has ever written status = 'attended'. Not the
-- app, not a trigger, not a job. attended_count() therefore returns 0
-- for every person alive, circle_count() is gated behind that being at
-- least 2, and so the crossed paths number has never once rendered for
-- anybody. This is the missing input.
--
-- Server side, not in the browser, for two reasons. The graph needs
-- BOTH halves of a pair promoted, so a person who never reopens the app
-- would otherwise stay invisible in everyone else's crossings forever.
-- And row level security deliberately forbids a client from writing
-- 'attended' at all: if a browser could assert it, the signal would
-- mean nothing.

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

-- "actually I wasn't there". Only ever demotes, only ever your own row.
create or replace function public.unattend(p_user uuid, p_event uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  update public.attendances
     set status = 'cancelled', confirmed_at = null
   where user_id = p_user and event_id = p_event and status = 'attended';
  return found;
end $$;

grant execute on function public.unattend(uuid, uuid) to anon;

-- What was auto-marked recently, so the app can ask about it once.
create or replace function public.recent_auto_attended(
  p_user uuid, p_since interval default interval '7 days')
returns table (event_id uuid, short_id text, title text, starts_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select e.id, e.short_id, e.title, e.starts_at
  from public.attendances a
  join public.events e on e.id = a.event_id
  where a.user_id = p_user
    and a.status = 'attended'
    and a.confirmed_at > now() - p_since
  order by e.starts_at desc
  limit 20;
$$;

grant execute on function public.recent_auto_attended(uuid, interval) to anon;

-- The schedule. Enable pg_cron once under Database → Extensions.
create extension if not exists pg_cron;

select cron.unschedule('bich-promote-attendance')
where exists (select 1 from cron.job where jobname = 'bich-promote-attendance');

select cron.schedule(
  'bich-promote-attendance',
  '17 * * * *',                      -- hourly, off the hour
  $$select public.promote_attendance()$$
);


-- ── 3. two shared events, not one ─────────────────────────────────
-- The old join matched on a SINGLE shared event, so one coincidental
-- overlap made two people "crossed paths". Once promotion above starts
-- running, that turns every busy night into hundreds of mutual
-- crossings at once. Twice is a pattern; once is a coincidence.
--
-- The other thresholds are deliberately NOT loosened. An event still
-- needs 10 people before any number appears, and the overlap still
-- needs to be 3. Together those are what stop a count becoming a name:
-- at four attendees, "three people you've crossed paths with"
-- identifies them exactly. Small gatherings therefore show nothing,
-- and that is the correct trade.

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

grant execute on function public.circle_count(uuid, uuid) to anon;


-- ── 4. events say who made them ───────────────────────────────────
-- events_public exposed no host, so every event read back with an empty
-- host and the app could only label your own. The handle is two random
-- words and identifies nobody, which is the entire point of it.

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
    where status in ('going', 'attended')
    group by event_id
  ) a on a.event_id = e.id
  where e.status = 'live';

grant select on public.events_public to anon;

-- events_in_bbox returned that view and went down with the cascade.
create or replace function public.events_in_bbox(
  min_lat double precision, min_lng double precision,
  max_lat double precision, max_lng double precision,
  from_ts timestamptz default now()
)
returns setof public.events_public
language sql stable security definer set search_path = public
as $$
  select * from public.events_public
  where venue_lat between min_lat and max_lat
    and venue_lng between min_lng and max_lng
    and starts_at >= from_ts
  order by starts_at;
$$;

grant execute on function public.events_in_bbox(
  double precision, double precision, double precision, double precision, timestamptz) to anon;


-- ── afterwards ────────────────────────────────────────────────────
--   select jobname, schedule from cron.job;
--   select public.promote_attendance();            -- run it once by hand
--   select slug, name, kind, radius_km, event_count
--     from public.communities order by event_count desc;
