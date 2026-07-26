-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 10: Bali
--
-- Seeded from a real photo: EXIF -8.812219, 115.113167, which is
-- Pererenan on the Canggu coast.
--
-- Run after parts 1-9. Safe to re-run.
-- ════════════════════════════════════════════════════════════════


-- ── the island ───────────────────────────────────────────────────
-- Centre is the island's geometric middle rather than any one town,
-- because the radius has to reach Canggu in the south west, Ubud
-- inland and Amed in the east from the same point. Bali is about
-- 145 km across and 80 km tall; 80 km of radius covers everywhere
-- anyone would call Bali and stops short of Lombok.
--
-- kind = 'island' matters beyond bookkeeping: community_reach sets
-- may_widen = false for islands, so the feed shows the whole island
-- and never widens past the coast into open water.
insert into public.communities
  (slug, name, country, centre_lat, centre_lng, radius_km, kind)
values
  ('bali', 'Bali', 'ID', -8.4095, 115.1889, 80, 'island')
on conflict (slug) do update
  set centre_lat = excluded.centre_lat,
      centre_lng = excluded.centre_lng,
      radius_km  = excluded.radius_km,
      kind       = excluded.kind,
      is_active  = true;

-- Check the photo lands where it should. Expect roughly 45 km, well
-- inside the radius, so a flyer shot in Pererenan resolves to 'bali'.
--   select slug, round((6371 * acos(
--     sin(radians(-8.812219)) * sin(radians(centre_lat)) +
--     cos(radians(-8.812219)) * cos(radians(centre_lat)) *
--     cos(radians(centre_lng - 115.113167))))::numeric, 1) as km
--   from public.communities where slug = 'bali';


-- ── the venue ────────────────────────────────────────────────────
-- Seeding this by hand does two things beyond saving one pin drop.
-- venuesNear() hands the name to the model as a candidate, which
-- turns reading a stylised logo from open transcription into multiple
-- choice; and once venue_match comes back, the stored coordinates
-- become the event's pin with no user input at all.
--
-- Coordinates are the photo's own GPS. Replace them with the actual
-- door if you know it better - a flyer is usually photographed in the
-- building it advertises, but "usually" is doing real work there.
insert into public.venues
  (name, address, lat, lng, city, community_slug, source, verified)
values
  ('The Space', 'Pererenan, Canggu', -8.812219, 115.113167, 'Canggu', 'bali', 'manual', true)
on conflict do nothing;

-- venues_guard from part 4 forces use_count = 0 and verified = false
-- on insert, so set verified afterwards rather than in the values.
update public.venues set verified = true
 where name = 'The Space' and community_slug = 'bali';


-- ── did it work ──────────────────────────────────────────────────
--   select name, city, lat, lng, use_count, verified
--   from public.venues where community_slug = 'bali';
--
--   select * from public.community_reach where slug = 'bali';
--   -- may_widen must be false, max_radius_km must equal radius_km
