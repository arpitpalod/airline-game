-- Daily engine (Stage 2b, part 2). One game day for one world runs in one transaction:
-- prices and events, fleet changes, capacity, demand and spill, money, results, quarter end, insolvency.

-- ---------- Schema additions ----------

alter table public.airline_finance add column insolvent_days int not null default 0;
alter table public.airlines add column administrations int not null default 0;   -- public mark
alter table public.airline_daily
  add column c_depr numeric not null default 0,      -- owned aircraft: depreciation (not cash)
  add column flights numeric not null default 0,
  add column cancelled numeric not null default 0;

create table public.season_factors (   -- demand multiplier by calendar month and segment (G)
  month int primary key check (month between 1 and 12),
  biz numeric not null, lei numeric not null, bud numeric not null
);
alter table public.season_factors enable row level security;
revoke all on public.season_factors from anon, authenticated;
grant select on public.season_factors to authenticated;
create policy read_all on public.season_factors for select to authenticated using (true);
insert into public.season_factors (month, biz, lei, bud) values
(1, 0.98, 1.05, 1.00), (2, 1.03, 1.00, 0.97), (3, 1.03, 0.90, 0.96), (4, 1.00, 1.00, 1.00),
(5, 0.95, 1.20, 1.10), (6, 0.97, 1.00, 1.00), (7, 1.00, 0.85, 0.93), (8, 1.00, 0.85, 0.93),
(9, 1.03, 0.85, 0.92), (10, 1.02, 1.00, 1.05), (11, 1.02, 1.10, 1.10), (12, 0.97, 1.20, 1.04);

create table game.engine_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  world_id uuid, game_day int, message text not null
);
alter table game.engine_log enable row level security;

insert into public.game_params (key, num, note) values
('seg_biz_a', -0.45, 'utility constants: 65% of potential flies when 3 airlines offer 4 flights a day at reference fares'),
('seg_lei_a', 1.82, ''), ('seg_bud_a', 3.59, ''),
('season_start_month', 4, 'calendar month of game day 1'),
('growth_year', 0.07, 'market growth a game year'),
('demand_noise_sd', 0.10, 'day-to-day swing in each market''s demand'),
('fuel_ref_inr_kg', 100, 'level the fuel price drifts back to'),
('fuel_vol_day', 0.012, ''), ('fuel_revert_day', 0.004, ''),
('fx_vol_day', 0.002, ''), ('fx_drift_year', 0.03, 'rupee weakens this much a game year'),
('event_fuel_prob_day', 0.004, 'chance a day that a fuel shock starts'),
('event_fx_prob_day', 0.003, ''), ('event_engine_prob_day', 0.002, ''),
('event_fuel_mult_min', 1.15, 'fuel shock size'), ('event_fuel_mult_max', 1.45, ''),
('event_fuel_days_min', 40, ''), ('event_fuel_days_max', 120, ''),
('event_fx_mult_min', 1.04, 'currency swing size'), ('event_fx_mult_max', 1.10, ''),
('event_fx_days_min', 60, ''), ('event_fx_days_max', 180, ''),
('event_engine_share_min', 0.15, 'share of one type grounded'), ('event_engine_share_max', 0.30, ''),
('event_engine_days_min', 21, ''), ('event_engine_days_max', 56, ''),
('ground_age_k', 0.1, 'extra chance of going technical per year of age'),
('ground_prob_day', 0.004, 'chance a day that an aircraft goes technical, before age'),
('ground_days_min', 2, ''), ('ground_days_max', 6, ''),
('maint_fh_offset', 0.25, 'hours added to cruise time to get flight hours'),
('intl_airport_mult', 2.0, 'foreign landing charge as a multiple of the Indian one'),
('handling_inr_pax', 150, 'airport handling per passenger'),
('slot_base_inr', 3000, 'slot price per movement at an empty congested airport'),
('slot_util_cap', 0.95, 'utilisation above this is priced as this'),
('dist_rev_share', 0.03, 'distribution cost as a share of ticket revenue'),
('service_inr_pax', 120, 'service cost per passenger'),
('overhead_fixed_inr_day', 600000, ''), ('overhead_aircraft_inr_day', 180000, ''), ('base_fixed_inr_day', 150000, ''),
('interest_year', 0.11, 'interest on the credit line'),
('otp_base', 0.92, 'on-time performance with a relaxed schedule'),
('otp_util_k', 0.20, 'on-time loss when an aircraft uses its whole flying window'),
('otp_smooth', 0.3, 'weight of today in the running on-time figure'),
('brand_drift', 0.02, 'share of the gap to its target that brand closes each day'),
('brand_otp_ref', 0.84, 'on-time performance that leaves brand unchanged'), ('brand_otp_k', 100, 'brand points per unit of on-time performance'),
('brand_cancel_k', 300, 'brand points lost per unit of cancellation rate'),
('brand_comfort_ref', 0.17, ''), ('brand_comfort_k', 15, ''),
('brand_mkt_max', 20, 'most brand points marketing can add'),
('brand_mkt_inr_pax', 100, 'marketing rupees per daily passenger that buy 63% of the maximum'),
('brand_mkt_min_pax', 2000, ''),
('restart_cash_inr', 2500000000, 'cash after administration'),
('restart_credit_share', 0.5, 'credit line after administration, as a share of the normal one'),
('restart_brand_hit', 15, 'brand points lost in administration'),
('route_keep_days', 28, 'days of route results kept'),
('tick_max_days', 30, 'most game days processed per world per run');

