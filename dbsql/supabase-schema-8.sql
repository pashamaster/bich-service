-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 8: short links
--
-- gen_short_id() produced a fixed 8 characters. This makes it start
-- at 5 and grow only when it has to, so early links are as short as
-- they can safely be and later ones stay unique without a rewrite.
--
-- Existing 8 character ids keep working. Nothing is migrated: a share
-- link that is already out in the world must never stop resolving.
--
-- Run after parts 1-7. Safe to re-run.
-- ════════════════════════════════════════════════════════════════


-- ── words a code must never be ───────────────────────────────────
-- Codes now sit at the root of the domain (bich.app/a3f9k), so a
-- generated code could in principle collide with a real path. Most
-- are impossible anyway because the alphabet drops l, o, 0 and 1 -
-- "icons" and "config" cannot be generated. "index", "admin" and
-- "events" can.
create table if not exists public.reserved_slugs (word text primary key);

insert into public.reserved_slugs (word) values
  ('index'), ('admin'), ('terms'), ('privacy'), ('events'), ('event'),
  ('share'), ('static'), ('assets'), ('images'), ('media'), ('search'),
  ('signin'), ('signup'), ('invite'), ('report'), ('legal'), ('press'),
  ('status'), ('health'), ('feed'), ('venue'), ('venues'), ('users'),
  ('user'), ('me'), ('new'), ('map'), ('api'), ('app'), ('www')
on conflict (word) do nothing;

alter table public.reserved_slugs enable row level security;
-- No policies: only the definer function below reads it.


-- ── the generator ────────────────────────────────────────────────
-- Start at five characters. The alphabet is 32 symbols, so five gives
-- 33.5 million codes and a first-try collision is vanishingly rare
-- while the table is small. Rather than counting rows on every insert
-- (a scan, on the hot path), let collisions do the tuning: four in a
-- row means the space is crowded, so take another character.
--
--   5 chars   32^5 =        33,554,432
--   6 chars   32^6 =     1,073,741,824
--   7 chars   32^7 =    34,359,738,368
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

alter table public.events alter column short_id set default public.gen_short_id();

-- guard_event_defaults() in part 4 already fills short_id when a
-- client omits it, and calls this same function, so it needs no change.


-- ── how crowded is it actually? ──────────────────────────────────
-- Read this occasionally. If p_used climbs past a percent or so at
-- any length, collisions are about to become common at that length
-- and the generator will start reaching for the next one on its own.
create or replace view public.short_id_pressure as
  select
    length(short_id)                                   as len,
    count(*)                                           as issued,
    power(32, length(short_id))::bigint                as space,
    round(100.0 * count(*) / power(32, length(short_id)), 6) as p_used
  from public.events
  group by length(short_id)
  order by len;


-- ── note on guessability ─────────────────────────────────────────
-- Five characters is 33.5 million combinations, which is scannable by
-- anyone determined. That is not a new exposure: events are already
-- world readable by design ("live events are public" in part 1), so a
-- short code is a convenience, not a secret.
--
-- It does mean the whole feed can be enumerated. If unlisted events
-- ever become a feature, they need their own long random token in a
-- separate column, NOT a longer short_id - mixing the two would make
-- link length quietly imply privacy.
