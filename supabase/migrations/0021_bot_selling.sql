-- Migration 0021: the computer-run airlines sell like rivals (spec section 14.15). Each route of a computer-run airline
-- starts with a strategy drawn at random from its airline's mix (G). Every few weeks each route looks at What works where
-- for routes like it and moves to a way of selling that earned clearly more per seat, or now and then tries another way
-- at random. When a player starts flying one of its markets, the airline may fight: that route switches to Fill every seat
-- for some weeks; when a player cuts fares there, it may Follow the market. How likely it fights is the airline's
-- aggression (G).

insert into public.game_params (key, num, note) values
('bot_review_weeks', 4, 'each route of a computer-run airline reviews how it sells this often (weeks)'),
('bot_explore_prob', 0.15, 'at a review, the chance it tries another way of selling at random'),
('bot_switch_gain', 0.08, 'at a review, it moves to a way that earned this much more per seat on routes like it'),
('bot_fight_weeks', 8, 'weeks a computer-run airline keeps fighting a player on a market'),
('bot_follow_cut', 0.10, 'a player fare cut of this share or more on its market may make it follow')
on conflict (key) do update set num = excluded.num, note = excluded.note;

-- each computer-run airline's character (G): how likely it fights, and the mix its routes start from
alter table public.bot_airlines add column aggression numeric not null default 0.5 check (aggression between 0 and 1);
update public.bot_airlines set aggression = case code when 'KOL' then 0.9 when 'BLB' then 0.7 when 'SRW' then 0.4
                                                      when 'MYN' then 0.3 else 0.5 end;
create table public.bot_strategy_mix (
  code     text not null references public.bot_airlines,
  strategy text not null references public.rm_strategies,
  weight   numeric not null check (weight > 0),
  primary key (code, strategy)
);
insert into public.bot_strategy_mix values
('SRW', 'top', 0.5), ('SRW', 'balanced', 0.3), ('SRW', 'follow', 0.2),
('KOL', 'fill', 0.6), ('KOL', 'follow', 0.2), ('KOL', 'balanced', 0.2),
('BLB', 'follow', 0.5), ('BLB', 'fill', 0.3), ('BLB', 'balanced', 0.2),
('MYN', 'balanced', 0.6), ('MYN', 'top', 0.4),
('HRN', 'balanced', 0.5), ('HRN', 'follow', 0.3), ('HRN', 'top', 0.2),
('FLM', 'balanced', 0.4), ('FLM', 'top', 0.3), ('FLM', 'fill', 0.3);
alter table public.bot_strategy_mix enable row level security;
revoke all on public.bot_strategy_mix from anon, authenticated;
grant select on public.bot_strategy_mix to authenticated;
create policy read_admin on public.bot_strategy_mix for select to authenticated   -- admins only: players cannot read a rival's mix
  using (exists (select 1 from public.profiles where user_id = (select auth.uid()) and is_admin));

alter table public.route_plans
  add column prev_strategy text references public.rm_strategies,   -- what a fighting route goes back to
  add column fight_until int;                                       -- the week a fight ends

-- a strategy drawn from a computer-run airline's mix
create or replace function game.bot_pick(p_code text) returns text
language sql volatile set search_path = '' as $$
  select coalesce((select strategy from (
            select strategy, sum(weight) over (order by strategy) as c, sum(weight) over () as t
              from public.bot_strategy_mix where code = p_code) x
          where x.c >= r.v * x.t order by x.c limit 1), 'balanced')
    from (select random() as v) r
$$;

-- Redefined from 0020: a new route of a computer-run airline draws its strategy from the airline's mix.
create or replace function game.route_plan_new() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.route_plans (route_id, airline_id, strategy)
  select new.id, new.airline_id, coalesce((select game.bot_pick(al.code) from public.airlines al where al.id = new.airline_id and al.is_ai), 'balanced')
  on conflict do nothing;
  return null;
end $$;
update public.route_plans pl set strategy = game.bot_pick(al.code)
  from public.airlines al where al.id = pl.airline_id and al.is_ai;

