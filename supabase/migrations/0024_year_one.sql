-- Migration 0024 (spec 14.18): year-one fixes, each a real-world mechanism. Owner's target (20 Nov 2026): losses in the first
-- years are normal and drive players to optimise, but they must come from decisions, not dice.
--  A. Groundings at real rates (about 1% of flights cancelled; DGCA reports 1.0 to 1.3% in normal 2025 months).
--  B. Fuel shocks and engine events about once in three years each (they started about 1.5 and 0.7 times a year).
--  C. Computer-run airlines review their routes every quarter from their first (they waited a year to drop a starting route).
--  D. Their networks are sized to the world: each route's flights scaled to its demand (at least 3 a week, thinner routes are
--     left out), whole aircraft per base, and aircraft shared between routes. Before, every scaled-down route got its own
--     part-used aircraft, which paid full rent.
--  E. Capacity follows each route's profit after flying and aircraft costs, not only how full it is (cheap selling fills
--     aircraft and hides losses): losing routes lose flights, earning full routes gain them, idle aircraft move to where they
--     are needed, then one is kept as a spare at a big base and the rest go back to the lessors (they leave the world: principle 6).
--  F. When a player enters, a fighting computer-run airline matches the market instead of filling every seat, and it never
--     sells economy below the fare that covers the route's flying and aircraft costs at 80% full.
--  G. Fares follow a third of a change in fuel cost, a few weeks late (IndiGo's fuel charges pass on part of a rise).
-- Older checks keep the old behaviour through bot_plan 0, bot_sell_floor_lf 0, bot_fight_follow 0 and fuel_pass 0.

-- ---------- game values ----------
update public.game_params set num = 0.0015 where key = 'ground_prob_day';          -- was 0.004
update public.game_params set num = 0.001 where key = 'event_fuel_prob_day';       -- was 0.004
update public.game_params set num = 0.001 where key = 'event_engine_prob_day';     -- was 0.002
update public.game_params set num = 91 where key = 'bot_drop_min_days';            -- was 364
insert into public.game_params (key, num, note) values
('bot_plan', 1, 'computer-run airlines plan each route''s weekly flights and share aircraft between routes (0024); 0 = one route per aircraft, as before'),
('bot_min_weekly', 3, 'fewest round trips a week a computer-run airline flies on a route; thinner routes are left out'),
('bot_cut_margin', -0.05, 'a computer-run route whose result over 28 days, after flying and aircraft costs, is below this share of its revenue loses flights'),
('bot_cut_share', 0.25, 'the share of its flights it loses each quarter'),
('bot_grow_margin', 0.05, 'a computer-run route earning more than this share of its revenue, and fuller than bot_grow_lf, gains flights: profits attract capacity'),
('bot_grow_lf', 0.80, 'load factor over 28 days above which an earning computer-run route gains flights'),
('bot_grow_share', 0.25, 'the share of flights it gains each quarter'),
('bot_grow_adds', 3, 'new aircraft a computer-run airline may add in a quarter for routes that grew (within the fleet cap)'),
('bot_enter_weekly', 14, 'round trips a week a computer-run airline starts with when it contests a player route'),
('bot_spare_min', 8, 'a computer-run base with this many aircraft of one type and cabin keeps one idle aircraft as a spare'),
('bot_return_share', 0.10, 'the most of its fleet a computer-run airline hands back to the lessors in a quarter (at least 2)'),
('bot_sell_floor_lf', 0.80, 'computer-run airlines never sell economy below the fare that covers a route''s flying and aircraft costs at this load factor (0: no floor)'),
('bot_floor_anc', 0.08, 'extras earned per rupee of fare, counted in that floor'),
('bot_fight_follow', 1, 'when a player enters its market, a fighting computer-run airline matches the market (1) or fills every seat (0)'),
('fuel_pass', 0.33, 'share of a change in fuel cost per passenger that fares follow'),
('fuel_fare_share', 0.38, 'fuel cost per passenger as a share of the reference fare, at the reference fuel price'),
('fuel_fare_smooth', 0.25, 'each week, fares move this share of the way towards the current fuel price (a lag of about four weeks)');

-- G: the fuel price fares follow, and the fare index it gives (public, like the fuel price)
alter table public.worlds add column fuel_avg numeric, add column fare_index numeric not null default 1;
update public.worlds set fuel_avg = fuel_inr_kg;

-- ---------- D, E: computer-run airlines plan their routes and share aircraft ----------
create table game.bot_plan (
  route_id   uuid primary key references public.routes on delete cascade,
  airline_id uuid not null references public.airlines on delete cascade,
  trips      int not null check (trips >= 0),      -- planned round trips a week
  type_id    text not null, biz_rows int not null, biz_pitch int, econ_pitch int not null,   -- the aircraft that fly it
  base       text not null,                         -- where those aircraft are based
  since_day  int not null default 0                 -- day it joined the plan: new routes are not reviewed for bot_exit_min_days
);
create index bot_plan_airline_idx on game.bot_plan (airline_id);
create table game.bot_start (airline_id uuid primary key references public.airlines on delete cascade, aircraft int not null);

-- running worlds: each open computer-run route keeps its flights, flown by the type and cabin that flies most of them
insert into game.bot_plan (route_id, airline_id, trips, type_id, biz_rows, biz_pitch, econ_pitch, base, since_day)
select distinct on (r.id) r.id, r.airline_id, (select sum(x.weekly_trips) from public.rotations x where x.route_id = r.id),
       a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch, a.base_iata, r.opened_day
  from public.routes r
  join public.airlines al on al.id = r.airline_id and al.is_ai
  join public.rotations ro on ro.route_id = r.id
  join public.aircraft a on a.id = ro.aircraft_id
 where r.status = 'open'
 order by r.id, ro.weekly_trips desc;
insert into game.bot_start (airline_id, aircraft)
select al.id, game.bot_start_fleet(al.world_id, al.code) from public.airlines al where al.is_ai;

-- the old ways stay for the older checks (bot_plan 0)
alter function game.bot_seed(uuid) rename to bot_seed_v1;
alter function game.bot_quarter(uuid, int) rename to bot_quarter_v1;
alter function game.bot_enter(uuid, int) rename to bot_enter_v1;
alter function game.bot_exit(uuid, int) rename to bot_exit_v1;

-- round trips a week one aircraft of this type and cabin fits on a route (as game.fit_trips, without an aircraft)
create or replace function game.bot_fit(p_type text, p_biz_rows int, p_biz_pitch int, p_econ_pitch int, p_km numeric) returns int
language sql stable set search_path = '' as $$
  select greatest(1, least(84, floor(game.param('bot_window_use') * 7 * t.day_window_h
                                     / (2 * (p_km / t.cruise_kmh + t.block_offset_h + l.min_turn_min / 60))))::int)
    from public.aircraft_types t, public.layout_calc(p_type, p_biz_rows, p_biz_pitch, p_econ_pitch) l
   where t.id = p_type
$$;

-- a route's result over the last 28 days, after its flying costs and its share of aircraft costs, as a share of its revenue
create or replace function game.bot_margin(p_route uuid, p_day int) returns float8
language sql stable set search_path = '' as $$
  select ((sum(d.revenue_inr) - sum(d.var_cost_inr + d.aircraft_cost_inr)) / nullif(sum(d.revenue_inr), 0))::float8
    from public.route_daily d where d.route_id = p_route and d.game_day > p_day - 28
$$;

-- the most aircraft a computer-run airline may have: bot_fleet_max_mult times its starting fleet
create or replace function game.bot_fleet_cap(p_airline uuid) returns int
language sql stable set search_path = '' as $$
  select (game.param('bot_fleet_max_mult') * coalesce((select s.aircraft from game.bot_start s where s.airline_id = al.id),
                                                       game.bot_start_fleet(al.world_id, al.code)))::int
    from public.airlines al where al.id = p_airline
$$;

-- Puts an airline's planned flights on its aircraft, base by base and by type and cabin: each route in turn (the biggest first)
-- fills the first aircraft with time left, so the flights use as few aircraft as they need and the rest stay idle. Grounded
-- aircraft are filled last. Flights that do not fit come off the plan. Returns the round trips that did not fit.
create or replace function game.bot_pack(p_airline uuid) returns int
language plpgsql set search_path = '' as $$
declare
  grp record; r record;
  v_ids uuid[]; v_cap float8[]; v_left int; v_k int; v_short int := 0;
begin
  for grp in select distinct p.base, p.type_id, p.biz_rows, coalesce(p.biz_pitch, 0) as bp, p.econ_pitch
               from game.bot_plan p where p.airline_id = p_airline loop
    v_ids := array(select x.id from public.aircraft x
                    where x.airline_id = p_airline and x.status in ('active', 'grounded') and x.base_iata = grp.base
                      and x.type_id = grp.type_id and x.biz_rows = grp.biz_rows and coalesce(x.biz_pitch, 0) = grp.bp
                      and x.econ_pitch = grp.econ_pitch
                    order by (x.status = 'grounded'), x.id);
    v_cap := array_fill(1.0::float8, array[greatest(1, coalesce(array_length(v_ids, 1), 0))]);
    delete from public.rotations where aircraft_id = any (v_ids);
    for r in
      select p.route_id, p.trips, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km) as fit
        from game.bot_plan p join public.routes rt on rt.id = p.route_id
        join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
       where p.airline_id = p_airline and p.base = grp.base and p.type_id = grp.type_id and p.biz_rows = grp.biz_rows
         and coalesce(p.biz_pitch, 0) = grp.bp and p.econ_pitch = grp.econ_pitch and p.trips > 0
       order by p.trips::float8 / greatest(1, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km)) desc, p.route_id
    loop
      delete from public.rotations where route_id = r.route_id;   -- any other aircraft that flew it before
      v_left := r.trips;
      for i in 1..coalesce(array_length(v_ids, 1), 0) loop
        exit when v_left = 0;
        v_k := least(v_left, floor(v_cap[i] * r.fit + 1e-6)::int);
        if v_k >= 1 then
          insert into public.rotations (aircraft_id, route_id, weekly_trips) values (v_ids[i], r.route_id, v_k);
          v_cap[i] := v_cap[i] - v_k::float8 / r.fit;
          v_left := v_left - v_k;
        end if;
      end loop;
      if v_left > 0 then
        update game.bot_plan set trips = trips - v_left where route_id = r.route_id;
        v_short := v_short + v_left;
      end if;
    end loop;
  end loop;
  return v_short;