-- ---------- Helpers ----------

create or replace function game.rand_normal() returns float8
language sql volatile set search_path = '' as $$
  select sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random())
$$;

-- A random number between two game values.
create or replace function game.rand_between(p_lo text, p_hi text) returns numeric
language sql volatile set search_path = '' as $$
  select (game.param(p_lo) + random() * (game.param(p_hi) - game.param(p_lo)))::numeric
$$;

create or replace function game.cabin_crew(p_rule text, p_seats int) returns int   -- same rule as layout_calc
language sql immutable set search_path = '' as $$
  select case when p_rule = 'india' and p_seats <= 50 then 1
              when p_rule = 'india' and p_seats < 100 then 2
              when p_rule = 'india' then 2 + ceil((p_seats - 99) / 50.0)::int
              else ceil(p_seats / 50.0)::int end
$$;

-- The game day the clock has reached (null unless the world is running).
create or replace function game.due_day(p_world uuid) returns int
language sql stable set search_path = '' as $$
  select least(w.season_days,
               floor((extract(epoch from now() - w.started_at) - w.paused_seconds) * w.speed / 86400)::int)
  from public.worlds w where w.id = p_world and w.status = 'running'
$$;

-- ---------- Step 1: fuel price, exchange rate, events ----------

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

  if random() < game.param('event_fuel_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fuel_shock' and ends_day >= p_day) then
    v_m := round(game.rand_between('event_fuel_mult_min', 'event_fuel_mult_max'), 2);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fuel_shock', p_day, p_day, p_day + game.rand_between('event_fuel_days_min', 'event_fuel_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Fuel shock: jet fuel is up ' || round((v_m - 1) * 100) || '%.');
  end if;
  if random() < game.param('event_fx_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fx_swing' and ends_day >= p_day) then
    v_m := round(game.rand_between('event_fx_mult_min', 'event_fx_mult_max'), 3);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fx_swing', p_day, p_day, p_day + game.rand_between('event_fx_days_min', 'event_fx_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Currency swing: the rupee has weakened ' || round((v_m - 1) * 100, 1) || '% against the dollar.');
  end if;
  if random() < game.param('event_engine_prob_day') then
    select x.type_id into v_type from public.aircraft x
     where x.world_id = p_world and x.status = 'active' and x.airline_id is not null
     group by x.type_id order by random() limit 1;
    if v_type is not null then
      insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
      values (p_world, 'engine_grounding', p_day, p_day, p_day + game.rand_between('event_engine_days_min', 'event_engine_days_max')::int,
              jsonb_build_object('type', v_type, 'share', round(game.rand_between('event_engine_share_min', 'event_engine_share_max'), 2)));
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

-- ---------- Step 2: deliveries, lease renewals, refits, groundings ----------

