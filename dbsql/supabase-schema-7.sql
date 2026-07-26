-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 7: a feed that can widen
--
-- feed() filters on community_slug, which is a label match. It cannot
-- answer "everything within 60 km of here", so it cannot widen when a
-- town is quiet. This adds a geographic sibling.
--
-- No PostGIS. The haversine expression below is a handful of trig
-- calls, and a bounding box prefilter means the index does the work
-- before any of it runs. At the scale where that stops being true you
-- will want PostGIS anyway, and this function is the thing you would
-- replace.
--
-- Run after parts 1-6. Safe to re-run.
-- ════════════════════════════════════════════════════════════════

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

grant execute on function public.feed_near(
  uuid, double precision, double precision, double precision, text, timestamptz, integer
) to anon;

-- Same guarantee as feed(): SECURITY DEFINER so it can count
-- attendances, but it returns counts only. circle_count keeps its own
-- k-anonymity floor and stays revoked from anon directly.

-- ── how wide should a place look? ────────────────────────────────
-- Read by the client to build its widening ladder. Islands never
-- widen: past their own shoreline is open water, and the next thing
-- across it is a different scene entirely, not a further-away version
-- of the same one.
create or replace view public.community_reach as
  select slug, name, kind, centre_lat, centre_lng, radius_km,
         (kind <> 'island') as may_widen,
         case kind
           when 'island' then radius_km          -- never past the coast
           when 'town'   then 60
           when 'city'   then 100
           when 'region' then 120
         end as max_radius_km
  from public.communities
  where is_active;
