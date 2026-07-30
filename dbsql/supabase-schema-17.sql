-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 17
--
--   the handle vocabulary moves out of index.html
--
-- Run after 16. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── the problem being fixed ───────────────────────────────────────
-- Handles came from two 30-word arrays hardcoded in index.html. That is
-- 900 possible names, and ensureUser() gave up after 4 collisions —
-- so at a few hundred accounts a real share of new devices would fail
-- to get a users row at all.
--
-- The failure was silent and expensive: with no user row, CURRENT_USER
-- .id stays null, and every attendance write, every community signal
-- and every ownership claim is skipped without an error.
--
-- Two things change here. The vocabulary lives in a table, so it grows
-- with an INSERT instead of a deploy. And the DATABASE picks the name,
-- because it is the only party that knows what is already taken —
-- collision handling belongs where uniqueness is enforced, not in a
-- retry loop on a phone.

create table if not exists public.handle_words (
  word     text primary key,
  part     text not null check (part in ('a','b')),
  active   boolean not null default true
);

alter table public.handle_words enable row level security;

-- Readable so the client can keep an offline fallback list. There is
-- nothing sensitive here: it is a word list.
drop policy if exists "words are public" on public.handle_words;
create policy "words are public" on public.handle_words for select to anon using (true);

-- The original 60, so nobody's existing handle stops being valid.
insert into public.handle_words (word, part) values
  ('slide','a'),('oak','a'),('wisp','a'),('bram','a'),('linen','a'),
  ('clove','a'),('flint','a'),('moss','a'),('rye','a'),('sage','a'),
  ('vale','a'),('dusk','a'),('reed','a'),('dune','a'),('ivy','a'),
  ('silk','a'),('wren','a'),('plume','a'),('tide','a'),('cove','a'),
  ('elm','a'),('fawn','a'),('glen','a'),('heath','a'),('jade','a'),
  ('lark','a'),('marsh','a'),('nook','a'),('onyx','a'),('pine','a'),
  ('tem','b'),('fern','b'),('toad','b'),('lin','b'),('star','b'),
  ('blue','b'),('hum','b'),('low','b'),('dim','b'),('spar','b'),
  ('tune','b'),('wave','b'),('rest','b'),('glow','b'),('flow','b'),
  ('cast','b'),('tide','b'),('hush','b'),('arc','b'),('vow','b'),
  ('peak','b'),('calm','b'),('wild','b'),('soft','b'),('near','b'),
  ('far','b'),('quill','b'),('myrrh','b'),('seam','b'),('flax','b')
on conflict (word) do nothing;

-- Widening the pool. Every word is 3-5 lowercase letters because the
-- users insert policy enforces '^[a-z]{3,5} [a-z]{3,5}$' — a longer
-- word here would generate handles the database then refuses.
insert into public.handle_words (word, part) values
  ('birch','a'),('gorse','a'),('kelp','a'),('loam','a'),('myrtle'
    ,'a'),('slate','a'),('thyme','a'),('umber','a'),('yarn','a'),('zest','a'),
  ('brine','a'),('chalk','a'),('drift','a'),('ember','a'),('frost','a'),
  ('grove','a'),('husk','a'),('inlet','a'),('juno','a'),('kiln','a'),
  ('amber','b'),('bloom','b'),('crest','b'),('dawn','b'),('echo','b'),
  ('fold','b'),('gale','b'),('haze','b'),('iris','b'),('jetty','b'),
  ('lull','b'),('mist','b'),('north','b'),('opal','b'),('pearl','b'),
  ('quiet','b'),('reef','b'),('shade','b'),('trace','b'),('verve','b')
on conflict (word) do nothing;

-- 'myrtle' is six letters and would generate a handle the users policy
-- rejects. Remove anything that cannot pass.
delete from public.handle_words where word !~ '^[a-z]{3,5}$';


-- ── picking one ───────────────────────────────────────────────────
-- The database picks, because it is the only party that knows what is
-- taken. Tries random pairs first — cheap, and almost always succeeds
-- while the pool is far larger than the number of accounts. Falls back
-- to an exhaustive search of genuinely free combinations, so this
-- cannot fail while any name at all remains.

create or replace function public.pick_handle()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_try text;
  i     integer := 0;
begin
  while i < 12 loop
    select a.word || ' ' || b.word into v_try
    from (select word from public.handle_words where part = 'a' and active
           order by random() limit 1) a,
         (select word from public.handle_words where part = 'b' and active
           order by random() limit 1) b;

    if v_try is null then return null; end if;

    if not exists (select 1 from public.users where handle = v_try) then
      return v_try;
    end if;
    i := i + 1;
  end loop;

  -- Every random attempt collided, so the pool is crowded. Ask for a
  -- free one directly rather than guessing again.
  select a.word || ' ' || b.word into v_try
  from public.handle_words a, public.handle_words b
  where a.part = 'a' and b.part = 'b' and a.active and b.active
    and not exists (
      select 1 from public.users u where u.handle = a.word || ' ' || b.word)
  order by random()
  limit 1;

  return v_try;   -- null only when literally every combination is taken
end $$;

grant execute on function public.pick_handle() to anon;


-- Creates the account in one round trip, name included, so the client
-- never runs a collision retry loop of its own.
create or replace function public.create_account()
returns table (id uuid, handle text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handle text;
  v_id     uuid;
begin
  v_handle := public.pick_handle();
  if v_handle is null then
    raise exception 'no handles left — add words to public.handle_words'
      using errcode = '23505';
  end if;

  insert into public.users (handle) values (v_handle)
  returning users.id into v_id;

  return query select v_id, v_handle;
end $$;

grant execute on function public.create_account() to anon;


-- ── afterwards ────────────────────────────────────────────────────
--   select part, count(*) from public.handle_words group by part;
--   select (select count(*) from public.handle_words where part='a' and active)
--        * (select count(*) from public.handle_words where part='b' and active)
--        as possible_handles;
--   select public.pick_handle();
--
-- Add more words any time, no deploy needed. 3-5 lowercase letters only:
--   insert into public.handle_words (word, part) values ('coral','a');
--
-- Retire a word without breaking anyone already using it:
--   update public.handle_words set active = false where word = 'toad';