create or replace function game.day_fleet(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_bal numeric; v_rent numeric; v_dep numeric;
  v_term int := game.param('lease_term_days')::int;
  v_gmin int := game.param('ground_days_min')::int;
  v_gmax int := game.param('ground_days_max')::int;
  v_gprob numeric := game.param('ground_prob_day');
  v_gage numeric := game.param('ground_age_k');
begin
  select * into rw from public.worlds where id = p_world;

  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, x.airline_id, 'fleet', t.name || ' ' || x.reg || ' has joined your fleet at ' || x.base_iata || '.', true
    from public.aircraft x join public.aircraft_types t on t.id = x.type_id
   where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and x.airline_id is not null;

  -- new aircraft from the manufacturer: pay the balance, or sell and lease back
  for rec in
    select x.id, x.reg, y.airline_id, y.price_usd, y.deposit_inr, y.pay_plan, t.lease_usd_month
      from public.aircraft x
      join public.aircraft_terms y on y.aircraft_id = x.id
      join public.aircraft_types t on t.id = x.type_id
     where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and y.ordered_day is not null
  loop
    v_bal := round(rec.price_usd * rw.fx_inr_usd) - rec.deposit_inr;
    if rec.pay_plan = 'cash'
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
    update public.aircraft set status = 'grounded', available_day = rec.ends_day + 1
     where world_id = p_world and type_id = rec.payload ->> 'type' and status = 'active' and airline_id is not null
       and random() < (rec.payload ->> 'share')::numeric;
  end loop;

  -- random technical groundings, more often with age (a wet lessor covers its own aircraft)
  update public.aircraft x
     set status = 'grounded', available_day = p_day + v_gmin + floor(random() * (v_gmax - v_gmin + 1))::int
   where x.world_id = p_world and x.status = 'active' and x.airline_id is not null
     and exists (select 1 from public.aircraft_terms y where y.aircraft_id = x.id and y.holding <> 'wet')
     and random() < v_gprob * (1 + v_gage * greatest(0, p_day - x.built_day) / 364.0);
end $$;

-- ---------- Steps 3 to 6: capacity, demand, money, results ----------

create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    seg_biz_a numeric, seg_biz_price numeric, seg_biz_freq numeric, seg_biz_comfort numeric, seg_biz_brand numeric,
    seg_lei_a numeric, seg_lei_price numeric, seg_lei_freq numeric, seg_lei_comfort numeric, seg_lei_brand numeric,
    seg_bud_a numeric, seg_bud_price numeric, seg_bud_freq numeric, seg_bud_comfort numeric, seg_bud_brand numeric,
    biz_fare_mult numeric, spill_recapture numeric, ancillary_share numeric, demand_noise_sd numeric,
    growth_year numeric, season_start_month numeric, age_fuel_per_year numeric, age_maint_per_year numeric,
    maint_fh_offset numeric, cabin_inr_bh numeric, cabin_fixed_inr_day numeric, intl_airport_mult numeric,
    handling_inr_pax numeric, slot_base_inr numeric, slot_util_cap numeric, dist_rev_share numeric,
    service_inr_pax numeric, wet_min_hours_day numeric, depreciation_year numeric, overhead_fixed_inr_day numeric,
    overhead_aircraft_inr_day numeric, base_fixed_inr_day numeric, interest_year numeric, otp_base numeric,
    otp_util_k numeric, otp_smooth numeric, brand_drift numeric, brand_otp_ref numeric, brand_otp_k numeric, brand_cancel_k numeric,
    brand_comfort_ref numeric, brand_comfort_k numeric, brand_mkt_max numeric, brand_mkt_inr_pax numeric,
    brand_mkt_min_pax numeric, route_keep_days numeric);

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
    c_airport numeric default 0, c_slots numeric default 0
  ) on commit drop;
  create temp table if not exists _prod (  -- one row per airline per market: what it offers and what it sells
    route_id uuid primary key, airline_id uuid, a text, b text, km int,
    f numeric, f_b numeric, cap_e numeric, cap_b numeric,   -- flights and seats a day, each way
    comf_e numeric, comf_b numeric, block_h numeric, fare_e numeric, fare_b numeric, ref numeric, brand numeric,
    n_biz numeric, n_lei numeric, n_bud numeric,
    xb_e numeric, xb_b numeric, xl numeric, xu numeric,     -- exp(utility) by segment and cabin
    dem_e numeric, dem_b numeric, pax_e numeric, pax_b numeric, spill numeric,
    pe numeric, pb numeric, rev numeric                      -- both directions
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod;

  -- Step 3: capacity from the rotations of aircraft in service (grounded aircraft cancel their flights)
  insert into pg_temp._rot (route_id, airline_id, aircraft_id, type_id, a, b, km, intl, f, flown, wet,
                            seats_e, seats_b, comf_e, comf_b, block_h, turn_min, age_y, crew)
  select r.id, r.airline_id, ac.id, ac.type_id, m.a, m.b, m.km, m.intl, ro.weekly_trips / 7.0,
         ac.status = 'active', tm.holding = 'wet', ac.seats_econ, ac.seats_biz,
         (ac.econ_pitch - 28) / 6.0,
         case when ac.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (ac.biz_pitch - 36) / 12.0 end,
         m.km::numeric / t.cruise_kmh + t.block_offset_h,
         greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (ac.seats_econ + ac.seats_biz - t.ref_seats)),
         greatest(0, p_day - ac.built_day) / 364.0,
         game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz)
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.status = 'active'
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id and ac.status in ('active', 'grounded')
    join public.aircraft_types t on t.id = ac.type_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where r.world_id = p_world and r.status = 'open';

  -- Step 4: demand. Market size today, then each airline's share, then spill.
  insert into pg_temp._prod (route_id, airline_id, a, b, km, f, f_b, cap_e, cap_b, comf_e, comf_b, block_h,
                             fare_e, fare_b, ref, brand, n_biz, n_lei, n_bud)
  with mk as materialized (
    select q.a, q.b, exp(g.demand_noise_sd * game.rand_normal() - g.demand_noise_sd * g.demand_noise_sd / 2) * v_grow as k
      from (select distinct a, b from pg_temp._rot where flown) q)
  select s.route_id, s.airline_id, s.a, s.b, s.km, s.f, s.f_b, s.cap_e, s.cap_b, coalesce(s.comf_e, 0), coalesce(s.comf_b, 0),
         s.block_h, r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)), m.ref_fare, al.brand,
         m.n_biz * v_sb * mk.k, m.n_lei * v_sl * mk.k, m.n_bud * v_su * mk.k
    from (select route_id, airline_id, a, b, km, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
                 sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
                 sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
                 sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
                 sum(f * block_h) / sum(f) as block_h
            from pg_temp._rot where flown group by route_id, airline_id, a, b, km) s
    join public.routes r on r.id = s.route_id
    join public.airlines al on al.id = s.airline_id
    join public.markets m on m.a = s.a and m.b = s.b
    join mk on mk.a = s.a and mk.b = s.b;

  -- U = a - b x fare / reference + c x ln(1 + flights) + d x comfort x sqrt(block hours) + e x (brand - 50) / 50
  update pg_temp._prod set
    xb_e = case when cap_e > 0 then exp(g.seg_biz_a - g.seg_biz_price * fare_e / ref + g.seg_biz_freq * ln(1 + f)
             + g.seg_biz_comfort * comf_e * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) else 0 end,
    xb_b = case when cap_b > 0 then exp(g.seg_biz_a - g.seg_biz_price * fare_b / (ref * g.biz_fare_mult) + g.seg_biz_freq * ln(1 + f_b)
             + g.seg_biz_comfort * comf_b * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) else 0 end,
    xl   = case when cap_e > 0 then exp(g.seg_lei_a - g.seg_lei_price * fare_e / ref + g.seg_lei_freq * ln(1 + f)
             + g.seg_lei_comfort * comf_e * sqrt(block_h) + g.seg_lei_brand * (brand - 50) / 50) else 0 end,
    xu   = case when cap_e > 0 then exp(g.seg_bud_a - g.seg_bud_price * fare_e / ref + g.seg_bud_freq * ln(1 + f)
             + g.seg_bud_comfort * comf_e * sqrt(block_h) + g.seg_bud_brand * (brand - 50) / 50) else 0 end;

  -- share = exp(U) / (1 + sum of exp(U)); the 1 is the option of not flying
  update pg_temp._prod p set dem_e = s.dem_e, dem_b = s.dem_b
    from (select route_id,
                 n_biz * xb_e / (1 + sum(xb_e + xb_b) over mkt) + n_lei * xl / (1 + sum(xl) over mkt)
                   + n_bud * xu / (1 + sum(xu) over mkt) as dem_e,
                 n_biz * xb_b / (1 + sum(xb_e + xb_b) over mkt) as dem_b
            from pg_temp._prod window mkt as (partition by a, b)) s
   where s.route_id = p.route_id;

  -- spill: a share of travellers who find no seat move to airlines in the same cabin with seats left
  update pg_temp._prod p
     set pax_e = s.pax_e, pax_b = s.pax_b, spill = s.spill, pe = round(2 * s.pax_e), pb = round(2 * s.pax_b),
         rev = round(2 * s.pax_e) * p.fare_e + round(2 * s.pax_b) * p.fare_b
    from (select route_id,
                 least(dem_e, cap_e) + case when sum(greatest(cap_e - dem_e, 0)) over mkt > 0 then
                   least(greatest(cap_e - dem_e, 0), g.spill_recapture * sum(greatest(dem_e - cap_e, 0)) over mkt
                         * greatest(cap_e - dem_e, 0) / sum(greatest(cap_e - dem_e, 0)) over mkt) else 0 end as pax_e,
                 least(dem_b, cap_b) + case when sum(greatest(cap_b - dem_b, 0)) over mkt > 0 then
                   least(greatest(cap_b - dem_b, 0), g.spill_recapture * sum(greatest(dem_b - cap_b, 0)) over mkt
                         * greatest(cap_b - dem_b, 0) / sum(greatest(cap_b - dem_b, 0)) over mkt) else 0 end as pax_b,
                 greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) as spill
            from pg_temp._prod window mkt as (partition by a, b)) s
   where s.route_id = p.route_id;

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is.
  with mv as (
    select z.iata, sum(z.m) as moves
      from (select a as iata, 2 * f as m from pg_temp._rot where flown
            union all select b, 2 * f from pg_temp._rot where flown) z
     group by z.iata),
  sp as (
    select ap.iata, g.slot_base_inr / power(1 - least(g.slot_util_cap, mv.moves / (ap.slot_cap * rw.slot_scale)), 2) as price
      from mv join public.airports ap on ap.iata = mv.iata
     where ap.slot_cap is not null)
  update pg_temp._rot x set
    c_fuel = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * rw.fuel_inr_kg,
    c_crew = case when x.wet then 0 else 2 * x.f * x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * (1 + g.age_maint_per_year * x.age_y) * rw.fx_inr_usd end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0))
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id;

  -- Step 6: results
  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev * (1 + g.ancillary_share)),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb))
    from pg_temp._prod p
    join (select route_id, sum(c_fuel + c_crew + c_maint + c_airport + c_slots) as var
            from pg_temp._rot where flown group by route_id) c on c.route_id = p.route_id;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.rev, 0) * g.ancillary_share),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0)), round(coalesce(rc.maint, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0)
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
                            when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'wet' then 0 else
                            t.pilot_fixed_inr_day + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
                where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
                group by tm.airline_id) fl on fl.airline_id = al.id
    left join (select airline_id, -sum(pnl_inr) as other from public.transactions where game_day = p_day group by airline_id) tx
           on tx.airline_id = al.id
   where al.world_id = p_world and al.status = 'active';

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + d.rev_ticket + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  -- punctuality: tight schedules run late. Brand drifts toward a target built from punctuality,
  -- cancellations, cabin comfort and marketing per passenger.
  update public.airlines al set otp = round((1 - g.otp_smooth) * al.otp + g.otp_smooth * s.otp, 4)
    from (select u.airline_id, sum(u.fl * (g.otp_base - g.otp_util_k * greatest(0, u.util - 0.85) / 0.15)) / sum(u.fl) as otp
            from (select x.airline_id, x.aircraft_id, sum(2 * x.f) as fl,
                         sum(2 * x.f * (x.block_h + x.turn_min / 60)) / max(t.day_window_h) as util
                    from pg_temp._rot x join public.aircraft_types t on t.id = x.type_id
                   where x.flown group by x.airline_id, x.aircraft_id) u
           group by u.airline_id) s
   where al.id = s.airline_id;

  update public.airlines al
     set brand = round(least(100, greatest(0, al.brand + g.brand_drift * (
           50 + g.brand_otp_k * (al.otp - g.brand_otp_ref)
              - g.brand_cancel_k * coalesce(d.cancelled / nullif(d.flights + d.cancelled, 0), 0)
              + g.brand_comfort_k * (coalesce(c.comf, g.brand_comfort_ref) - g.brand_comfort_ref)
              + g.brand_mkt_max * (1 - exp(-al.marketing_inr_day / (g.brand_mkt_inr_pax * greatest(d.pax, g.brand_mkt_min_pax))))
           - al.brand))), 2)
    from public.airline_daily d
    left join (select airline_id, sum(cap_e * comf_e) / nullif(sum(cap_e), 0) as comf from pg_temp._prod group by airline_id) c
           on c.airline_id = d.airline_id
   where d.airline_id = al.id and d.game_day = p_day and al.world_id = p_world and al.status = 'active';

  delete from public.route_daily rd using public.airlines al
   where al.id = rd.airline_id and al.world_id = p_world and rd.game_day <= p_day - g.route_keep_days::int;