end $$;

-- Fits an airline's plan to its aircraft. A base that needs more aircraft of a type and cabin first takes idle ones from other
-- bases; at a quarter end it may then add new ones for routes that grew (bot_grow_adds, within the fleet cap). Plans that still
-- do not fit are trimmed, worst-earning route first and routes new to the plan last, down to bot_min_weekly and then off.
-- The flights are packed onto the aircraft; at a quarter end idle aircraft are kept as one spare at a big base and the rest
-- handed back (at most bot_return_share of the fleet a quarter): they leave the world (principle 6). Returns the changes made.
create or replace function game.bot_balance(p_airline uuid, p_day int, p_quarter boolean) returns int
language plpgsql set search_path = '' as $$
declare
  grp record; r record; a record;
  v_world uuid; v_need int; v_have int; v_excess float8; v_cut int; v_ac uuid; v_n int := 0; v_adds int := 0;
  v_ret int := 0; v_ret_max int; v_min int := game.param('bot_min_weekly')::int;
begin
  select world_id into v_world from public.airlines where id = p_airline;
  create temp table if not exists _bot_grow (route_id uuid primary key) on commit drop;
  drop table if exists pg_temp._bg;
  create temp table _bg on commit drop as
  select p.base, p.type_id, p.biz_rows, coalesce(p.biz_pitch, 0) as bp, max(p.biz_pitch) as biz_pitch, p.econ_pitch,
         sum(p.trips::float8 / game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km)) as need,
         bool_or(p.route_id in (select g.route_id from pg_temp._bot_grow g)) as grew
    from game.bot_plan p join public.routes rt on rt.id = p.route_id
    join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
   where p.airline_id = p_airline and p.trips > 0
   group by p.base, p.type_id, p.biz_rows, coalesce(p.biz_pitch, 0), p.econ_pitch;

  for grp in select * from pg_temp._bg order by need desc loop
    v_need := ceil(grp.need - 1e-6)::int - (select count(*) from public.aircraft x
                 where x.airline_id = p_airline and x.status in ('active', 'grounded') and x.base_iata = grp.base
                   and x.type_id = grp.type_id and x.biz_rows = grp.biz_rows and coalesce(x.biz_pitch, 0) = grp.bp
                   and x.econ_pitch = grp.econ_pitch);
    -- idle aircraft of the same type and cabin at a base that has more than it needs
    while v_need > 0 loop
      select x.id into v_ac from public.aircraft x
       where x.airline_id = p_airline and x.status = 'active' and x.base_iata <> grp.base and x.type_id = grp.type_id
         and x.biz_rows = grp.biz_rows and coalesce(x.biz_pitch, 0) = grp.bp and x.econ_pitch = grp.econ_pitch
         and (select count(*) from public.aircraft y
               where y.airline_id = p_airline and y.status in ('active', 'grounded') and y.base_iata = x.base_iata
                 and y.type_id = x.type_id and y.biz_rows = x.biz_rows and coalesce(y.biz_pitch, 0) = coalesce(x.biz_pitch, 0)
                 and y.econ_pitch = x.econ_pitch)
             > coalesce((select ceil(b.need - 1e-6) from pg_temp._bg b
                          where b.base = x.base_iata and b.type_id = x.type_id and b.biz_rows = x.biz_rows
                            and b.bp = coalesce(x.biz_pitch, 0) and b.econ_pitch = x.econ_pitch), 0)
       order by (select count(*) from public.rotations ro where ro.aircraft_id = x.id), x.id
       limit 1;
      exit when not found;
      begin
        delete from public.rotations where aircraft_id = v_ac;
        perform public.rebase_aircraft(p_airline, v_ac, grp.base);
        v_need := v_need - 1; v_n := v_n + 1;
      exception when others then
        exit;
      end;
    end loop;
    -- new aircraft for routes that grew, from the airline's own orders, at a quarter end
    while p_quarter and grp.grew and v_need > 0 and v_adds < game.param('bot_grow_adds')
          and (select count(*) from public.aircraft where airline_id = p_airline and status in ('active', 'grounded', 'refit', 'delivering'))
              < game.bot_fleet_cap(p_airline) loop
      insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                   biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
      select v_world, grp.type_id, p_airline, game.next_reg(), p_day, 'active', p_day, grp.base,
             grp.biz_rows, grp.biz_pitch, grp.econ_pitch, l.seats_biz, l.seats_econ
        from public.layout_calc(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch,
                                (select crew_rule from public.worlds where id = v_world)) l
      returning id into v_ac;
      insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
      values (v_ac, p_airline, 'lease', game.lease_rent_usd(v_world, grp.type_id, p_day, p_day),
              p_day + game.param('lease_term_days')::int, 0, p_day);
      v_need := v_need - 1; v_adds := v_adds + 1; v_n := v_n + 1;
    end loop;
    -- what still does not fit is trimmed: worst-earning route first, routes new to the plan last
    if v_need > 0 then
      v_have := ceil(grp.need - 1e-6)::int - v_need;
      v_excess := grp.need - v_have;
      for r in
        select p.route_id, p.trips, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km) as fit,
               (p.since_day > p_day - game.param('bot_exit_min_days')) as fresh, game.bot_margin(p.route_id, p_day) as margin
          from game.bot_plan p join public.routes rt on rt.id = p.route_id
          join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
         where p.airline_id = p_airline and p.base = grp.base and p.type_id = grp.type_id and p.biz_rows = grp.biz_rows
           and coalesce(p.biz_pitch, 0) = grp.bp and p.econ_pitch = grp.econ_pitch and p.trips > 0
         order by fresh, margin nulls last, p.trips
      loop
        exit when v_excess <= 1e-6;
        v_cut := least(greatest(0, r.trips - v_min), ceil(v_excess * r.fit - 1e-6)::int);
        if v_cut > 0 then
          update game.bot_plan set trips = trips - v_cut where route_id = r.route_id;
          v_excess := v_excess - v_cut::float8 / r.fit; v_n := v_n + 1;
        end if;
      end loop;
      for r in   -- still too much: routes come off, worst first
        select p.route_id, p.trips, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km) as fit,
               (p.since_day > p_day - game.param('bot_exit_min_days')) as fresh, game.bot_margin(p.route_id, p_day) as margin
          from game.bot_plan p join public.routes rt on rt.id = p.route_id
          join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
         where p.airline_id = p_airline and p.base = grp.base and p.type_id = grp.type_id and p.biz_rows = grp.biz_rows
           and coalesce(p.biz_pitch, 0) = grp.bp and p.econ_pitch = grp.econ_pitch and p.trips > 0
         order by fresh, margin nulls last, p.trips
      loop
        exit when v_excess <= 1e-6;
        update game.bot_plan set trips = 0 where route_id = r.route_id;
        v_excess := v_excess - r.trips::float8 / r.fit; v_n := v_n + 1;
      end loop;
    end if;
  end loop;

  -- the flights go onto the aircraft; routes with no flights left are closed
  perform game.bot_pack(p_airline);
  for r in select p.route_id from game.bot_plan p where p.airline_id = p_airline and p.trips < 1 loop
    perform game.bot_close(p_airline, r.route_id, p_day);
  end loop;

  -- idle aircraft at a quarter end: one spare stays at a big base, the rest go back (they leave the world)
  if p_quarter then
    v_ret_max := greatest(2, ceil(game.param('bot_return_share')
                   * (select count(*) from public.aircraft where airline_id = p_airline and status in ('active', 'grounded', 'refit'))))::int;
    for a in
      select x.id, row_number() over (partition by x.base_iata, x.type_id, x.biz_rows, coalesce(x.biz_pitch, 0), x.econ_pitch
                                      order by tm.lease_end_day desc nulls first, x.id) as k,
             (select count(*) from public.aircraft y
               where y.airline_id = p_airline and y.status in ('active', 'grounded') and y.base_iata = x.base_iata
                 and y.type_id = x.type_id and y.biz_rows = x.biz_rows and coalesce(y.biz_pitch, 0) = coalesce(x.biz_pitch, 0)
                 and y.econ_pitch = x.econ_pitch) as at_base
        from public.aircraft x left join public.aircraft_terms tm on tm.aircraft_id = x.id
       where x.airline_id = p_airline and x.status in ('active', 'grounded')
         and not exists (select 1 from public.rotations ro where ro.aircraft_id = x.id)
       order by tm.lease_end_day nulls last, x.id
    loop
      continue when a.k = 1 and a.at_base >= game.param('bot_spare_min');
      exit when v_ret >= v_ret_max;
      begin
        perform public.return_aircraft(p_airline, a.id);
        update public.aircraft set status = 'returned' where id = a.id and status = 'pool';
        v_ret := v_ret + 1; v_n := v_n + 1;
      exception when others then
        null;
      end;
    end loop;
  end if;
  return v_n;
