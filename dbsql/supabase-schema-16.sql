-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 16
--
--   let venues picked off the map be saved
--
-- Run after 15. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── the policy that would have blocked this ───────────────────────
-- The venues insert policy allowed only source in ('manual','photo').
-- The venues TABLE has always accepted 'osm' — the check constraint
-- lists it — but row level security is checked as well as the
-- constraint, and it refused.
--
-- So every venue picked from map search would have been rejected at
-- publish, ensureVenue() would have swallowed the error and returned
-- null, and the event would have saved with no venue link. Nothing
-- visible would break: the venue book simply would never grow in any
-- town where the first person used search, which is the exact case
-- this feature exists for.

drop policy if exists "anyone may add a venue" on public.venues;

create policy "anyone may add a venue"
  on public.venues for insert to anon
  with check (
    length(name) between 1 and 200
    and lat between -90 and 90
    and lng between -180 and 180
    -- 'osm' added. The other names in the table's own check constraint
    -- stay out: this app has no foursquare or locationiq integration,
    -- and a policy should permit what exists rather than what might.
    and source in ('manual', 'photo', 'osm')
    -- A place from the map must carry its OSM id. That is what makes
    -- unique(source, source_id) actually deduplicate — with a null id,
    -- Postgres allows unlimited duplicates and the same bar accumulates
    -- a row per publish.
    and (source <> 'osm' or (source_id is not null and length(source_id) between 3 and 64))
  );


-- ── afterwards ────────────────────────────────────────────────────
--   select name, city, source, source_id, use_count
--     from public.venues order by created_at desc limit 20;
--
-- Venues that arrived from the map, and how used they are:
--   select count(*) filter (where source = 'osm')    as from_map,
--          count(*) filter (where source <> 'osm')   as typed_or_photo
--     from public.venues;
