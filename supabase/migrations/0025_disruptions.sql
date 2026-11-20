-- Migration 0025 (spec 14.19): disruptions set per world by the admin, and fights at a random but profitable fare.
-- Owner's decisions (20 Nov 2026):
--  1. Each world has its own disruption values: random groundings, fuel shocks, currency swings and engine events, how often
--     (never to once a month) and how big and long. Unset values follow the game's defaults. Players are not told.
--     Currency swings by default about once in three years (they started about once a year); one engine event at a time.
--  2. A computer-run airline that fights a player draws, for the fight, where it prices between its profitable lowest fare
--     (its cost at 80% full plus 5%) and the player's fare; aggressive airlines draw lower. It never fights at a loss.

-- ---------- game values ----------
update public.game_params set num = 0.001 where key = 'event_fx_prob_day';          -- was 0.003: about once in 3 years
insert into public.game_params (key, num, note) values
('bot_fight_random', 1, 'a fighting computer-run airline prices at a point drawn for the fight between its profitable lowest fare and the player''s fare (0: as 0024)'),
('bot_fight_margin', 0.05, 'its profitable lowest fare in a fight: the cost floor (bot_sell_floor_lf) plus this margin'),
('bot_fight_skew', 3, 'the draw is random() to the power aggression x this: aggressive airlines fight nearer their lowest fare');

-- ---------- 1. each world's own disruption values ----------
create table public.world_params (
  world_id uuid not null references public.worlds on delete cascade,
  key      text not null references public.game_params (key),
  num      numeric not null,
  primary key (world_id, key)
);
alter table public.world_params enable row level security;
revoke all on public.world_params from anon, authenticated;
grant select on public.world_params to authenticated;
create policy read_admin on public.world_params for select to authenticated   -- admins only: players are not told
  using (exists (select 1 from public.profiles where user_id = (select auth.uid()) and is_admin));

-- a game value for one world: its own if the admin set one, else the game's
create or replace function game.wparam(p_world uuid, p_key text) returns numeric
language sql stable set search_path = '' as $$
  select coalesce((select wp.num from public.world_params wp where wp.world_id = p_world and wp.key = p_key), game.param(p_key))
$$;

create or replace function game.wrand_between(p_world uuid, p_lo text, p_hi text) returns numeric
language sql volatile set search_path = '' as $$
  select (game.wparam(p_world, p_lo) + random() * (game.wparam(p_world, p_hi) - game.wparam(p_world, p_lo)))::numeric
$$;