end $$;

-- a computer-run airline stops flying a route: closed, with public news
create or replace function game.bot_close(p_airline uuid, p_route uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare r record;
begin
  select rt.origin, rt.dest, al.name, al.world_id into r
    from public.routes rt join public.airlines al on al.id = rt.airline_id where rt.id = p_route and rt.status = 'open';
  if not found then return; end if;
  delete from game.bot_plan where route_id = p_route;
  perform public.close_route(p_airline, p_route);
  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  values (r.world_id, p_day, p_airline, 'route',
          format('%s stops flying %s to %s.', r.name, (select city from public.airports where iata = r.origin),
                 (select city from public.airports where iata = r.dest)), false);
end $$;

-- Sets up the computer-run airlines on a world's first day (D). Each starting route's flights are scaled to the world
-- (demand_scale x bot_scale), at least bot_min_weekly a week; thinner routes are left out. Each base gets whole aircraft per
-- type and cabin for the flights there (at least one); where that is fewer than the flights need, every route there flies
-- proportionally fewer. The flights are then packed onto the aircraft, which routes share.
create or replace function game.bot_seed(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  b record; n record; grp record;
  v_day int; v_al uuid; v_route uuid; v_ac uuid; v_built int; v_k int; v_seats numeric; v_count int := 0;
  v_scale numeric; v_min int := game.param('bot_min_weekly')::int;
  v_age numeric := game.param('bot_max_age_years');
  v_term int := game.param('lease_term_days')::int;
begin
  if game.param('bot_plan') = 0 then return game.bot_seed_v1(p_world); end if;
  select * into rw from public.worlds where id = p_world;
  if rw.bot_scale <= 0 or exists (select 1 from public.airlines where world_id = p_world and is_ai) then return 0; end if;
  v_day := rw.game_day + 1;
  v_scale := rw.demand_scale * rw.bot_scale;
  for b in select * from public.bot_airlines order by sort loop
    drop table if exists pg_temp._seed;
    create temp table _seed on commit drop as
    select bn.origin, bn.dest, bn.type_id, bn.biz_rows, bn.biz_pitch, bn.econ_pitch,
           round(bn.aircraft * bn.weekly_trips * v_scale)::int as t,
           game.bot_fit(bn.type_id, bn.biz_rows, bn.biz_pitch, bn.econ_pitch, m.km) as fit
      from public.bot_network bn join public.markets m on m.a = least(bn.origin, bn.dest) and m.b = greatest(bn.origin, bn.dest)
     where bn.code = b.code;
    delete from pg_temp._seed where t < v_min;
    continue when not exists (select 1 from pg_temp._seed);
    v_al := null;
    insert into public.airlines (world_id, is_ai, name, code, created_day)
    values (p_world, true, b.name, b.code, v_day)
    on conflict do nothing returning id into v_al;
    continue when v_al is null;
    insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr) values (v_al, 0, game.param('credit_limit_inr'));
    perform game.book(v_al, v_day, game.param('start_cash_inr'), 'equity', 'Founding equity');
    insert into public.bases (airline_id, iata, opened_day) select distinct v_al, origin, v_day from pg_temp._seed;
    for grp in select s.origin, s.type_id, s.biz_rows, coalesce(s.biz_pitch, 0) as bp, max(s.biz_pitch) as biz_pitch, s.econ_pitch,
                      sum(s.t::float8 / s.fit) as need
                 from pg_temp._seed s group by s.origin, s.type_id, s.biz_rows, coalesce(s.biz_pitch, 0), s.econ_pitch loop
      v_k := greatest(1, round(grp.need))::int;
      if grp.need > v_k then
        update pg_temp._seed s set t = floor(s.t * v_k / grp.need)
         where s.origin = grp.origin and s.type_id = grp.type_id and s.biz_rows = grp.biz_rows
           and coalesce(s.biz_pitch, 0) = grp.bp and s.econ_pitch = grp.econ_pitch;
      end if;
      for i in 1..v_k loop
        v_built := v_day - floor(random() * v_age * 364)::int;
        insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                     biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
        select p_world, grp.type_id, v_al, game.next_reg(), v_built, 'active', v_day, grp.origin,
               grp.biz_rows, case when grp.biz_rows > 0 then coalesce(grp.biz_pitch, 44) end, grp.econ_pitch, l.seats_biz, l.seats_econ
          from public.layout_calc(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch, rw.crew_rule) l
        returning id into v_ac;
        insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
        values (v_ac, v_al, 'lease', game.lease_rent_usd(p_world, grp.type_id, v_built, v_day),
                v_day + floor(random() * v_term)::int, 0, v_day);
        v_count := v_count + 1;
      end loop;
    end loop;
    v_seats := 0;
    for n in select s.*, l.seats from pg_temp._seed s
               cross join lateral public.layout_calc(s.type_id, s.biz_rows, s.biz_pitch, s.econ_pitch, rw.crew_rule) l
              where s.t >= v_min order by s.t desc, s.origin, s.dest loop
      v_route := public.open_route(v_al, n.origin, n.dest);
      insert into game.bot_plan (route_id, airline_id, trips, type_id, biz_rows, biz_pitch, econ_pitch, base, since_day)
      values (v_route, v_al, n.t, n.type_id, n.biz_rows, case when n.biz_rows > 0 then coalesce(n.biz_pitch, 44) end, n.econ_pitch,
              n.origin, v_day);
      v_seats := v_seats + n.t * n.seats * 2 / 7.0;
    end loop;
    insert into game.bot_start (airline_id, aircraft)
    values (v_al, (select count(*) from public.aircraft where airline_id = v_al));
    perform game.bot_pack(v_al);
    delete from game.bot_plan where airline_id = v_al and trips < 1;
    perform public.set_marketing(v_al, least(game.param('marketing_max_inr_day'), round(b.mkt_inr_pax * 0.85 * v_seats)));
  end loop;
  insert into public.news (world_id, game_day, kind, body)
  select p_world, v_day, 'world', 'Established airlines in this world: ' || string_agg(al.name, ', ' order by al.name) || '.'
    from public.airlines al where al.world_id = p_world and al.is_ai
  having count(*) > 0;
  return v_count;
end $$;

-- Contesting player routes (14.5), with plans: the new route starts with bot_enter_weekly round trips (or what one aircraft
-- fits), flown by the type and cabin the base has most of that can fly it; the room comes from the airline's own weakest
-- routes at that base (bot_balance). Candidates, entry fare and limits as in 0009.
create or replace function game.bot_enter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; cand record; grp record;
  v_taken text[] := '{}';
  v_n int := 0; v_k int; v_route uuid; v_fare int; v_fit int;
begin
  if game.param('bot_plan') = 0 then return game.bot_enter_v1(p_world, p_day); end if;
  for al in select a.id, a.name, a.code, ba.fare_lo, ba.fare_hi
              from public.airlines a join public.bot_airlines ba on ba.code = a.code
             where a.world_id = p_world and a.is_ai and a.status = 'active' order by a.code loop
    v_k := 0;
    for cand in
      with pr as (   -- city pairs players fly, over the last 28 days
        select least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b,
               sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0) as lf,
               sum(d.revenue_inr) as rev, min(r.fare_econ) as fare
          from public.routes r
          join public.airlines pa on pa.id = r.airline_id and not pa.is_ai and pa.status = 'active'
          join public.route_daily d on d.route_id = r.id and d.game_day > p_day - 28
         where r.world_id = p_world and r.status = 'open' and r.opened_day <= p_day - game.param('bot_enter_min_days')
         group by 1, 2)
      select pr.*, m.km, m.ref_fare, bs.iata as base, case when bs.iata = pr.a then pr.b else pr.a end as other
        from pr
        join public.markets m on m.a = pr.a and m.b = pr.b
        join public.bases bs on bs.airline_id = al.id and bs.iata in (pr.a, pr.b)
       where pr.lf >= game.param('bot_enter_lf') and pr.fare >= game.param('bot_enter_fare_mult') * m.ref_fare
         and not (pr.a || '-' || pr.b = any (v_taken))
         and not exists (select 1 from public.routes x where x.airline_id = al.id and x.status = 'open'
                            and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b)
         and not exists (select 1 from public.routes x join public.airlines xa on xa.id = x.airline_id and xa.is_ai
                          where x.world_id = p_world and x.status = 'closed' and x.opened_day > p_day - game.param('bot_retry_days')
                            and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b)
         and (select count(distinct x.airline_id) from public.routes x
               where x.world_id = p_world and x.status = 'open' and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b
                 and exists (select 1 from public.rotations ro where ro.route_id = x.id)) < game.param('bot_enter_max_airlines')
       order by pr.rev desc
    loop
      exit when v_k >= game.param('bot_enter_qtr');
      select p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch into grp
        from game.bot_plan p
        cross join lateral public.layout_calc(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch) l
       where p.airline_id = al.id and p.base = cand.base and l.range_km >= cand.km
         and (select min(ap.runway_class) from public.airports ap where ap.iata in (cand.a, cand.b))
             >= (select t.runway_class from public.aircraft_types t where t.id = p.type_id)
       group by p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch
       order by sum(p.trips) desc limit 1;
      continue when not found;
      v_fare := round(greatest(al.fare_lo * cand.ref_fare, least(al.fare_hi * cand.ref_fare, cand.fare * game.param('bot_enter_undercut'))));
      v_fit := game.bot_fit(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch, cand.km);
      v_route := public.open_route(al.id, cand.base, cand.other, v_fare);
      insert into game.bot_plan (route_id, airline_id, trips, type_id, biz_rows, biz_pitch, econ_pitch, base, since_day)
      values (v_route, al.id, least(v_fit, game.param('bot_enter_weekly')::int), grp.type_id, grp.biz_rows, grp.biz_pitch,
              grp.econ_pitch, cand.base, p_day);
      perform game.bot_balance(al.id, p_day, false);
      continue when not exists (select 1 from public.rotations ro where ro.route_id = v_route);
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      values (p_world, p_day, al.id, 'route',
              format('%s starts flying %s to %s, against the airlines already there.', al.name,
                     (select city from public.airports where iata = cand.base), (select city from public.airports where iata = cand.other)),
              false);
      v_taken := v_taken || (cand.a || '-' || cand.b);
      v_k := v_k + 1; v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

