-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 6: sizing communities
--
-- The problem this fixes: every community was seeded with the default
-- radius_km = 25, which is a sensible size for a town and wrong for
-- an island. Mallorca's stored centre is 39.6953, 3.0176; Palma is
-- about 34 km from it. So the app's biggest town resolved to no
-- community at all, and so did Alcudia and Pollenca.
--
-- Run after parts 1-5. Safe to re-run.
-- ════════════════════════════════════════════════════════════════


-- ── 1. say out loud what kind of place each row is ───────────────
-- radius_km alone already encodes this, but only implicitly, and an
-- implicit rule gets broken the first time someone adds a row in a
-- hurry. Naming the scale makes the right radius obvious and lets the
-- check constraint below enforce it.
alter table public.communities
  add column if not exists kind text not null default 'town'
    check (kind in ('town', 'city', 'island', 'region'));

-- Sizes that hold up in practice. A community circle should cover the
-- whole place it names, edge to edge, not just its middle:
--
--   town     15 km   a village and the beaches either side of it
--   city     30 km   the built up area plus its commuter belt
--   island   60 km   Mallorca is ~100 km corner to corner
--   region   80 km   a coastline or valley people treat as one scene
--
-- Deliberately generous. A radius slightly too big pulls in an event
-- from the next village, which is a mild annoyance. A radius slightly
-- too small drops the event out of the feed entirely, which is
-- indistinguishable from the app being broken.
alter table public.communities
  drop constraint if exists community_radius_matches_kind;
alter table public.communities
  add constraint community_radius_matches_kind check (
    radius_km > 0 and radius_km <= 150 and (
      (kind = 'town'   and radius_km between  5 and 25) or
      (kind = 'city'   and radius_km between 15 and 45) or
      (kind = 'island' and radius_km between 25 and 90) or
      (kind = 'region' and radius_km between 30 and 120)
    )
  );


-- ── 2. fix the rows you have ─────────────────────────────────────
update public.communities set kind = 'island', radius_km = 60 where slug = 'mallorca';
update public.communities set kind = 'town',   radius_km = 15 where slug = 'ericeira';
update public.communities set kind = 'city',   radius_km = 30 where slug = 'lisboa';


-- ── 3. nesting is allowed, and resolved by the client ────────────
-- Circles may overlap. The frontend picks the SMALLEST circle that
-- contains the point, so adding a town inside an island automatically
-- takes precedence there without touching the island row:
--
--   insert into public.communities
--     (slug, name, country, centre_lat, centre_lng, radius_km, kind)
--   values ('palma', 'Palma', 'ES', 39.5696, 2.6502, 10, 'town');
--
-- A coordinate in Palma old town then resolves to 'palma'; one in
-- Alcudia still resolves to 'mallorca'. Nothing needs migrating,
-- because old events keep whatever slug they were published with.
--
-- Start island-wide. Split a town out only once that town has enough
-- events that seeing the whole island is noise rather than context.


-- ── 4. find where you should open next ───────────────────────────
-- Events publish with a null community_slug when their pin falls
-- outside every circle. That is not a bug, it is a demand signal:
-- these are the places people are already posting about.
create or replace view public.unplaced_events as
  select
    round(venue_lat::numeric, 1) as lat_bucket,
    round(venue_lng::numeric, 1) as lng_bucket,
    count(*)                     as events,
    min(city)                    as sample_city,
    max(created_at)              as latest
  from public.events
  where community_slug is null
    and venue_lat is not null
    and status = 'live'
  group by 1, 2
  having count(*) >= 2
  order by events desc;

-- Deliberately a view and not an automatic insert. Communities stay
-- hand made: the schema's own warning is that extraction will invent
-- "Ericeira", "ericeira" and "Ericeira coast" as three places inside a
-- week, and a photo's GPS is where the flyer was standing, not
-- necessarily where the event is. Read this monthly, add rows by hand.