end $$;

-- ---------- Step 7: quarter end ----------

create or replace function game.day_quarter(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_q int := p_day / 91;
  v_n int;
begin
  select * into rw from public.worlds where id = p_world;

  insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax, load_factor, rask, cask,
                                        otp, brand, net_worth)
  select al.id, v_q, s.rev, s.rev - s.cost, s.rev - s.cost - s.interest, s.pax,
         round(s.rpk / nullif(s.ask, 0), 4), round(s.rev / nullif(s.ask, 0), 3), round(s.cost / nullif(s.ask, 0), 3),
         al.otp, al.brand, round(fin.cash_inr - fin.debt_inr + coalesce(ast.v, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    join (select airline_id, sum(rev_ticket + rev_anc) as rev, sum(c_interest) as interest, sum(pax) as pax,
                 sum(ask) as ask, sum(rpk) as rpk,
                 sum(c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead
                     + c_other + c_depr) as cost
            from public.airline_daily where game_day > p_day - 91 and game_day <= p_day group by airline_id) s
      on s.airline_id = al.id
    left join (select airline_id,
                      sum(deposit_inr + case when holding = 'owned' and ordered_day is null
                            then game.book_value_usd(price_usd, start_day, p_day) * rw.fx_inr_usd else 0 end) as v
                 from public.aircraft_terms group by airline_id) ast on ast.airline_id = al.id
   where al.world_id = p_world and al.status = 'active';

  -- season score: net worth + 5 x operating profit of the last four quarters
  update public.quarterly_reports q
     set score = round(q.net_worth + game.param('score_profit_mult')
                 * (select sum(h.op_profit) from public.quarterly_reports h
                     where h.airline_id = q.airline_id and h.quarter > v_q - 4 and h.quarter <= v_q))
    from public.airlines al
   where al.id = q.airline_id and al.world_id = p_world and q.quarter = v_q;
  update public.quarterly_reports q set rank = s.rk
    from (select h.airline_id, rank() over (order by h.score desc) as rk
            from public.quarterly_reports h join public.airlines al on al.id = h.airline_id
           where al.world_id = p_world and h.quarter = v_q) s
   where q.airline_id = s.airline_id and q.quarter = v_q;

  insert into public.news (world_id, game_day, kind, body)
  select p_world, p_day, 'results', 'Quarter ' || v_q || ' results are out. Leaders: ' || string_agg(s.name, ', ' order by s.rank) || '.'
    from (select al.name, q.rank from public.quarterly_reports q join public.airlines al on al.id = q.airline_id
           where al.world_id = p_world and q.quarter = v_q and q.rank <= 3) s
  having count(*) > 0;

  -- lessors add aircraft, up to the target
  for rec in select type_id, target from public.pool_targets where world_id = p_world loop
    select count(*) into v_n from public.aircraft where world_id = p_world and type_id = rec.type_id and status = 'pool';
    perform game.fill_pool(p_world, rec.type_id,
                           least(ceil(rec.target * game.param('pool_refill_share'))::int, rec.target - v_n), p_day);
  end loop;
end $$;

-- ---------- Step 8: insolvency ----------

-- Lessors repossess, orders are cancelled, routes close; the airline restarts with reduced capital.
create or replace function game.administer(p_airline uuid, p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
begin
  delete from public.rotations ro using public.routes r where r.id = ro.route_id and r.airline_id = p_airline;
  update public.routes set status = 'closed' where airline_id = p_airline and status = 'open';
  update public.aircraft x
     set airline_id = null, base_iata = null, available_day = p_day,
         status = case when y.holding = 'wet' or (x.status = 'delivering' and y.ordered_day is not null)
                       then 'returned' else 'pool' end
    from public.aircraft_terms y
   where y.aircraft_id = x.id and y.airline_id = p_airline;
  delete from public.aircraft_terms where airline_id = p_airline;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select p_airline, p_day, 'administration', game.param('restart_cash_inr') - cash_inr,
         'Administration: fleet and debts gone, restart capital paid in'
    from public.airline_finance where airline_id = p_airline;
  update public.airline_finance
     set cash_inr = game.param('restart_cash_inr'), debt_inr = 0, insolvent_days = 0,
         credit_limit_inr = round(game.param('credit_limit_inr') * game.param('restart_credit_share'))
   where airline_id = p_airline;
  update public.airlines
     set administrations = administrations + 1, brand = greatest(0, brand - game.param('restart_brand_hit')), marketing_inr_day = 0
   where id = p_airline;
  insert into public.news (world_id, game_day, airline_id, kind, body)
  select p_world, p_day, p_airline, 'administration', name || ' has gone into administration and restarts with reduced capital.'
    from public.airlines where id = p_airline;
end $$;

create or replace function game.day_solvency(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rec record;
begin
  -- a shortfall is drawn from the credit line while it lasts
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select fin.airline_id, p_day, 'borrow', least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr), 'Shortfall covered from the credit line'
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;
  update public.airline_finance fin
     set debt_inr = fin.debt_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr),
         cash_inr = fin.cash_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr)
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;

  update public.airline_finance fin
     set insolvent_days = case when fin.cash_inr < 0 then fin.insolvent_days + 1 else 0 end
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and al.status = 'active';

  update public.airline_daily d set cash_end = fin.cash_inr, brand = al.brand, otp = al.otp
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  for rec in
    select fin.airline_id from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
     where al.world_id = p_world and al.status = 'active' and fin.insolvent_days >= game.param('insolvency_days')
  loop
    perform game.administer(rec.airline_id, p_world, p_day);
  end loop;
end $$;

-- ---------- One game day, and the clock ----------

-- Processes the next game day of a world. Returns the day, or null if the world is not running.
create or replace function game.run_day(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_day int;
begin
  perform pg_advisory_xact_lock(hashtextextended('day:' || p_world, 0));
  select * into rw from public.worlds where id = p_world for update;
  if not found or rw.status <> 'running' or rw.game_day >= rw.season_days then return null; end if;
  v_day := rw.game_day + 1;
  perform game.day_world(p_world, v_day);
  perform game.day_fleet(p_world, v_day);
  perform game.day_ops(p_world, v_day);
  if v_day % 91 = 0 then perform game.day_quarter(p_world, v_day); end if;
  perform game.day_solvency(p_world, v_day);
  update public.worlds set game_day = v_day, status = case when v_day >= season_days then 'ended' else status end
   where id = p_world;
  if v_day >= rw.season_days then
    insert into public.news (world_id, game_day, kind, body) values (p_world, v_day, 'season', 'The season has ended.');
  end if;
  return v_day;
end $$;

-- Catches every running world up with its clock. A day that fails is rolled back, logged and retried next run.
create or replace function game.tick() returns int
language plpgsql set search_path = '' as $$
declare
  rec record;
  v_due int; v_done int := 0; v_n int;
  v_max int := game.param('tick_max_days')::int;
begin
  for rec in select id from public.worlds where status = 'running' loop
    v_due := game.due_day(rec.id);
    v_n := 0;
    while v_n < v_max and (select game_day from public.worlds where id = rec.id) < v_due loop
      begin
        perform game.run_day(rec.id);
      exception when others then
        insert into game.engine_log (world_id, game_day, message)
        select rec.id, game_day + 1, sqlerrm from public.worlds where id = rec.id;
        exit;
      end;
      v_n := v_n + 1;
      v_done := v_done + 1;
    end loop;
  end loop;
  return v_done;
end $$;

revoke all on all functions in schema game from public, anon, authenticated;