-- Giving up routes, with plans: a contested route that stays empty (0009) and a starting route that does not pay its way
-- (0016, from bot_drop_min_days; its result now counts its share of aircraft costs, as aircraft are shared). The aircraft
-- stay with the airline; bot_balance packs, keeps a spare and hands the rest back at the quarter end.
create or replace function game.bot_exit(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare r record; v_n int := 0;
begin
  if game.param('bot_plan') = 0 then return game.bot_exit_v1(p_world, p_day); end if;
  for r in
    select rt.id, rt.airline_id
      from public.routes rt join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
     where rt.world_id = p_world and rt.status = 'open' and rt.opened_day <= p_day - game.param('bot_exit_min_days')
       and game.bot_entered(rt.airline_id, rt.origin, rt.dest)
       and coalesce((select sum(z.pax_econ + z.pax_biz)::numeric / nullif(sum(z.seats_econ + z.seats_biz), 0)
                       from public.route_daily z where z.route_id = rt.id and z.game_day > p_day - 28), 0) < game.param('bot_exit_lf')
  loop
    perform game.bot_close(r.airline_id, r.id, p_day);
    v_n := v_n + 1;
  end loop;
  for r in
    select rt.id, rt.airline_id,
           coalesce((select sum(z.revenue_inr - z.var_cost_inr - z.aircraft_cost_inr) from public.route_daily z
                      where z.route_id = rt.id and z.game_day > p_day - 28), 0) as result
      from public.routes rt join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
     where rt.world_id = p_world and rt.status = 'open' and rt.opened_day <= p_day - game.param('bot_drop_min_days')
       and not game.bot_entered(rt.airline_id, rt.origin, rt.dest)
       and (select count(*) from public.route_daily z where z.route_id = rt.id and z.game_day > p_day - 28) >= 21
       and coalesce((select sum(z.pax_econ + z.pax_biz)::numeric / nullif(sum(z.seats_econ + z.seats_biz), 0)
                       from public.route_daily z where z.route_id = rt.id and z.game_day > p_day - 28), 0) < game.param('bot_drop_lf')
       and (least(rt.origin, rt.dest), greatest(rt.origin, rt.dest)) not in
           (select m.a, m.b from public.markets m where not m.intl order by m.n_biz + m.n_lei + m.n_bud desc limit 8)
     order by 3
  loop
    continue when r.result >= 0;
    continue when (select count(*) from public.routes o where o.airline_id = r.airline_id and o.status = 'open') <= game.param('bot_keep_routes');
    perform game.bot_close(r.airline_id, r.id, p_day);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Each quarter end (E): routes given up, routes contested, then every route reviewed on its result over 28 days after flying
-- and aircraft costs. Losing ones (below bot_cut_margin) lose bot_cut_share of their flights, down to bot_min_weekly; earning
-- ones that are full (above bot_grow_margin and bot_grow_lf) gain bot_grow_share. Routes new to the plan wait bot_exit_min_days.
-- Then the plan is fitted to the aircraft (bot_balance).
create or replace function game.bot_quarter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; v_n int := 0; v_min int := game.param('bot_min_weekly')::int;
begin
  if game.param('bot_plan') = 0 then return game.bot_quarter_v1(p_world, p_day); end if;
  v_n := game.bot_exit(p_world, p_day);
  v_n := v_n + game.bot_enter(p_world, p_day);
  drop table if exists pg_temp._bot_grow;
  create temp table _bot_grow (route_id uuid primary key) on commit drop;
  for al in select a.id from public.airlines a where a.world_id = p_world and a.is_ai and a.status = 'active' order by a.code loop
    drop table if exists pg_temp._bst;
    create temp table _bst on commit drop as
    select p.route_id, p.trips,
           ((sum(d.revenue_inr) - sum(d.var_cost_inr + d.aircraft_cost_inr)) / nullif(sum(d.revenue_inr), 0))::float8 as margin,
           (sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0))::float8 as lf,
           count(*) as days
      from game.bot_plan p join public.route_daily d on d.route_id = p.route_id and d.game_day > p_day - 28
     where p.airline_id = al.id and p.since_day <= p_day - game.param('bot_exit_min_days') and p.trips > 0
     group by p.route_id, p.trips;
    update game.bot_plan p set trips = greatest(least(p.trips, v_min), round(p.trips * (1 - game.param('bot_cut_share')))::int)
      from pg_temp._bst s
     where s.route_id = p.route_id and s.days >= 21 and s.margin < game.param('bot_cut_margin');
    insert into pg_temp._bot_grow (route_id)
    select s.route_id from pg_temp._bst s
     where s.days >= 21 and s.margin > game.param('bot_grow_margin') and s.lf > game.param('bot_grow_lf')
    on conflict do nothing;
    update game.bot_plan p set trips = ceil(p.trips * (1 + game.param('bot_grow_share')))::int
      from pg_temp._bot_grow g where g.route_id = p.route_id and p.airline_id = al.id;
    v_n := v_n + game.bot_balance(al.id, p_day, true);
  end loop;
  return v_n;