-- The admin sets a world's disruption values: {"key": number} sets one, {"key": null} goes back to the game's default.
-- How often is a chance a day (per aircraft for groundings), from never to once a month (12 in a 364-day year). Returns the
-- world's values in force.
create or replace function public.admin_set_disruptions(p_world uuid, p_values jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  k text; v jsonb; lim record; v_out jsonb;
begin
  perform game.require_admin();
  if not exists (select 1 from public.worlds where id = p_world) then raise exception 'No such world'; end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' then raise exception 'Give the values as an object'; end if;
  for k, v in select * from jsonb_each(p_values) loop
    select * into lim from (values
      ('ground_prob_day', 0::numeric, 12 / 364.0), ('ground_days_min', 1, 60), ('ground_days_max', 1, 60),
      ('event_fuel_prob_day', 0, 12 / 364.0), ('event_fuel_mult_min', 1, 2), ('event_fuel_mult_max', 1, 2),
      ('event_fuel_days_min', 7, 364), ('event_fuel_days_max', 7, 364),
      ('event_fx_prob_day', 0, 12 / 364.0), ('event_fx_mult_min', 1, 1.5), ('event_fx_mult_max', 1, 1.5),
      ('event_fx_days_min', 7, 364), ('event_fx_days_max', 7, 364),
      ('event_engine_prob_day', 0, 12 / 364.0), ('event_engine_share_min', 0.05, 0.6), ('event_engine_share_max', 0.05, 0.6),
      ('event_engine_days_min', 7, 364), ('event_engine_days_max', 7, 364)) as t(key, lo, hi)
     where t.key = k;
    if not found then raise exception 'Not a disruption value: %', k; end if;
    if jsonb_typeof(v) = 'null' then
      delete from public.world_params where world_id = p_world and key = k;
    elsif jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < lim.lo - 1e-9 or (v #>> '{}')::numeric > lim.hi + 1e-9 then
      raise exception '% must be a number from % to %', k, round(lim.lo, 4), round(lim.hi, 4);
    else
      insert into public.world_params (world_id, key, num) values (p_world, k, (v #>> '{}')::numeric)
      on conflict (world_id, key) do update set num = excluded.num;
    end if;
  end loop;
  if game.wparam(p_world, 'ground_days_min') > game.wparam(p_world, 'ground_days_max')
     or game.wparam(p_world, 'event_fuel_mult_min') > game.wparam(p_world, 'event_fuel_mult_max')
     or game.wparam(p_world, 'event_fuel_days_min') > game.wparam(p_world, 'event_fuel_days_max')
     or game.wparam(p_world, 'event_fx_mult_min') > game.wparam(p_world, 'event_fx_mult_max')
     or game.wparam(p_world, 'event_fx_days_min') > game.wparam(p_world, 'event_fx_days_max')
     or game.wparam(p_world, 'event_engine_share_min') > game.wparam(p_world, 'event_engine_share_max')
     or game.wparam(p_world, 'event_engine_days_min') > game.wparam(p_world, 'event_engine_days_max') then
    raise exception 'Each lowest value must not be above its highest';
  end if;
  select jsonb_object_agg(g.key, game.wparam(p_world, g.key)) into v_out
    from public.game_params g where g.key like 'event\_%' or g.key like 'ground\_%';
  return v_out;
end $$;

-- ---------- 2. fights ----------
alter table public.route_plans add column fight_pos numeric;   -- 0 = at its profitable lowest fare, 1 = the player's fare

-- day_world from 0005: each world's own disruption values (game.wparam), and one engine event at a time
create or replace function game.day_world(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_fuel numeric; v_fx numeric; v_mf numeric; v_mx numeric; v_m numeric; v_type text;
begin
  select * into rw from public.worlds where id = p_world;
  v_fuel := rw.fuel_walk * exp(game.param('fuel_vol_day') * game.rand_normal()
                               + game.param('fuel_revert_day') * ln(game.param('fuel_ref_inr_kg') / rw.fuel_walk));
  v_fx := rw.fx_walk * exp(game.param('fx_vol_day') * game.rand_normal() + game.param('fx_drift_year') / 364);

  if random() < game.wparam(p_world, 'event_fuel_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fuel_shock' and ends_day >= p_day) then
    v_m := round(game.wrand_between(p_world, 'event_fuel_mult_min', 'event_fuel_mult_max'), 2);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fuel_shock', p_day, p_day, p_day + game.wrand_between(p_world, 'event_fuel_days_min', 'event_fuel_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Fuel shock: jet fuel is up ' || round((v_m - 1) * 100) || '%.');
  end if;
  if random() < game.wparam(p_world, 'event_fx_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fx_swing' and ends_day >= p_day) then
    v_m := round(game.wrand_between(p_world, 'event_fx_mult_min', 'event_fx_mult_max'), 3);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fx_swing', p_day, p_day, p_day + game.wrand_between(p_world, 'event_fx_days_min', 'event_fx_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Currency swing: the rupee has weakened ' || round((v_m - 1) * 100, 1) || '% against the dollar.');
  end if;
  if random() < game.wparam(p_world, 'event_engine_prob_day') and not exists   -- 0025: one engine event at a time, like the others
     (select 1 from public.events where world_id = p_world and kind = 'engine_grounding' and ends_day >= p_day) then
    select x.type_id into v_type from public.aircraft x
     where x.world_id = p_world and x.status = 'active' and x.airline_id is not null
     group by x.type_id order by random() limit 1;
    if v_type is not null then
      insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
      values (p_world, 'engine_grounding', p_day, p_day, p_day + game.wrand_between(p_world, 'event_engine_days_min', 'event_engine_days_max')::int,
              jsonb_build_object('type', v_type, 'share', round(game.wrand_between(p_world, 'event_engine_share_min', 'event_engine_share_max'), 2)));
      insert into public.news (world_id, game_day, kind, body)
      select p_world, p_day, 'event', 'Engine inspections ground part of the ' || name || ' fleet for several weeks.'
        from public.aircraft_types where id = v_type;
    end if;
  end if;

  select coalesce(exp(sum(ln((payload ->> 'mult')::numeric)) filter (where kind = 'fuel_shock')), 1),
         coalesce(exp(sum(ln((payload ->> 'mult')::numeric)) filter (where kind = 'fx_swing')), 1)
    into v_mf, v_mx
    from public.events
   where world_id = p_world and kind in ('fuel_shock', 'fx_swing') and starts_day <= p_day and ends_day >= p_day;

  update public.worlds
     set fuel_walk = v_fuel, fx_walk = v_fx, fuel_inr_kg = round(v_fuel * v_mf, 2), fx_inr_usd = round(v_fx * v_mx, 3)
   where id = p_world;
  insert into public.world_daily (world_id, game_day, fuel_inr_kg, fx_inr_usd)
  values (p_world, p_day, round(v_fuel * v_mf, 2), round(v_fx * v_mx, 3));
  insert into public.news (world_id, game_day, kind, body)
  select p_world, p_day, 'event', city || ' airport (' || iata || ') opens today.'
    from public.airports where opens_day = p_day;
end $$;

-- day_fleet from 0023: each world's own grounding values
create or replace function game.day_fleet(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_bal numeric; v_rent numeric; v_dep numeric; v_loan numeric;
  v_term int := game.param('lease_term_days')::int;
  v_gmin int := game.wparam(p_world, 'ground_days_min')::int;
  v_gmax int := game.wparam(p_world, 'ground_days_max')::int;
  v_gprob numeric := game.wparam(p_world, 'ground_prob_day');
  v_gage numeric := game.wparam(p_world, 'ground_age_k');
begin
  select * into rw from public.worlds where id = p_world;

  -- a maintenance strategy chosen earlier takes effect today (0023)
  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, ao.airline_id, 'fleet',
         case when ao.maint_next = 'hangar' then 'Your own hangar is open: maintenance now runs in-house.'
              else 'Your maintenance strategy is now ' || lower(mp.name) || '.' end, true
    from public.airline_ops ao
    join public.airlines al on al.id = ao.airline_id and al.world_id = p_world
    join public.maint_plans mp on mp.key = ao.maint_next
   where ao.maint_next_day <= p_day;
  update public.airline_ops ao
     set maint_plan = ao.maint_next, maint_next = null, maint_next_day = null, maint_locked_until = p_day + mp.lock_weeks * 7
    from public.airlines al, public.maint_plans mp
   where al.id = ao.airline_id and al.world_id = p_world and mp.key = ao.maint_next and ao.maint_next_day <= p_day;

  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, x.airline_id, 'fleet', t.name || ' ' || x.reg || ' has joined your fleet at ' || x.base_iata || '.', true
    from public.aircraft x join public.aircraft_types t on t.id = x.type_id
   where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and x.airline_id is not null;

  -- new aircraft from the manufacturer: borrow the balance, pay it, or sell and lease back
  for rec in
    select x.id, x.reg, y.airline_id, y.price_usd, y.deposit_inr, y.pay_plan, y.finance_loan, t.lease_usd_month
      from public.aircraft x
      join public.aircraft_terms y on y.aircraft_id = x.id
      join public.aircraft_types t on t.id = x.type_id
     where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and y.ordered_day is not null
  loop
    v_bal := round(rec.price_usd * rw.fx_inr_usd) - rec.deposit_inr;
    if rec.finance_loan then
      v_loan := round(v_bal / rw.fx_inr_usd, 2);
      update public.aircraft_terms
         set deposit_inr = 0, start_day = p_day, ordered_day = null, loan_usd = v_loan,
             loan_pay_usd_day = round(v_loan / (game.param('loan_years') * 364), 4)
       where aircraft_id = rec.id;
      perform game.book(rec.airline_id, p_day, 0, 'loan', 'Aircraft loan of $' || v_loan || ' for ' || rec.reg || ' on delivery');
    elsif rec.pay_plan = 'cash'
       and (select cash_inr from public.airline_finance where airline_id = rec.airline_id) >= v_bal then
      perform game.book(rec.airline_id, p_day, -v_bal, 'purchase', 'Balance paid on delivery of ' || rec.reg);
      update public.aircraft_terms set deposit_inr = 0, start_day = p_day, ordered_day = null where aircraft_id = rec.id;
    else
      v_rent := round(rec.lease_usd_month * game.param('slb_rent_mult'));
      v_dep := round(v_rent * game.param('lease_deposit_months') * rw.fx_inr_usd);
      perform game.book(rec.airline_id, p_day, rec.deposit_inr - v_dep, 'leaseback',
                        'Sale and leaseback of ' || rec.reg || ': order deposit returned, lease deposit paid', 0, true);
      update public.aircraft_terms
         set holding = 'lease', lease_usd_month = v_rent, lease_end_day = p_day + v_term, deposit_inr = v_dep,
             price_usd = null, start_day = p_day, ordered_day = null
       where aircraft_id = rec.id;
    end if;
  end loop;

  -- arrivals, finished refits, groundings that are over
  update public.aircraft set status = 'active'
   where world_id = p_world and airline_id is not null
     and status in ('delivering', 'refit', 'grounded') and available_day <= p_day;

  -- leases at the end of their term renew at today's market rent
  for rec in
    select y.aircraft_id, y.airline_id, y.lease_usd_month, x.reg, x.type_id, x.built_day
      from public.aircraft_terms y join public.aircraft x on x.id = y.aircraft_id
     where x.world_id = p_world and y.holding = 'lease' and y.lease_end_day < p_day and x.status <> 'delivering'
  loop
    v_rent := game.lease_rent_usd(p_world, rec.type_id, rec.built_day, p_day);
    update public.aircraft_terms set lease_usd_month = v_rent, lease_end_day = lease_end_day + v_term
     where aircraft_id = rec.aircraft_id;
    insert into public.news (world_id, game_day, airline_id, kind, body, private)
    values (p_world, p_day, rec.airline_id, 'fleet', 'The lease on ' || rec.reg || ' was renewed at $' || v_rent
            || ' a month (was $' || rec.lease_usd_month || ').', true);
  end loop;

  -- fleet-wide engine events starting today
  for rec in select * from public.events where world_id = p_world and kind = 'engine_grounding' and starts_day = p_day loop
    update public.aircraft x set status = 'grounded', available_day = rec.ends_day + 1, grounded_day = p_day
      from (select al.id, coalesce(mp.engine_mult, 1) as em
              from public.airlines al
              left join public.airline_ops ao on ao.airline_id = al.id
              left join public.maint_plans mp on mp.key = ao.maint_plan
             where al.world_id = p_world) q
     where x.world_id = p_world and x.type_id = rec.payload ->> 'type' and x.status = 'active' and x.airline_id = q.id
       and random() < (rec.payload ->> 'share')::numeric * q.em;
  end loop;

  -- random technical groundings, more often with age (a wet lessor covers its own aircraft)
  update public.aircraft x
     set status = 'grounded', grounded_day = p_day,
         available_day = p_day + greatest(1, round((v_gmin + floor(random() * (v_gmax - v_gmin + 1))) * q.gl))::int
    from (select al.id, coalesce(mp.ground_mult, 1) as gm, coalesce(mp.ground_len_mult, 1) as gl
            from public.airlines al
            left join public.airline_ops ao on ao.airline_id = al.id
            left join public.maint_plans mp on mp.key = ao.maint_plan
           where al.world_id = p_world) q
   where x.world_id = p_world and x.status = 'active' and x.airline_id = q.id
     and exists (select 1 from public.aircraft_terms y where y.aircraft_id = x.id and y.holding <> 'wet')
     and random() < v_gprob * (1 + v_gage * greatest(0, p_day - x.built_day) / 364.0) * q.gm;
end $$;

-- ops_preview from 0023: the world's own grounding values
create or replace function public.ops_preview(p_airline uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.airlines%rowtype; rw public.worlds%rowtype; ao public.airline_ops%rowtype;
  cp public.maint_plans%rowtype; cs public.op_styles%rowtype;
  v_day int; v_n int; v_age numeric; v_gq numeric; v_floor numeric := game.param('turn_floor_min');
  v_plans jsonb; v_styles jsonb; v_hedges jsonb;
begin
  select * into ra from public.airlines where id = p_airline;
  if not found then raise exception 'Airline not found'; end if;
  if not game.is_server() and (auth.uid() is null or ra.user_id is distinct from auth.uid()) then
    raise exception 'This is not your airline';
  end if;
  select * into rw from public.worlds where id = ra.world_id;
  select * into ao from public.airline_ops where airline_id = p_airline;
  select * into cp from public.maint_plans where key = ao.maint_plan;
  select * into cs from public.op_styles where key = ao.op_style;
  v_day := greatest(rw.game_day, 1);
  select count(*), coalesce(avg(greatest(0, v_day - ac.built_day) / 364.0), 0) into v_n, v_age
    from public.aircraft ac join public.aircraft_terms tm on tm.aircraft_id = ac.id
   where ac.airline_id = p_airline and ac.status in ('active', 'grounded', 'refit') and tm.holding <> 'wet';
  -- technical groundings a quarter at today's ages, before the strategy
  v_gq := v_n * game.wparam(ra.world_id, 'ground_prob_day') * (1 + game.wparam(ra.world_id, 'ground_age_k') * v_age) * 91;

  select jsonb_agg(jsonb_build_object(
           'key', mp.key, 'cost_week', round(coalesce(x.v, 0) * mp.rate_mult * cs.hour_cost_mult + mp.fixed_inr_week),
           'fixed_week', mp.fixed_inr_week, 'groundings_qtr', round(v_gq * mp.ground_mult, 1),
           'days_qtr', round(v_gq * mp.ground_mult * (game.wparam(ra.world_id, 'ground_days_min') + game.wparam(ra.world_id, 'ground_days_max')) / 2 * mp.ground_len_mult, 1),
           'otp_delta', mp.otp_delta, 'lock_weeks', mp.lock_weeks, 'setup_inr', mp.setup_inr, 'setup_weeks', mp.setup_weeks)
         order by mp.sort) into v_plans
    from public.maint_plans mp
    left join lateral (select sum(r.trips * 2 * (r.fh * r.maint_usd_fh + r.maint_usd_cycle) * (1 + mp.age_k * r.age_y)) * rw.fx_inr_usd as v
                         from game.ops_rows(p_airline, v_day, rw.crew_rule) r where not r.wet) x on true;

  select jsonb_agg(jsonb_build_object(
           'key', s.key, 'fuel_kg_week', round(coalesce(f.kg, 0) * s.fuel_mult),
           'fuel_week', round(coalesce(f.kg, 0) * s.fuel_mult * rw.fuel_inr_kg),
           'other_week', round(coalesce(f.hours_cost, 0) * (s.hour_cost_mult - 1) + s.allowance_inr_turn * coalesce(f.deps, 0)),
           'trips_week', coalesce(f.trips, 0), 'trips_fit', coalesce(c.fit, 0), 'over', coalesce(c.over, 0),
           'otp', round(least(0.99, greatest(0, ra.otp - cp.otp_delta - cs.otp_delta + cp.otp_delta + s.otp_delta)), 3),
           'brand_delta', s.brand_delta)
         order by s.sort) into v_styles
    from public.op_styles s
    left join lateral (
      select sum(r.trips * 2 * r.fuel_kg) as kg, sum(r.trips) as trips,
             sum(r.trips * 2) filter (where not r.wet) as deps,
             sum(r.trips * 2 * r.block_h * r.crew_inr_bh) filter (where not r.wet)
               + sum(r.trips * 2 * (r.fh * r.maint_usd_fh + r.maint_usd_cycle) * cp.rate_mult * (1 + cp.age_k * r.age_y) * rw.fx_inr_usd)
                   filter (where not r.wet) as hours_cost
        from game.ops_rows(p_airline, v_day, rw.crew_rule) r) f on true
    left join lateral (
      select sum(floor(7 * a.window_h / (a.h / a.trips)))::int as fit, count(*) filter (where a.h > 7 * a.window_h)::int as over
        from (select r.aircraft_id, max(r.window_h) as window_h, sum(r.trips) as trips,
                     sum(r.trips * 2 * (r.block_h + greatest(v_floor, r.turn_min + s.turn_delta_min) / 60)) as h
                from game.ops_rows(p_airline, v_day, rw.crew_rule) r group by r.aircraft_id) a
       where a.trips > 0) c on true;

  select coalesce(jsonb_agg(jsonb_build_object('week', fh.week, 'share', fh.share, 'price', fh.price_inr_kg) order by fh.week), '[]'::jsonb)
    into v_hedges from public.fuel_hedges fh where fh.airline_id = p_airline;

  return jsonb_build_object(
    'day', v_day, 'aircraft', v_n, 'avg_age', round(v_age, 1),
    'plan', ao.maint_plan, 'plan_next', ao.maint_next, 'plan_next_day', ao.maint_next_day, 'locked_until', ao.maint_locked_until,
    'style', ao.op_style, 'hedge_share', ao.hedge_share,
    'fuel_price', rw.fuel_inr_kg, 'fuel_normal', rw.fuel_walk, 'hedge_premium', game.param('hedge_premium'),
    'hedge_lead_weeks', game.param('hedge_lead_weeks'), 'hedges', v_hedges,
    'plans', v_plans, 'styles', v_styles);
end $$;

-- bot_selling from 0024: each fight draws where it prices (route_plans.fight_pos)
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
     set prev_strategy = pl.strategy, strategy = mv.answer, fight_until = v_w + g.bot_fight_weeks,
         -- 0025: where between its profitable lowest fare (0) and the player's fare (1) it fights; aggressive airlines draw lower
         fight_pos = case when game.param('bot_fight_random') > 0 then power(random(), b.aggression * game.param('bot_fight_skew')) end
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
  update public.route_plans pl set strategy = coalesce(pl.prev_strategy, pl.strategy), prev_strategy = null, fight_until = null, fight_pos = null
    from public.routes r
   where r.id = pl.route_id and r.world_id = p_world and pl.fight_until is not null and pl.fight_until <= v_w;
end $$;

-- sell_week from 0024: computer-run airlines that fight price at the point drawn for the fight, never below cost plus a margin
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
  drop table if exists pg_temp._bfloor;
  create temp table _bfloor on commit drop as
  select d.route_id,
         sum(d.var_cost_inr + d.aircraft_cost_inr)::float8
           / nullif(game.param('bot_sell_floor_lf') * (1 + game.param('bot_floor_anc'))
                    * sum(d.seats_econ + g.biz_fare_mult * d.seats_biz), 0) as floor_e
    from public.route_daily d join public.airlines al on al.id = d.airline_id and al.is_ai
   where al.world_id = p_world and d.game_day > p_day - 28
   group by d.route_id having count(*) >= 7;
  if game.param('bot_sell_floor_lf') > 0 then
    update pg_temp._sell z set pe = greatest(z.pe, round(least(z.mx * z.rp, f.floor_e) / 10) * 10)
      from pg_temp._bfloor f where f.route_id = z.route_id and f.floor_e is not null;
  end if;
  -- 0025: a computer-run airline fighting a player prices each flight week at the point drawn for the fight
  -- (route_plans.fight_pos) between its profitable lowest fare (that floor plus bot_fight_margin; the strategy's lowest
  -- before it has 7 days of results) and the lowest player fare on the market that week; below that lowest it holds
  if game.param('bot_fight_random') > 0 then
    update pg_temp._sell z
       set pe = round(least(z.mx * z.rp, greatest(k.fp, least(k.lo, k.fp + k.pos * (k.lo - k.fp)))) / 10) * 10
      from (select y.route_id, y.week, pp.fight_pos::float8 as pos,
                   coalesce(f.floor_e, y.mn * y.rp) * (1 + game.param('bot_fight_margin')) as fp,
                   (select min(o.pe) from pg_temp._sell o join public.airlines oa on oa.id = o.airline_id and not oa.is_ai
                     where o.a = y.a and o.b = y.b and o.week = y.week) as lo
              from pg_temp._sell y
              join public.route_plans pp on pp.route_id = y.route_id and pp.fight_until is not null and pp.fight_pos is not null
              left join pg_temp._bfloor f on f.route_id = y.route_id) k
     where k.route_id = z.route_id and k.week = z.week and k.lo is not null;
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

revoke all on function game.wparam(uuid, text), game.wrand_between(uuid, text, text), game.day_world(uuid, int),
  game.day_fleet(uuid, int), game.bot_selling(uuid, int), game.sell_week(uuid, int) from public, anon, authenticated;
revoke all on function public.admin_set_disruptions(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_disruptions(uuid, jsonb) to authenticated, service_role;
