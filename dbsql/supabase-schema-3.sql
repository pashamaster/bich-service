-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 3: fixes before going live
--
-- Two problems with what you already ran. Both matter.
--
-- 1. public.venues had no row level security. In Supabase a table with
--    RLS off is fully open to the publishable key: anyone could rewrite
--    or delete your venue book from the browser console.
--
-- 2. circle_count, attended_count and feed default to SECURITY INVOKER,
--    so they read public.attendances as the caller. attendances has RLS
--    on with no select policy, so from the browser those functions would
--    always return nothing. The social signal would silently read zero
--    forever. They need SECURITY DEFINER: they return only aggregates,
--    never rows, which is exactly what the guardrails were designed for.
--
-- Run after parts 1 and 2. Safe to re-run.
-- ════════════════════════════════════════════════════════════════

-- ── 1. close the venues hole ─────────────────────────────────────
alter table public.venues enable row level security;

drop policy if exists "venues are readable" on public.venues;
create policy "venues are readable"
  on public.venues for select
  using (true);
-- No insert/update/delete policy: writes go through the worker using the
-- service role, which bypasses RLS. The browser can read the venue book
-- and never change it.

-- ── 2. make the social functions work from the browser ───────────
-- SECURITY DEFINER means these run as the owner and can see attendances.
-- They still expose only counts, and the k-anonymity rules inside them
-- are what keep that safe. Pinning search_path is required: without it a
-- definer function can be hijacked by a caller's search_path.

create or replace function public.circle_count(viewer uuid, event uuid)
returns integer
language plpgsql stable
security definer
set search_path = public
as $$
declare
  total integer;
  circle integer;
begin
  select count(*) into total
  from public.attendances
  where event_id = event and status in ('going','attended');

  if total < 10 then
    return null;                       -- too thin to show any number
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

  if circle < 3 then
    return 0;                          -- app says "a few people", never a number
  end if;

  return circle;
end $$;

create or replace function public.attended_count(viewer uuid)
returns integer
language sql stable
security definer
set search_path = public
as $$
  select count(*)::integer from public.attendances
  where user_id = viewer and status = 'attended';
$$;

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

-- search_venues only ever touches venues, which is publicly readable, so
-- invoker is correct there. Left as is.

-- ── 3. lock down who may call what ───────────────────────────────
revoke all on function public.decay_unconfirmed(interval) from anon, authenticated;
revoke all on function public.circle_count(uuid, uuid)     from anon, authenticated;
-- circle_count is reachable through feed(), which is the only intended
-- entry point. Calling it directly would let someone probe a single event.

grant execute on function public.feed(uuid, text, timestamptz, integer) to anon;
grant execute on function public.attended_count(uuid)                    to anon;
grant execute on function public.search_venues(text, double precision, double precision, text, integer) to anon;