-- The computer-run airlines' choices, at the start of each week before its selling.
create or replace function game.bot_selling(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  v_w int := game.week_of(p_day);
  g record;
begin
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    bot_review_weeks int, bot_explore_prob float8, bot_switch_gain float8, bot_fight_weeks int, bot_follow_cut float8);

  -- last week a player started flying one of its markets (it may fight with low fares) or cut fares there (it may follow)
  with mv as (
    select distinct on (m.a, m.b) m.a, m.b, case when m.kind = 'enter' then 'fill' else 'follow' end as answer
      from public.market_moves m join public.airlines al on al.id = m.airline_id and not al.is_ai
     where m.world_id = p_world and m.week = v_w - 1
       and (m.kind = 'enter' or (m.kind = 'fare_down' and m.new_value <= m.old_value * (1 - g.bot_follow_cut)))
     order by m.a, m.b, case when m.kind = 'enter' then 0 else 1 end)
  update public.route_plans pl
     set prev_strategy = pl.strategy, strategy = mv.answer, fight_until = v_w + g.bot_fight_weeks
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.is_ai and al.status = 'active'
    join public.bot_airlines b on b.code = al.code
    join mv on mv.a = least(r.origin, r.dest) and mv.b = greatest(r.origin, r.dest)
   where pl.route_id = r.id and r.world_id = p_world and r.status = 'open' and pl.fight_until is null
     and random() < b.aggression;

  -- reviews, a few routes each week: move to a way that earned clearly more per seat than its own way on routes like it
  -- (What works where), or now and then try another way at random
  with own as (
    select x.route_id, m.a, m.b, m.km, m.intl,
           sum(x.rev_flown_e + x.rev_flown_b) / nullif(sum((x.seats_e + x.seats_b) * m.ref_fare), 0) as idx
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where x.world_id = p_world and x.flown_e is not null and x.week >= v_w - 8
     group by x.route_id, m.a, m.b, m.km, m.intl),
  shp as (select a, b, count(*) as n from public.market_watch where world_id = p_world and trips > 0 group by a, b),
  cand as (
    select pl.route_id, pl.strategy, o.idx,
           case when o.intl then 'intl' when o.km < 800 then 'short' when o.km < 1800 then 'medium' else 'long' end as band,
           case when coalesce(s.n, 1) <= 1 then 'alone' when s.n = 2 then 'two' when s.n <= 4 then 'few' else 'many' end as shape
      from public.route_plans pl
      join public.routes r on r.id = pl.route_id and r.world_id = p_world and r.status = 'open'
      join public.airlines al on al.id = r.airline_id and al.is_ai and al.status = 'active'
      join own o on o.route_id = pl.route_id
      left join shp s on s.a = o.a and s.b = o.b
     where pl.fight_until is null and (v_w + abs(hashtext(pl.route_id::text))) % greatest(1, g.bot_review_weeks) = 0),
  best as (
    select distinct on (c.route_id) c.route_id, si.strategy, si.rev_index
      from cand c join public.sector_insights si on si.world_id = p_world and si.band = c.band and si.shape = c.shape
     order by c.route_id, si.rev_index desc),
  -- how its own way did on routes like it (or, with too few such routes, how the route itself did)
  mine as (
    select c.route_id, coalesce(si.rev_index, c.idx, 0) as v
      from cand c left join public.sector_insights si on si.world_id = p_world and si.band = c.band and si.shape = c.shape
                                                     and si.strategy = c.strategy),
  pick as (
    select c.route_id,
           case when b.strategy is not null and b.strategy <> c.strategy and b.rev_index > mi.v * (1 + g.bot_switch_gain)
                then b.strategy
                when random() < g.bot_explore_prob
                then (select k.key from public.rm_strategies k where k.key <> c.strategy order by random() limit 1)
                else c.strategy end as s
      from cand c join mine mi on mi.route_id = c.route_id left join best b on b.route_id = c.route_id)
  update public.route_plans pl set strategy = p.s from pick p where pl.route_id = p.route_id and pl.strategy <> p.s;

  -- fights that are over: back to the way it sold before (after the reviews, so its first week back is not reviewed)
  update public.route_plans pl set strategy = coalesce(pl.prev_strategy, pl.strategy), prev_strategy = null, fight_until = null
    from public.routes r
   where r.id = pl.route_id and r.world_id = p_world and pl.fight_until is not null and pl.fight_until <= v_w;