end $$;


-- sell_week from 0022: fares priced from the reference fare times the world's fare index (G), and the computer-run
-- airlines' cost floor (F)
create or replace function game.sell_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' set jit = off as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_w int := game.week_of(p_day);
  v_h int := game.param('sale_weeks')::int;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    seg_biz_a float8, seg_biz_price float8, seg_biz_freq float8, seg_biz_comfort float8, seg_biz_brand float8,
    seg_lei_a float8, seg_lei_price float8, seg_lei_freq float8, seg_lei_comfort float8, seg_lei_brand float8,
    seg_bud_a float8, seg_bud_price float8, seg_bud_freq float8, seg_bud_comfort float8, seg_bud_brand float8,
    biz_fare_mult float8, nest_lambda float8, biz_downgrade_share float8, seg_biz_cabin_a float8,
    growth_year float8, growth_year_intl float8, season_start_month float8, demand_noise_sd float8,
    book_shape_biz float8, book_scale_biz float8, book_shape_lei float8, book_scale_lei float8,
    book_shape_bud float8, book_scale_bud float8, fare_ramp_power float8,
    noshow_biz float8, noshow_lei float8, noshow_bud float8, noshow_market_sd float8, noshow_week_sd float8,
    denied_comp_inr float8, rm_history_weeks float8, watch_ahead_weeks float8,
    news_fare_move float8, news_flights_move float8, insight_min_routes float8);

  -- booking curves: the share of each traveller type deciding n weeks before the flight week (arr), and the share who have
  -- decided before week n (pre)
  drop table if exists pg_temp._curve;
  create temp table _curve on commit drop as
  with k as (select n, (n + 0.5)::float8 as x from generate_series(0, v_h - 1) n),
  raw as (select n, x ^ g.book_shape_biz * exp(-x / g.book_scale_biz) as b, x ^ g.book_shape_lei * exp(-x / g.book_scale_lei) as l,
                 x ^ g.book_shape_bud * exp(-x / g.book_scale_bud) as u from k),
  nrm as (select n, b / sum(b) over () as b, l / sum(l) over () as l, u / sum(u) over () as u from raw)
  select n, b as arr_b, l as arr_l, u as arr_u,
         coalesce(sum(b) over w, 0) as pre_b, coalesce(sum(l) over w, 0) as pre_l, coalesce(sum(u) over w, 0) as pre_u,
         ((v_h - 1 - n)::float8 / (v_h - 1)) ^ g.fare_ramp_power as ramp
    from nrm window w as (order by n desc rows between unbounded preceding and 1 preceding);

  drop table if exists pg_temp._money;
  create temp table _money (airline_id uuid, sales float8 default 0, refunds float8 default 0, comp float8 default 0) on commit drop;

  -- 1. Routes closed: their tickets are refunded.
  with gone as (
    delete from public.route_weeks x using public.routes r
     where x.world_id = p_world and x.flown_e is null and r.id = x.route_id and r.status <> 'open'
    returning x.airline_id, 2 * (x.rev_e + x.rev_b) as amt)
  insert into pg_temp._money (airline_id, refunds) select airline_id, sum(amt) from gone group by airline_id;

  -- 2. Seats on sale: for each open route, each flight week from this one to the end of the sale, the rotations of the
  -- aircraft that are in the fleet by the start of that week.
  drop table if exists pg_temp._cap;
  create temp table _cap on commit drop as
  select r.id as route_id, wk.w as week, r.airline_id, m.a, m.b,
         sum(ro.weekly_trips)::float8 as trips,
         sum(ro.weekly_trips * ac.seats_econ)::float8 as seats_e, sum(ro.weekly_trips * ac.seats_biz)::float8 as seats_b,
         coalesce(sum(ro.weekly_trips * ac.seats_econ * (ac.econ_pitch - 28) / 6.0) / nullif(sum(ro.weekly_trips * ac.seats_econ), 0), 0)::float8 as comf_e,
         coalesce(sum(ro.weekly_trips * ac.seats_biz * case when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (ac.biz_pitch - 36) / 12.0 end)
                  / nullif(sum(ro.weekly_trips * ac.seats_biz), 0), 0)::float8 as comf_b,
         (sum(ro.weekly_trips * (m.km::numeric / t.cruise_kmh + t.block_offset_h)) / sum(ro.weekly_trips))::float8 as block_h
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.status = 'active'
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    cross join generate_series(v_w, v_w + v_h - 1) wk(w)
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id
         and ac.status in ('active', 'grounded', 'refit', 'delivering') and coalesce(ac.available_day, 0) <= (wk.w - 1) * 7 + 1
    join public.aircraft_types t on t.id = ac.type_id
   where r.world_id = p_world and r.status = 'open'
     and greatest(r.first_flight_day, al.first_flight_day) <= (wk.w - 1) * 7 + 1
   group by r.id, wk.w, r.airline_id, m.a, m.b;

  -- a flight week new on sale starts from what the route has learnt: the fare changes of the week now closing
  insert into public.route_weeks (route_id, week, world_id, airline_id, trips, seats_e, seats_b, seats_max_e, seats_max_b, adj_e, adj_b, listed)
  select c.route_id, c.week, p_world, c.airline_id, c.trips, c.seats_e, c.seats_b, c.seats_e, c.seats_b,
         coalesce(y.adj_e, 1), coalesce(y.adj_b, 1), v_w
    from pg_temp._cap c left join public.route_weeks y on y.route_id = c.route_id and y.week = v_w
  on conflict (route_id, week) do update
    set trips = excluded.trips, seats_e = excluded.seats_e, seats_b = excluded.seats_b,
        seats_max_e = greatest(public.route_weeks.seats_max_e, excluded.seats_e),
        seats_max_b = greatest(public.route_weeks.seats_max_b, excluded.seats_b);
  update public.route_weeks x set trips = 0, seats_e = 0, seats_b = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null
     and (x.trips > 0 or x.seats_e > 0)
     and not exists (select 1 from pg_temp._cap c where c.route_id = x.route_id and c.week = x.week);

  -- 3. Fares. Every flight week on sale with seats; n is weeks before the flight week.
  drop table if exists pg_temp._sell;
  create temp table _sell on commit drop as
  with ax as materialized (
    select q.airline_id, t.d_biz, t.d_lei, t.d_bud
      from (select distinct airline_id from pg_temp._cap) q cross join lateral game.anc_terms(q.airline_id) t)
  select x.route_id, x.week, x.week - v_w as n, x.airline_id, c.a, c.b, m.intl, m.ref_fare::float8 as ref, m.ref_fare::float8 * coalesce(rw.fare_index, 1)::float8 as rp, p.strategy,
         s.target_lf::float8 as tlf, s.early_mult::float8 as em, s.late_mult::float8 as lm,
         s.biz_early_mult::float8 as bem, s.biz_late_mult::float8 as blm, s.min_mult::float8 as mn, s.max_mult::float8 as mx,
         s.step::float8 as st, s.band::float8 as bd, s.follow_gap::float8 as gap, s.overbook::float8 as ob,
         c.trips / 7 as f, c.seats_e as se, c.seats_b as sb, c.comf_e as ce, c.comf_b as cb, c.block_h as bh,
         al.brand::float8 as brand, ax.d_biz::float8 as adb, ax.d_lei::float8 as adl, ax.d_bud::float8 as adu,
         (x.bk_be + x.bk_l + x.bk_u)::float8 as sold_e, x.bk_b::float8 as sold_b, x.adj_e::float8 as adj_e, x.adj_b::float8 as adj_b, x.listed,
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         -- the market's own (hidden) no-show factor, and the no-show share the engine expects in economy from the traveller mix
         mf.v as mf,
         (m.n_biz * g.noshow_biz + m.n_lei * g.noshow_lei + m.n_bud * g.noshow_bud) / nullif(m.n_biz + m.n_lei + m.n_bud, 0) * mf.v as ns,
         0::float8 as pe, 0::float8 as pb, 0::float8 as room_e, 0::float8 as room_b,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu,
         0::float8 as got_be, 0::float8 as got_l, 0::float8 as got_u, 0::float8 as got_b, 0::float8 as lost
    from public.route_weeks x
    join pg_temp._cap c on c.route_id = x.route_id and c.week = x.week
    join public.route_plans p on p.route_id = x.route_id
    join public.rm_strategies s on s.key = p.strategy
    join public.markets m on m.a = c.a and m.b = c.b
    join public.airlines al on al.id = x.airline_id
    join ax on ax.airline_id = x.airline_id
    cross join lateral (select exp(g.noshow_market_sd * game.hash_normal('ns:' || m.a || m.b) - g.noshow_market_sd ^ 2 / 2) as v) mf
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null;

  -- pace: compare seats sold with the target curve; outside the band, move this week's fares by the step for each band's
  -- width they are off (up to three steps), within the strategy's bounds
  update pg_temp._sell z set
    adj_e = least(z.mx / q.base_e, greatest(z.mn / q.base_e, z.adj_e * case
              when q.tgt_e < 0.02 * z.se or abs(z.sold_e / q.tgt_e - 1) <= z.bd then 1
              else 1 + z.st * greatest(-3, least(3, (z.sold_e / q.tgt_e - 1) / greatest(z.bd, 0.01))) end)),
    adj_b = least(z.mx / q.base_b, greatest(z.mn / q.base_b, z.adj_b * case
              when z.sb = 0 or q.tgt_b < 0.02 * z.sb or abs(z.sold_b / q.tgt_b - 1) <= z.bd then 1
              else 1 + z.st * greatest(-3, least(3, (z.sold_b / q.tgt_b - 1) / greatest(z.bd, 0.01))) end))
    from (select z0.route_id, z0.week,
                 z0.em + (z0.lm - z0.em) * c.ramp as base_e, z0.bem + (z0.blm - z0.bem) * c.ramp as base_b,
                 z0.tlf * z0.se * (z0.nb * case when z0.sb > 0 then 0.3 else 1 end * c.pre_b + z0.nl * c.pre_l + z0.nu * c.pre_u)
                     / nullif(z0.nb * case when z0.sb > 0 then 0.3 else 1 end + z0.nl + z0.nu, 0) as tgt_e,
                 z0.tlf * z0.sb * c.pre_b as tgt_b
            from pg_temp._sell z0 join pg_temp._curve c on c.n = z0.n) q
   where q.route_id = z.route_id and q.week = z.week;
  update pg_temp._sell z set
    pe = round(z.rp * (z.em + (z.lm - z.em) * c.ramp) * z.adj_e / 10) * 10,
    pb = round(z.rp * g.biz_fare_mult * (z.bem + (z.blm - z.bem) * c.ramp) * z.adj_b / 10) * 10
    from pg_temp._curve c where c.n = z.n;
  -- follow the market: the rivals' average for the same flight week
  update pg_temp._sell z set
    pe = round(least(z.mx * z.rp, greatest(z.mn * z.rp, q.e * (1 + z.gap))) / 10) * 10,
    pb = coalesce(round(least(z.mx * z.rp * g.biz_fare_mult, greatest(z.mn * z.rp * g.biz_fare_mult, q.b * (1 + z.gap))) / 10) * 10, z.pb)
    from (select z1.route_id, z1.week, avg(z2.pe) as e, avg(z2.pb) filter (where z2.sb > 0) as b
            from pg_temp._sell z1 join pg_temp._sell z2 on z2.a = z1.a and z2.b = z1.b and z2.week = z1.week and z2.airline_id <> z1.airline_id
           where z1.strategy = 'follow' and z2.se > 0
           group by z1.route_id, z1.week) q
   where z.route_id = q.route_id and z.week = q.week;

  -- 0024 (F): computer-run airlines never sell economy below the fare that covers the route's flying and aircraft costs at
  -- bot_sell_floor_lf full over the last 28 days (business seats counted at the business multiple, extras at bot_floor_anc),
  -- within the strategy's highest fare
  if game.param('bot_sell_floor_lf') > 0 then
    update pg_temp._sell z set pe = greatest(z.pe, round(least(z.mx * z.rp, f.floor_e) / 10) * 10)
      from (select d.route_id,
                   sum(d.var_cost_inr + d.aircraft_cost_inr)::float8
                     / nullif(game.param('bot_sell_floor_lf') * (1 + game.param('bot_floor_anc'))
                              * sum(d.seats_econ + g.biz_fare_mult * d.seats_biz), 0) as floor_e
              from public.route_daily d join public.airlines al on al.id = d.airline_id and al.is_ai
             where al.world_id = p_world and d.game_day > p_day - 28
             group by d.route_id having count(*) >= 7) f
     where f.route_id = z.route_id;
  end if;

  -- 4. This week's bookings. Seats can be sold beyond the cabin by the strategy's overbooking share of expected no-shows.
  update pg_temp._sell set
    room_e = greatest(0, se * (1 + ob * ns) - sold_e),
    room_b = greatest(0, sb * (1 + ob * g.noshow_biz * mf) - sold_b);
  update pg_temp._sell set
    xb_e = case when room_e > 0.5 then game.sell_x(g.seg_biz_a - g.seg_biz_price * (pe / ref + adb) + g.seg_biz_freq * ln(1 + f)
             + g.seg_biz_comfort * ce * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50, g.nest_lambda) else 0 end,
    xb_b = case when room_b > 0.5 then game.sell_x(g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * pb / (ref * g.biz_fare_mult)
             + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * cb * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50, g.nest_lambda) else 0 end,
    xl   = case when room_e > 0.5 then game.sell_x(g.seg_lei_a - g.seg_lei_price * (pe / ref + adl) + g.seg_lei_freq * ln(1 + f)
             + g.seg_lei_comfort * ce * sqrt(bh) + g.seg_lei_brand * (brand - 50) / 50, g.nest_lambda) else 0 end,
    xu   = case when room_e > 0.5 then game.sell_x(g.seg_bud_a - g.seg_bud_price * (pe / ref + adu) + g.seg_bud_freq * ln(1 + f)
             + g.seg_bud_comfort * ce * sqrt(bh) + g.seg_bud_brand * (brand - 50) / 50, g.nest_lambda) else 0 end;

  -- festivals and events (G): each day of a flight week inside an event adds a seventh of the event's extra demand
  drop table if exists pg_temp._ev;
  create temp table _ev on commit drop as
  select q.a, q.b, q.week,
         (1 + sum(e.biz - 1) / 7.0)::float8 as fb, (1 + sum(e.lei - 1) / 7.0)::float8 as fl, (1 + sum(e.bud - 1) / 7.0)::float8 as fu
    from (select distinct a, b, week, intl from pg_temp._sell) q
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    cross join generate_series(0, 6) dd
    join public.demand_events e
      on (((q.week - 1) * 7 + dd) % 364 + 1 - e.start_doy + 364) % 364 < e.days
     and (e.domestic is null or e.domestic = not q.intl)
     and (e.airports is null or q.a = any (e.airports) or q.b = any (e.airports))
     and (e.regions is null or pa.region = any (e.regions) or pb.region = any (e.regions))
   group by q.a, q.b, q.week;

  -- travellers who decide this week on each market and flight week: the week's demand (7 days, season of its middle day,
  -- growth, a swing fixed per market and week) times the share of each type who book n weeks ahead (when the week first
  -- opens on its market, everyone who would have booked by then)
  with wk as (
    select w, (w - 1) * 7 + 4 as mid,
           power(1 + g.growth_year, ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow,
           power(1 + coalesce(g.growth_year_intl, g.growth_year), ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow_i
      from generate_series(v_w, v_w + v_h - 1) w),
  sf as (
    select wk.w, wk.grow, wk.grow_i, s.biz, s.lei, s.bud from wk join public.season_factors s
      on s.month = ((g.season_start_month::int - 1 + (((wk.mid - 1) % 364) * 12) / 364) % 12) + 1),
  -- a flight week opens for sale on its market when no airline had it on sale before (a new market, or the world's
  -- first week): travellers who would have booked earlier book now
  op as (
    select route_id, week, min(listed) over (partition by a, b, week) = v_w as opening from pg_temp._sell),
  arr as (
    select z.route_id, z.week,
           7 * z.nb * sf.biz * coalesce(ev.fb, 1) * k.v * case when z.opening then c.pre_b + c.arr_b else c.arr_b end as ab,
           7 * z.nl * sf.lei * coalesce(ev.fl, 1) * k.v * case when z.opening then c.pre_l + c.arr_l else c.arr_l end as al_,
           7 * z.nu * sf.bud * coalesce(ev.fu, 1) * k.v * case when z.opening then c.pre_u + c.arr_u else c.arr_u end as au,
           game.sell_k(sum(z.xb_e + z.xb_b) over mkt, g.nest_lambda) as kb,
           game.sell_k(sum(z.xl) over mkt, g.nest_lambda) as kl,
           game.sell_k(sum(z.xu) over mkt, g.nest_lambda) as ku
      from (select z0.*, op.opening from pg_temp._sell z0 join op on op.route_id = z0.route_id and op.week = z0.week) z
      join sf on sf.w = z.week
      join pg_temp._curve c on c.n = z.n
      left join pg_temp._ev ev on ev.a = z.a and ev.b = z.b and ev.week = z.week
      cross join lateral (select case when z.intl then sf.grow_i else sf.grow end * exp(g.demand_noise_sd / sqrt(7) * game.hash_normal(p_world::text || z.a || z.b || z.week)
                                               - g.demand_noise_sd ^ 2 / 14) as v) k
    window mkt as (partition by z.a, z.b, z.week)),
  dem as (
    select z.route_id, z.week, a.ab * z.xb_e * a.kb as d_be, a.ab * z.xb_b * a.kb as d_bb,
           a.al_ * z.xl * a.kl as d_l, a.au * z.xu * a.ku as d_u
      from pg_temp._sell z join arr a on a.route_id = z.route_id and a.week = z.week),
  -- business cabin first; part of its overflow takes economy on the same airline
  bz as (
    select d.*, least(d.d_bb, z.room_b) as got_b, g.biz_downgrade_share * greatest(d.d_bb - z.room_b, 0) as dg, z.room_e
      from dem d join pg_temp._sell z on z.route_id = d.route_id and z.week = d.week)
  update pg_temp._sell z
     set got_b = bz.got_b,
         got_be = (bz.d_be + bz.dg) * e.fac, got_l = bz.d_l * e.fac, got_u = bz.d_u * e.fac,
         lost = (bz.d_bb - bz.got_b - bz.dg) + (bz.d_be + bz.dg + bz.d_l + bz.d_u) * (1 - e.fac)
    from bz cross join lateral (select case when bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.room_e
                                            then bz.room_e / (bz.d_be + bz.dg + bz.d_l + bz.d_u) else 1 end as fac) e
   where bz.route_id = z.route_id and bz.week = z.week;

  update public.route_weeks x
     set price_e = z.pe, price_b = case when z.sb > 0 then z.pb end, adj_e = z.adj_e, adj_b = z.adj_b, strategy = z.strategy,
         bk_be = x.bk_be + z.got_be, bk_l = x.bk_l + z.got_l, bk_u = x.bk_u + z.got_u, bk_b = x.bk_b + z.got_b,
         rev_e = x.rev_e + (z.got_be + z.got_l + z.got_u) * z.pe, rev_b = x.rev_b + z.got_b * z.pb,
         sold_wk = z.got_be + z.got_l + z.got_u + z.got_b, spill = x.spill + z.lost
    from pg_temp._sell z
   where x.route_id = z.route_id and x.week = z.week;
  -- weeks with no seats on sale this week sold nothing
  update public.route_weeks x set sold_wk = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null and x.sold_wk <> 0
     and not exists (select 1 from pg_temp._sell z where z.route_id = x.route_id and z.week = x.week);
  insert into pg_temp._money (airline_id, sales)
  select airline_id, 2 * sum((got_be + got_l + got_u) * pe + got_b * pb) from pg_temp._sell group by airline_id;

  -- 5. The flight week now starting closes. No-shows by traveller type (the market's hidden factor and a weekly swing);
  -- passengers who turn up beyond the seats cannot board: a refund, plus compensation unless the seats were cut by the
  -- airline's own schedule change (then a refund only).
  with fl as (
    select x.route_id, x.airline_id, x.seats_e, x.seats_b, x.seats_max_e, x.seats_max_b,
           x.bk_be + x.bk_l + x.bk_u as sold_e, x.bk_b as sold_b, x.rev_e, x.rev_b,
           f.k * (x.bk_be * g.noshow_biz + x.bk_l * g.noshow_lei + x.bk_u * g.noshow_bud) as ns_e,
           f.k * x.bk_b * g.noshow_biz as ns_b
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
      cross join lateral (select least(0.9, exp(g.noshow_market_sd * game.hash_normal('ns:' || m.a || m.b) - g.noshow_market_sd ^ 2 / 2
                                  + g.noshow_week_sd * game.hash_normal('nsw:' || p_world::text || m.a || m.b || x.week) - g.noshow_week_sd ^ 2 / 2)) as k) f
     where x.world_id = p_world and x.week = v_w and x.flown_e is null),
  dn as (
    select fl.*, greatest(0, fl.sold_e - fl.ns_e - fl.seats_e) as den_e, greatest(0, fl.sold_b - fl.ns_b - fl.seats_b) as den_b
      from fl),
  upd as (
    update public.route_weeks x
       set noshow = dn.ns_e + dn.ns_b, denied = dn.den_e + dn.den_b,
           comp = greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)) + greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)),
           flown_e = dn.sold_e - dn.ns_e - dn.den_e, flown_b = dn.sold_b - dn.ns_b - dn.den_b,
           rev_flown_e = dn.rev_e - dn.den_e * coalesce(dn.rev_e / nullif(dn.sold_e, 0), 0),
           rev_flown_b = dn.rev_b - dn.den_b * coalesce(dn.rev_b / nullif(dn.sold_b, 0), 0)
      from dn where x.route_id = dn.route_id and x.week = v_w
    returning x.airline_id, 2 * (x.rev_e + x.rev_b - x.rev_flown_e - x.rev_flown_b) as refund, 2 * x.comp * g.denied_comp_inr as comp)
  insert into pg_temp._money (airline_id, refunds, comp) select airline_id, sum(refund), sum(comp) from upd group by airline_id;

  -- the money: tickets sold in, refunds and compensation out (compensation is a cost; the rest moves cash only)
  update public.airline_finance fin set cash_inr = round(fin.cash_inr + m.sales - m.refunds - m.comp)
    from (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp from pg_temp._money group by airline_id) m
   where fin.airline_id = m.airline_id;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  select airline_id, p_day, 'denied_boarding', -round(sum(comp)), 'Compensation to passengers who could not board', -round(sum(comp))
    from pg_temp._money group by airline_id having sum(comp) >= 1;
  insert into public.airline_weeks (airline_id, week, sales_inr, refunds_inr, comp_inr, advance_inr)
  select al.id, v_w, round(coalesce(m.sales, 0)), round(coalesce(m.refunds, 0)), round(coalesce(m.comp, 0)),
         round(coalesce((select 2 * sum(x.rev_e + x.rev_b) from public.route_weeks x where x.airline_id = al.id and x.week > v_w), 0))
    from public.airlines al
    left join (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp from pg_temp._money group by airline_id) m
           on m.airline_id = al.id
   where al.world_id = p_world and (al.status = 'active' or m.airline_id is not null)
  on conflict (airline_id, week) do update
    set sales_inr = excluded.sales_inr, refunds_inr = excluded.refunds_inr, comp_inr = excluded.comp_inr, advance_inr = excluded.advance_inr;

  -- the fares shown on each route: next week's
  update public.routes r set fare_econ = greatest(1, x.price_e), fare_biz = coalesce(x.price_b, r.fare_biz)
    from public.route_weeks x
   where x.route_id = r.id and x.week = v_w + 1 and r.world_id = p_world and x.price_e is not null;

  -- 6. What rivals can see: each airline's fare a few weeks ahead and next week's flights, and what changed.
  drop table if exists pg_temp._watch;
  create temp table _watch on commit drop as
  select r.id as route_id, r.airline_id, least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b,
         f.price_e as fare_e, f.price_b as fare_b, coalesce(nx.trips, 0) as trips, coalesce(nx.seats_e + nx.seats_b, 0) as seats
    from public.routes r
    left join public.route_weeks f on f.route_id = r.id and f.week = v_w + g.watch_ahead_weeks::int
    left join public.route_weeks nx on nx.route_id = r.id and nx.week = v_w + 1
   where r.world_id = p_world and r.status = 'open';
  insert into public.market_moves (world_id, a, b, week, airline_id, kind, old_value, new_value)
  select p_world, a, b, v_w, airline_id, kind,
         case when kind in ('fare_up', 'fare_down') then o_fare else o_trips end,
         case when kind in ('fare_up', 'fare_down') then n_fare else n_trips end
    from (select coalesce(n.a, o.a) as a, coalesce(n.b, o.b) as b, coalesce(n.airline_id, o.airline_id) as airline_id,
                 o.trips as o_trips, n.trips as n_trips, o.fare_e as o_fare, n.fare_e as n_fare,
                 case when coalesce(o.trips, 0) = 0 and coalesce(n.trips, 0) > 0 then 'enter'
                      when coalesce(n.trips, 0) = 0 and coalesce(o.trips, 0) > 0 then 'leave'
                      when n.trips >= o.trips * 1.1 + 0.5 then 'more_flights'
                      when n.trips <= o.trips / 1.1 - 0.5 then 'fewer_flights'
                      when n.fare_e >= o.fare_e * 1.07 then 'fare_up'
                      when n.fare_e <= o.fare_e / 1.07 then 'fare_down' end as kind
            from pg_temp._watch n
            full join (select * from public.market_watch where world_id = p_world) o on o.route_id = n.route_id) q
   where kind is not null;
  -- rivals' bigger moves reach every player flying the same market, as private news
  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, r.airline_id, 'rival',
         al.name || case mv.kind when 'enter' then ' starts flying ' when 'leave' then ' stops flying '
                                 when 'fare_up' then ' raises fares on ' when 'fare_down' then ' cuts fares on '
                                 when 'more_flights' then ' adds flights on ' else ' cuts flights on ' end
         || pa.city || '–' || pb.city
         || case when mv.kind in ('fare_up', 'fare_down')
                 then ': ₹' || to_char(mv.old_value, 'FM999,999,990') || ' → ₹' || to_char(mv.new_value, 'FM999,999,990') || ' four weeks out'
                 when mv.kind in ('more_flights', 'fewer_flights')
                 then ': ' || round(mv.old_value) || ' → ' || round(mv.new_value) || ' flights a week' else '' end || '.',
         true
    from public.market_moves mv
    join public.airlines al on al.id = mv.airline_id
    join public.routes r on r.world_id = p_world and r.status = 'open' and least(r.origin, r.dest) = mv.a and greatest(r.origin, r.dest) = mv.b
                        and r.airline_id <> mv.airline_id
    join public.airports pa on pa.iata = r.origin
    join public.airports pb on pb.iata = r.dest
    join public.airlines me on me.id = r.airline_id and not me.is_ai and me.status = 'active'
   where mv.world_id = p_world and mv.week = v_w
     and (mv.kind in ('enter', 'leave')
          or (mv.kind in ('fare_up', 'fare_down') and abs(mv.new_value / nullif(mv.old_value, 0) - 1) >= g.news_fare_move)
          or (mv.kind in ('more_flights', 'fewer_flights') and abs(mv.new_value / nullif(mv.old_value, 0) - 1) >= g.news_flights_move));
  delete from public.market_watch where world_id = p_world;
  insert into public.market_watch (route_id, world_id, airline_id, a, b, week, fare_e, fare_b, trips, seats)
  select route_id, p_world, airline_id, a, b, v_w, fare_e, fare_b, trips, seats from pg_temp._watch;

  -- What works where (0020): the last 13 flown weeks of every route, by kind of sector, how many airlines fly the market
  -- and how the route sold. A cell needs insight_min_routes routes, so no single airline's results can be read off it.
  delete from public.sector_insights where world_id = p_world;
  insert into public.sector_insights (world_id, week, band, shape, strategy, routes, weeks, load, fare_index, rev_index)
  with fw as (
    select x.route_id, x.week, x.strategy, (x.seats_e + x.seats_b)::float8 as seats,
           (x.flown_e + x.flown_b)::float8 as flown, (x.rev_flown_e + x.rev_flown_b)::float8 as rev,
           m.ref_fare::float8 as ref, m.a, m.b, m.km, m.intl
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where x.world_id = p_world and x.flown_e is not null and x.week > v_w - 13 and x.seats_e + x.seats_b > 0 and x.strategy is not null),
  sh as (select a, b, week, count(*) as n from fw group by a, b, week)
  select p_world, v_w,
         case when fw.intl then 'intl' when fw.km < 800 then 'short' when fw.km < 1800 then 'medium' else 'long' end,
         case when sh.n = 1 then 'alone' when sh.n = 2 then 'two' when sh.n <= 4 then 'few' else 'many' end,
         fw.strategy, count(distinct fw.route_id), count(*),
         round((sum(fw.flown) / sum(fw.seats))::numeric, 4),
         round((sum(fw.rev) / nullif(sum(fw.flown * fw.ref), 0))::numeric, 4),
         round((sum(fw.rev) / sum(fw.seats * fw.ref))::numeric, 4)
    from fw join sh on sh.a = fw.a and sh.b = fw.b and sh.week = fw.week
   group by 3, 4, 5
  having count(distinct fw.route_id) >= g.insight_min_routes;

  -- history
  delete from public.route_weeks where world_id = p_world and week < v_w - g.rm_history_weeks::int;
  delete from public.market_moves where world_id = p_world and week < v_w - 13;
