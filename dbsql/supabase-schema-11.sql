-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 11: category
--
-- The class timetable that prompted this carries a legend at the
-- bottom: CLASS · EVENT / WORKSHOP · FREE EVENT, colour coded through
-- the whole grid. That distinction was being read and thrown away,
-- and it is exactly what a map filter needs: "show me the yoga" and
-- "show me the parties" are different questions about the same pins.
--
-- Run after parts 1-10. Safe to re-run.
-- ════════════════════════════════════════════════════════════════

alter table public.events
  add column if not exists category text;

alter table public.events drop constraint if exists events_category_check;
alter table public.events add constraint events_category_check check (
  category is null or category in (
    'music', 'wellness', 'food', 'market', 'sport', 'art',
    'talk', 'film', 'social', 'workshop', 'nightlife', 'other'
  )
);

-- Filtering is always inside a time window, so the index is only
-- worth having alongside the date.
create index if not exists events_category_idx
  on public.events (category, starts_at) where status = 'live';

-- ── expose it ────────────────────────────────────────────────────
-- events_public and both feed functions select explicit column lists,
-- so a new column reaches no client until it is named. All three have
-- to be recreated. Views cannot be replaced when the column list
-- changes, hence the drops.

drop view if exists public.events_public cascade;
create view public.events_public as
  select
    e.id, e.short_id, e.title, e.description,
    e.venue_name, e.venue_lat, e.venue_lng,
    e.city, e.community_slug,
    e.starts_at, e.ends_at, e.recurrence,
    e.price_value, e.price_currency, e.capacity,
    e.cover_url, e.contact, e.source, e.category,
    coalesce(a.going_count, 0) as going_count
  from public.events e
  left join (
    select event_id, count(*) as going_count
    from public.attendances
    where status in ('going','attended')
    group by event_id
  ) a on a.event_id = e.id
  where e.status = 'live';

-- cascade above dropped events_in_bbox, which returns this view
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

drop function if exists public.feed(uuid, text, timestamptz, integer);
create function public.feed(
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
  cover_url text, category text, going_count bigint, circle_count integer
)
language sql stable security definer set search_path = public
as $$
  select e.id, e.short_id, e.title, e.description,
         e.venue_name, e.venue_lat, e.venue_lng,
         e.city, e.community_slug,
         e.starts_at, e.price_value, e.price_currency,
         e.cover_url, e.category,
         coalesce(a.n, 0) as going_count,
         case when viewer is null then null
              when public.attended_count(viewer) < 2 then null
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

drop function if exists public.feed_near(
  uuid, double precision, double precision, double precision, text, timestamptz, integer);
create function public.feed_near(
  viewer uuid default null,
  near_lat double precision default null,
  near_lng double precision default null,
  radius_km double precision default 25,
  community text default null,
  from_ts timestamptz default now(),
  max_results integer default 60
)
returns table (
  id uuid, short_id text, title text, description text,
  venue_name text, venue_lat double precision, venue_lng double precision,
  city text, community_slug text,
  starts_at timestamptz, ends_at timestamptz, recurrence text,
  price_value integer, price_currency text, capacity integer, contact text,
  cover_url text, category text, going_count bigint, circle_count integer,
  distance_km double precision
)
language sql stable security definer set search_path = public
as $$
  with box as (
    select
      near_lat - (radius_km / 111.0) as min_lat,
      near_lat + (radius_km / 111.0) as max_lat,
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
      and ((e.venue_lat between box.min_lat and box.max_lat
            and e.venue_lng between box.min_lng and box.max_lng)
        or (community is not null and e.community_slug = community))
  )
  select c.id, c.short_id, c.title, c.description,
         c.venue_name, c.venue_lat, c.venue_lng,
         c.city, c.community_slug,
         c.starts_at, c.ends_at, c.recurrence,
         c.price_value, c.price_currency, c.capacity, c.contact,
         c.cover_url, c.category,
         coalesce(a.n, 0) as going_count,
         case when viewer is null then null
              when public.attended_count(viewer) < 2 then null
              else public.circle_count(viewer, c.id) end as circle_count,
         c.dist as distance_km
  from candidates c
  left join (
    select event_id, count(*) as n from public.attendances
    where status in ('going','attended') group by event_id
  ) a on a.event_id = c.id
  where c.dist is null or c.dist <= radius_km
     or (community is not null and c.community_slug = community)
  order by c.starts_at
  limit max_results;
$$;

grant execute on function public.feed(uuid, text, timestamptz, integer) to anon;
grant execute on function public.feed_near(
  uuid, double precision, double precision, double precision, text, timestamptz, integer) to anon;
grant execute on function public.events_in_bbox(
  double precision, double precision, double precision, double precision, timestamptz) to anon;

-- update_event returns events_public, which was dropped and recreated
-- above, so it has to be recompiled. Re-run part 9 after this file.