end $$;

-- Redefined from 0019: the computer-run airlines choose how to sell before each week of selling.
create or replace function game.run_day(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_day int;
  v_ffd int;   -- first day of flights in this world (0018); before it, nothing flies and nothing is priced
begin
  perform pg_advisory_xact_lock(hashtextextended('day:' || p_world, 0));
  select * into rw from public.worlds where id = p_world for update;
  if not found or rw.status <> 'running' or rw.game_day >= rw.season_days then return null; end if;
  v_day := rw.game_day + 1;
  v_ffd := rw.prelaunch_weeks * 7 + 1;
  if rw.game_day = 0 then perform game.bot_seed(p_world); perform game.pilot_seed(p_world, v_day); end if;
  perform game.day_world(p_world, v_day);
  perform game.day_fleet(p_world, v_day);
  if v_day >= v_ffd and not rw.selling then perform game.bot_prices(p_world, v_day); end if;
  perform game.day_pilots(p_world, v_day);
  if rw.selling and (v_day - 1) % 7 = 0 then   -- a week of selling (0019), after the computer-run airlines' choices (0021)
    perform game.bot_selling(p_world, v_day);
    perform game.sell_week(p_world, v_day);
  end if;
  perform game.day_ops(p_world, v_day);
  if v_day % 91 = 0 and v_day >= v_ffd then
    perform game.day_quarter(p_world, v_day);
    perform game.bot_quarter(p_world, v_day);
  end if;
  perform game.day_solvency(p_world, v_day);
  update public.worlds set game_day = v_day, status = case when v_day >= season_days then 'ended' else status end
   where id = p_world;
  if v_day >= rw.season_days then
    insert into public.news (world_id, game_day, kind, body) values (p_world, v_day, 'season', 'The season has ended.');
  end if;
  return v_day;
end $$;

-- The admin tunes a computer-run airline's character: aggression (0 to 1) and the mix its new routes start from.
create or replace function public.admin_set_bot(p_code text, p_aggression numeric, p_mix jsonb default null) returns void
language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  perform game.require_admin();
  if not exists (select 1 from public.bot_airlines where code = p_code) then raise exception 'No such airline'; end if;
  if p_aggression is not null then
    if p_aggression < 0 or p_aggression > 1 then raise exception 'Aggression runs from 0 to 1'; end if;
    update public.bot_airlines set aggression = p_aggression where code = p_code;
  end if;
  if p_mix is not null then
    for k in select jsonb_object_keys(p_mix) loop
      if not exists (select 1 from public.rm_strategies where key = k) then raise exception 'Unknown strategy %', k; end if;
    end loop;
    if (select coalesce(sum(e.v::numeric), 0) from jsonb_each_text(p_mix) e(k, v)) <= 0 then
      raise exception 'The mix needs at least one weight above 0';
    end if;
    delete from public.bot_strategy_mix where code = p_code;
    insert into public.bot_strategy_mix (code, strategy, weight)
    select p_code, e.k, e.v::numeric from jsonb_each_text(p_mix) e(k, v) where e.v::numeric > 0;
  end if;
end $$;

-- The admin changes a game value (G) by name: it counts from the next game day processed.
create or replace function public.admin_set_param(p_key text, p_num numeric) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_admin();
  if p_num is null then raise exception 'Give a number'; end if;
  update public.game_params set num = p_num where key = p_key;
  if not found then raise exception 'No such game value: %', p_key; end if;
end $$;

revoke all on function game.bot_pick(text), game.bot_selling(uuid, int), game.route_plan_new(), game.run_day(uuid)
  from public, anon, authenticated;
revoke all on function public.admin_set_bot(text, numeric, jsonb), public.admin_set_param(text, numeric) from public, anon;
grant execute on function public.admin_set_bot(text, numeric, jsonb), public.admin_set_param(text, numeric) to authenticated, service_role;