end $$;

-- bot_selling from 0021: a fight matches the market (F)
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
    select distinct on (m.a, m.b) m.a, m.b, case when m.kind = 'enter' and game.param('bot_fight_follow') = 0 then 'fill' else 'follow' end as answer
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

-- ops_week from 0023: also moves the fare index with fuel (G)
create or replace function game.ops_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_w int := game.week_of(p_day);
  v_lead int := game.param('hedge_lead_weeks')::int;
begin
  -- G: the fuel price fares follow moves fuel_fare_smooth of the way to today's price each week; fares follow fuel_pass of
  -- the change in fuel cost per passenger (fuel_fare_share of the reference fare at fuel_ref_inr_kg)
  update public.worlds w
     set fuel_avg = round((coalesce(w.fuel_avg, w.fuel_inr_kg) * (1 - game.param('fuel_fare_smooth'))
                           + w.fuel_inr_kg * game.param('fuel_fare_smooth'))::numeric, 2)
   where w.id = p_world;
  update public.worlds w
     set fare_index = round((1 + game.param('fuel_pass') * game.param('fuel_fare_share')
                                 * (w.fuel_avg / game.param('fuel_ref_inr_kg') - 1))::numeric, 4)
   where w.id = p_world;
  select * into rw from public.worlds where id = p_world;
  insert into public.fuel_hedges (airline_id, week, share, price_inr_kg)
  select ao.airline_id, v_w + v_lead, ao.hedge_share, round(rw.fuel_inr_kg * (1 + game.param('hedge_premium')), 2)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, price_inr_kg = excluded.price_inr_kg;
  delete from public.fuel_hedges fh using public.airlines al
   where al.id = fh.airline_id and al.world_id = p_world and fh.week < v_w;

end $$;

revoke all on function game.bot_fit(text, int, int, int, numeric), game.bot_margin(uuid, int), game.bot_fleet_cap(uuid),
  game.bot_pack(uuid), game.bot_balance(uuid, int, boolean), game.bot_close(uuid, uuid, int), game.bot_seed(uuid),
  game.bot_enter(uuid, int), game.bot_exit(uuid, int), game.bot_quarter(uuid, int), game.sell_week(uuid, int),
  game.bot_selling(uuid, int), game.ops_week(uuid, int)
  from public, anon, authenticated;
