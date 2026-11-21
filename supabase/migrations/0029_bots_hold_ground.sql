-- Migration 0029 (spec 14.24): computer-run airlines that hold their ground in a full world (owner, 21 Nov 2026; open
-- items 16 and 24). Season runs with 18 players showed the smaller computer-run airlines flying 50 to 65% full and losing
-- 20 to 98% in year 2, with fleets halving in a year.
--  * Head office grows with the fleet, for every airline: the fixed Rs 6 lakh a day is paid in full from
--    overhead_full_fleet (20) aircraft, and in proportion below, from overhead_min_share (a quarter).
--  * Concentrate instead of thinning (bot_quarter): a losing route closes outright when it loses more than
--    bot_close_margin (15%) or a cut would leave it below bot_keep_weekly (7) round trips a week; the eight busiest domestic
--    markets are never closed this way, and an airline keeps bot_keep_routes routes. The other losing routes are cut by a
--    quarter as before, to no fewer than 7 round trips a week.
--  * Fight smarter: a computer-run airline fights or follows a player only on a market where it holds at least
--    bot_defend_share (40%) of the seats (bot_selling).
--  Tried and left out: a lowest fare at the load a route actually flies (not 80%). In season runs it priced the smaller
--  computer-run airlines out of their markets (loads fell to 30 to 55% and losses passed 100%).

insert into public.game_params (key, num, note) values
('overhead_full_fleet', 20, 'head office: paid in full from this many aircraft, in proportion below'),
('overhead_min_share', 0.25, 'head office: the least share of the full cost, however small the fleet'),
('bot_concentrate', 1, 'computer-run airlines close losing routes instead of thinning them (0: as before 0029)'),
('bot_close_margin', -0.15, 'computer-run airlines close a route losing more than this share of its revenue over 28 days'),
('bot_keep_weekly', 7, 'computer-run airlines keep at least this many round trips a week on a route, or close it when it loses money'),
('bot_defend_share', 0.4, 'computer-run airlines fight or follow a player only where they hold at least this share of the market''s seats');

-- day_ops from 0028: head office grows with the fleet (0029)
create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
  v_pbh numeric; v_res numeric := game.param('pilot_reserve'); v_aug_bh numeric := game.param('pilot_aug_bh'); v_aug numeric := game.param('pilot_aug_mult');
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record(game.params_for(p_world)) as x(   -- 0027: the world's own values
    seg_biz_a numeric, seg_biz_price numeric, seg_biz_freq numeric, seg_biz_comfort numeric, seg_biz_brand numeric,
    seg_lei_a numeric, seg_lei_price numeric, seg_lei_freq numeric, seg_lei_comfort numeric, seg_lei_brand numeric,
    seg_bud_a numeric, seg_bud_price numeric, seg_bud_freq numeric, seg_bud_comfort numeric, seg_bud_brand numeric,
    biz_fare_mult numeric, spill_recapture numeric, ancillary_share numeric, demand_noise_sd numeric,
    growth_year numeric, season_start_month numeric, age_fuel_per_year numeric, age_maint_per_year numeric,
    maint_fh_offset numeric, cabin_inr_bh numeric, cabin_fixed_inr_day numeric, intl_airport_mult numeric,
    handling_inr_pax numeric, slot_base_inr numeric, slot_util_cap numeric, dist_rev_share numeric,
    service_inr_pax numeric, wet_min_hours_day numeric, depreciation_year numeric, overhead_fixed_inr_day numeric,
    overhead_aircraft_inr_day numeric, overhead_seat_inr_day numeric, base_fixed_inr_day numeric, interest_year numeric, otp_base numeric,
    otp_util_k numeric, otp_smooth numeric, brand_drift numeric, brand_otp_ref numeric, brand_otp_k numeric, brand_cancel_k numeric,
    brand_comfort_ref numeric, brand_comfort_k numeric, brand_mkt_max numeric, brand_mkt_inr_pax numeric,
    brand_mkt_min_pax numeric, route_keep_days numeric, nest_lambda numeric, biz_downgrade_share numeric, seg_biz_cabin_a numeric,
    loan_rate_year numeric, anc_biz_share numeric, slot_ref_seats numeric, overhead_full_fleet numeric, overhead_min_share numeric);

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    fuel_kg numeric default 0, c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
    c_airport numeric default 0, c_slots numeric default 0
  ) on commit drop;
  create temp table if not exists _prod (  -- one row per airline per market: what it offers and what it sells
    route_id uuid primary key, airline_id uuid, a text, b text, km int,
    f numeric, f_b numeric, cap_e numeric, cap_b numeric,   -- flights and seats a day, each way
    comf_e numeric, comf_b numeric, block_h numeric, fare_e numeric, fare_b numeric, ref numeric, brand numeric,
    n_biz numeric, n_lei numeric, n_bud numeric,
    xb_e numeric, xb_b numeric, xl numeric, xu numeric,     -- exp(utility / lambda) by segment and cabin
    d_be numeric, d_bb numeric, d_l numeric, d_u numeric,   -- demand by segment: business in economy, in business, leisure, budget
    dg numeric,                                             -- business travellers moved down to economy
    dem_e numeric, dem_b numeric, pax_e numeric, pax_b numeric, spill numeric,
    pe numeric, pb numeric, rev numeric,                     -- both directions
    ad_b numeric, ad_l numeric, ad_u numeric,               -- extras: change in perceived fare by segment, in reference fares
    an_y numeric, an_c numeric, anc numeric, anc_cost numeric, -- extras: revenue and cost per economy passenger (reference fares), totals
    refund numeric default 0,                               -- selling worlds: money back for today's cancelled flights
    sales_x numeric default 0                               -- 0026: sales team abroad on international routes
  ) on commit drop;
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  create temp table if not exists _cxl (   -- 0028: refunds on routes with every flight cancelled today
    airline_id uuid, refund numeric
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx, pg_temp._cxl;

  -- Ops (migration 0023): each airline's maintenance strategy, operating style and this week's fuel hedge
  create temp table if not exists _ops (
    airline_id uuid primary key, rate numeric, age_k numeric, fixed_day numeric, fuel_mult numeric, hour_mult numeric,
    turn_d numeric, allowance numeric, otp_d numeric, brand_d numeric, h_share numeric, h_price numeric,
    fx numeric                                     -- 0026: the airline's rupees a dollar this week, with its dollar hedge
  ) on commit drop;
  truncate pg_temp._ops;
  insert into pg_temp._ops
  select al.id, coalesce(mp.rate_mult, 1), coalesce(mp.age_k, g.age_maint_per_year), coalesce(mp.fixed_inr_week, 0) / 7,
         coalesce(st.fuel_mult, 1), coalesce(st.hour_cost_mult, 1), coalesce(st.turn_delta_min, 0), coalesce(st.allowance_inr_turn, 0),
         coalesce(mp.otp_delta, 0) + coalesce(st.otp_delta, 0), coalesce(st.brand_delta, 0),
         coalesce(fh.share, 0), coalesce(fh.price_inr_kg, rw.fuel_inr_kg),
         coalesce(uh.share, 0) * coalesce(uh.rate_inr_usd, rw.fx_inr_usd) + (1 - coalesce(uh.share, 0)) * rw.fx_inr_usd
    from public.airlines al
    left join public.airline_ops ao on ao.airline_id = al.id
    left join public.maint_plans mp on mp.key = ao.maint_plan
    left join public.op_styles st on st.key = ao.op_style
    left join public.fuel_hedges fh on fh.airline_id = al.id and fh.week = game.week_of(p_day)
    left join public.usd_hedges uh on uh.airline_id = al.id and uh.week = game.week_of(p_day)
   where al.world_id = p_world and al.status = 'active';

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
    join public.airlines al on al.id = r.airline_id and al.status = 'active' and al.first_flight_day <= p_day
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id and ac.status in ('active', 'grounded')
    join public.aircraft_types t on t.id = ac.type_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where r.world_id = p_world and r.status = 'open' and r.first_flight_day <= p_day;

  -- 0028: an airspace closure. Routes between north India and the regions behind it fly round it (airspace_detours):
  -- more km, block hours, fuel, crew and maintenance.
  update pg_temp._rot x set km = x.km + d.detour_km,
                            block_h = (x.km + d.detour_km)::numeric / t.cruise_kmh + t.block_offset_h
    from public.events e, public.airports ia, public.airports fa, public.airspace_detours d, public.aircraft_types t
   where e.world_id = p_world and e.kind = 'airspace_closed' and e.starts_day <= p_day and e.ends_day >= p_day
     and x.intl and t.id = x.type_id
     and ia.iata in (x.a, x.b) and fa.iata in (x.a, x.b) and ia.is_india and not fa.is_india
     and ia.lat >= coalesce((e.payload ->> 'lat_min')::numeric, game.param('airspace_lat_min')) and d.region = fa.region;

  -- an idle aircraft (no rotations) of the same type at the same base flies a grounded aircraft's rotations
  with gr as (
    select x.aircraft_id, x.airline_id, x.type_id, ac.base_iata,
           row_number() over (partition by x.airline_id, x.type_id, ac.base_iata order by x.aircraft_id) as n
      from (select distinct aircraft_id, airline_id, type_id from pg_temp._rot where not flown) x
      join public.aircraft ac on ac.id = x.aircraft_id),
  sp as (
    select ac.*, tm.holding,
           row_number() over (partition by ac.airline_id, ac.type_id, ac.base_iata order by ac.id) as n
      from public.aircraft ac
      join public.aircraft_terms tm on tm.aircraft_id = ac.id
     where ac.world_id = p_world and ac.status = 'active' and ac.airline_id is not null
       and not exists (select 1 from public.rotations ro where ro.aircraft_id = ac.id))
  update pg_temp._rot x
     set aircraft_id = sp.id, flown = true, wet = sp.holding = 'wet', seats_e = sp.seats_econ, seats_b = sp.seats_biz,
         comf_e = (sp.econ_pitch - 28) / 6.0,
         comf_b = case when sp.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (sp.biz_pitch - 36) / 12.0 end,
         turn_min = greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (sp.seats_econ + sp.seats_biz - t.ref_seats)),
         age_y = greatest(0, p_day - sp.built_day) / 364.0,
         crew = game.cabin_crew(rw.crew_rule, sp.seats_econ + sp.seats_biz)
    from gr
    join sp on sp.airline_id = gr.airline_id and sp.type_id = gr.type_id and sp.base_iata = gr.base_iata and sp.n = gr.n
    join public.aircraft_types t on t.id = sp.type_id
   where x.aircraft_id = gr.aircraft_id and not x.flown;

  -- operating style (0023): every turnaround changes by the style's minutes, never below the floor
  update pg_temp._rot x set turn_min = greatest(game.param('turn_floor_min'), x.turn_min + o.turn_d)
    from pg_temp._ops o where o.airline_id = x.airline_id and o.turn_d <> 0;

  -- 0028: an aircraft that cannot reach on a longer way round cancels; so does every flight to or from a closed airport
  update pg_temp._rot x set flown = false
    from public.aircraft_types t
   where x.flown and t.id = x.type_id
     and x.km > t.range_km * least(1.10, 1 - 0.4 * (x.seats_e + x.seats_b - t.ref_seats)::numeric / t.ref_seats);
  update pg_temp._rot x set flown = false
    from public.events e
   where x.flown and e.world_id = p_world and e.kind = 'airport_closed' and e.starts_day <= p_day and e.ends_day >= p_day
     and e.payload ->> 'airport' in (x.a, x.b);

  -- pilots (migration 0013): an airline short of crew for a fleet family cancels flights at random until the rest can be crewed.
  -- A family's crews can fly least(captains, first officers) x hours per pilot / (1 + reserve) block hours a day.
  if rw.pilots then
    v_pbh := game.pilot_bh(p_world, p_day);
    update pg_temp._rot x set flown = false
      from (select z.rid
              from (select x2.ctid as rid, x2.airline_id, t.pilot_family as family,
                           sum(2 * x2.f * x2.block_h * case when x2.block_h > v_aug_bh then v_aug else 1 end)
                             over (partition by x2.airline_id, t.pilot_family order by random() rows unbounded preceding) as cum
                      from pg_temp._rot x2 join public.aircraft_types t on t.id = x2.type_id
                     where x2.flown and not x2.wet) z
              left join public.airline_pilots ap on ap.airline_id = z.airline_id and ap.family = z.family
             where z.cum > coalesce(least(ap.captains, ap.fos), 0) * v_pbh / (1 + v_res) + 1e-6) c
     where x.ctid = c.rid;
  end if;

  -- Step 4: demand. Market size today, then each airline's share, then spill.
  insert into pg_temp._prod (route_id, airline_id, a, b, km, f, f_b, cap_e, cap_b, comf_e, comf_b, block_h,
                             fare_e, fare_b, ref, brand, n_biz, n_lei, n_bud, ad_b, ad_l, ad_u, an_y, an_c)
  with ax as materialized (   -- each airline's extras, set for its whole network
    select q.airline_id, t.d_biz, t.d_lei, t.d_bud, t.yield, t.cost
      from (select distinct airline_id from pg_temp._rot where flown) q cross join lateral game.anc_terms(q.airline_id) t),
  mk as materialized (
    select q.a, q.b, exp(g.demand_noise_sd * game.rand_normal() - g.demand_noise_sd * g.demand_noise_sd / 2) * v_grow as k
      from (select distinct a, b from pg_temp._rot where flown) q)
  select s.route_id, s.airline_id, s.a, s.b, s.km, s.f, s.f_b, s.cap_e, s.cap_b, coalesce(s.comf_e, 0), coalesce(s.comf_b, 0),
         s.block_h, r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)), m.ref_fare, al.brand,
         m.n_biz * v_sb * mk.k, m.n_lei * v_sl * mk.k, m.n_bud * v_su * mk.k,
         ax.d_biz, ax.d_lei, ax.d_bud, ax.yield, ax.cost
    from (select route_id, airline_id, a, b, km, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
                 sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
                 sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
                 sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
                 sum(f * block_h) / sum(f) as block_h
            from pg_temp._rot where flown group by route_id, airline_id, a, b, km) s
    join public.routes r on r.id = s.route_id
    join public.airlines al on al.id = s.airline_id
    join public.markets m on m.a = s.a and m.b = s.b
    join mk on mk.a = s.a and mk.b = s.b
    join ax on ax.airline_id = s.airline_id;

  if rw.selling then
    -- Selling worlds (migration 0019): today's passengers are a seventh of the week's bookings who turned up and could
    -- board; each fare counts as paid (no-shows' fares with them). Flights cancelled today refund their passengers.
    update pg_temp._prod p
       set pax_e = least(p.cap_e, coalesce(w.flown_e, 0) / 7), pax_b = least(p.cap_b, coalesce(w.flown_b, 0) / 7),
           fare_e = coalesce(w.rev_flown_e / nullif(w.flown_e, 0), p.fare_e),
           fare_b = coalesce(w.rev_flown_b / nullif(w.flown_b, 0), p.fare_b),
           refund = 2 * (greatest(0, coalesce(w.flown_e, 0) / 7 - p.cap_e) * coalesce(w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0), 0)
                       + greatest(0, coalesce(w.flown_b, 0) / 7 - p.cap_b) * coalesce(w.rev_b / nullif(w.bk_b, 0), 0))
      from public.route_weeks w
     where w.route_id = p.route_id and w.week = game.week_of(p_day);
    update pg_temp._prod set pax_e = coalesce(pax_e, 0), pax_b = coalesce(pax_b, 0), dem_e = 0, dem_b = 0, dg = 0,
                             refund = coalesce(refund, 0);
    -- 0028: a route with every flight cancelled today refunds all of today's travellers
    insert into pg_temp._cxl (airline_id, refund)
    select x.airline_id,
           2 * (coalesce(w.flown_e, 0) / 7 * coalesce(w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0), 0)
              + coalesce(w.flown_b, 0) / 7 * coalesce(w.rev_b / nullif(w.bk_b, 0), 0))
      from (select distinct route_id, airline_id from pg_temp._rot) x
      join public.route_weeks w on w.route_id = x.route_id and w.week = game.week_of(p_day)
     where not exists (select 1 from pg_temp._prod p where p.route_id = x.route_id);
  else
    -- U = a - b x fare / reference + c x ln(1 + flights) + d x comfort x sqrt(block hours) + e x (brand - 50) / 50
    -- Nested logit: the airlines form one group against the option of not flying.
    -- x = exp(U / lambda); with S the sum of x on the market, P(fly) = S^lambda / (1 + S^lambda), and an airline's share of fliers is x / S.
    update pg_temp._prod set
      xb_e = case when cap_e > 0 then exp(((g.seg_biz_a - g.seg_biz_price * (fare_e / ref + ad_b) + g.seg_biz_freq * ln(1 + f)
               + g.seg_biz_comfort * comf_e * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xb_b = case when cap_b > 0 then exp(((g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * fare_b / (ref * g.biz_fare_mult) + g.seg_biz_freq * ln(1 + f_b)
               + g.seg_biz_comfort * comf_b * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xl   = case when cap_e > 0 then exp(((g.seg_lei_a - g.seg_lei_price * (fare_e / ref + ad_l) + g.seg_lei_freq * ln(1 + f)
               + g.seg_lei_comfort * comf_e * sqrt(block_h) + g.seg_lei_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xu   = case when cap_e > 0 then exp(((g.seg_bud_a - g.seg_bud_price * (fare_e / ref + ad_u) + g.seg_bud_freq * ln(1 + f)
               + g.seg_bud_comfort * comf_e * sqrt(block_h) + g.seg_bud_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end;

    update pg_temp._prod p
       set d_be = p.n_biz * p.xb_e * s.kb, d_bb = p.n_biz * p.xb_b * s.kb, d_l = p.n_lei * p.xl * s.kl, d_u = p.n_bud * p.xu * s.ku
      from (select route_id, game.nest_k(sum(xb_e + xb_b) over mkt, g.nest_lambda) as kb,
                   game.nest_k(sum(xl) over mkt, g.nest_lambda) as kl, game.nest_k(sum(xu) over mkt, g.nest_lambda) as ku
              from pg_temp._prod window mkt as (partition by a, b)) s
     where s.route_id = p.route_id;

    -- Business cabin. When it is full, part of the overflow takes economy on the same airline; the rest is spilled.
    -- Spilled travellers try airlines with seats left in the same cabin, in proportion to how attractive they are:
    -- a share spill_recapture x P(fly | airlines with seats) / P(fly | all airlines) finds a seat.
    update pg_temp._prod p
       set dem_b = p.d_bb, dg = g.biz_downgrade_share * greatest(p.d_bb - p.cap_b, 0),
           pax_b = least(p.d_bb, p.cap_b)
                   + case when p.cap_b > p.d_bb and s.sf > 0
                          then least(p.cap_b - p.d_bb, s.r * s.sp * p.xb_b / s.sf) else 0 end
      from (select route_id, sp, sf,
                   g.spill_recapture * least(1, game.nest_p(sf, g.nest_lambda) / nullif(game.nest_p(st, g.nest_lambda), 0)) as r
              from (select route_id,
                           sum((1 - g.biz_downgrade_share) * greatest(d_bb - cap_b, 0)) over mkt as sp,
                           sum(case when cap_b > d_bb then xb_b else 0 end) over mkt as sf,
                           sum(xb_e + xb_b) over mkt as st
                      from pg_temp._prod window mkt as (partition by a, b)) z) s
     where s.route_id = p.route_id;

    -- Economy cabin, with the business travellers who moved down.
    update pg_temp._prod set dem_e = d_be + dg + d_l + d_u;
    update pg_temp._prod p
       set pax_e = least(p.dem_e, p.cap_e)
                   + case when p.cap_e > p.dem_e then least(p.cap_e - p.dem_e,
                            coalesce(s.rb * s.spb * p.xb_e / nullif(s.sfb, 0), 0)
                          + coalesce(s.rl * s.spl * p.xl / nullif(s.sfl, 0), 0)
                          + coalesce(s.ru * s.spu * p.xu / nullif(s.sfu, 0), 0)) else 0 end
      from (select route_id, spb, spl, spu, sfb, sfl, sfu,
                   g.spill_recapture * least(1, game.nest_p(sfb, g.nest_lambda) / nullif(game.nest_p(stb, g.nest_lambda), 0)) as rb,
                   g.spill_recapture * least(1, game.nest_p(sfl, g.nest_lambda) / nullif(game.nest_p(stl, g.nest_lambda), 0)) as rl,
                   g.spill_recapture * least(1, game.nest_p(sfu, g.nest_lambda) / nullif(game.nest_p(stu, g.nest_lambda), 0)) as ru
              from (select route_id,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * (d_be + dg) / dem_e else 0 end) over mkt as spb,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * d_l / dem_e else 0 end) over mkt as spl,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * d_u / dem_e else 0 end) over mkt as spu,
                           sum(case when cap_e > dem_e then xb_e else 0 end) over mkt as sfb,
                           sum(case when cap_e > dem_e then xl else 0 end) over mkt as sfl,
                           sum(case when cap_e > dem_e then xu else 0 end) over mkt as sfu,
                           sum(xb_e + xb_b) over mkt as stb, sum(xl) over mkt as stl, sum(xu) over mkt as stu
                      from pg_temp._prod window mkt as (partition by a, b)) z) s
     where s.route_id = p.route_id;
  end if;

  update pg_temp._prod
     set spill = greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) - dg,
         pe = round(2 * pax_e), pb = round(2 * pax_b), rev = round(2 * pax_e) * fare_e + round(2 * pax_b) * fare_b,
         anc = round(2 * pax_e) * ref * an_y + round(2 * pax_b) * fare_b * g.anc_biz_share,
         anc_cost = round(2 * pax_e) * ref * an_c;

  -- 0026: a sales team abroad costs a share of an international route's revenue
  update pg_temp._prod p set sales_x = p.rev * po.sales_cost_share
    from public.route_plans rp join public.pos_options po on po.key = rp.sell_where, public.markets m
   where rw.selling and rp.route_id = p.route_id and m.a = p.a and m.b = p.b and m.intl and po.sales_cost_share > 0;

  if rw.selling then   -- travellers turned away while the week was on sale, a seventh a day
    update pg_temp._prod p set spill = coalesce(w.spill, 0) / 7
      from public.route_weeks w where w.route_id = p.route_id and w.week = game.week_of(p_day);
  end if;

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is, per movement scaled by the
  -- aircraft's size; a world scaled down in demand has proportionally fewer slots.
  with mv as (
    select z.iata, sum(z.m) as moves
      from (select a as iata, 2 * f as m from pg_temp._rot where flown
            union all select b, 2 * f from pg_temp._rot where flown) z
     group by z.iata),
  sp as (
    select ap.iata, g.slot_base_inr / power(1 - least(g.slot_util_cap, mv.moves / (ap.slot_cap * rw.slot_scale * rw.demand_scale)), 2) as price
      from mv join public.airports ap on ap.iata = mv.iata
     where ap.slot_cap is not null)
  update pg_temp._rot x set
    fuel_kg = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * o.fuel_mult,
    c_crew = case when x.wet then 0 else
               2 * x.f * (x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) * o.hour_mult + o.allowance) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * o.rate * (1 + o.age_k * x.age_y) * o.hour_mult * o.fx end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0)) * t.ref_seats / g.slot_ref_seats   -- 0016: by aircraft size
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  join pg_temp._ops o on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id and o.airline_id = x.airline_id;
  -- fuel at this week's hedged price (0023): the hedged share at its locked price, the rest at today's
  update pg_temp._rot x set c_fuel = x.fuel_kg * (o.h_share * o.h_price + (1 - o.h_share) * rw.fuel_inr_kg)
    from pg_temp._ops o where x.flown and o.airline_id = x.airline_id;

  -- Step 6: results
  -- What holding each aircraft costs a day (migration 0017): rent, wet-lease hours, or depreciation and loan interest for
  -- an owned one, plus its cabin crew's base pay (and the flat pilot cost in a world without pilots). Pilot salaries, head
  -- office and marketing are not split by aircraft.
  insert into pg_temp._acx (aircraft_id, airline_id, fixed, bh)
  select ac.id, tm.airline_id,
         case tm.holding
           when 'lease' then tm.lease_usd_month * coalesce(ox.fx, rw.fx_inr_usd) / 30.33
           when 'wet' then tm.wet_usd_bh * coalesce(ox.fx, rw.fx_inr_usd) * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
           else tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364
                + case when tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 * coalesce(ox.fx, rw.fx_inr_usd) else 0 end
                + tm.loan_inr * game.wparam(p_world, 'loan_rate_inr_year') / 364 end
         + case when tm.holding = 'wet' then 0 else
             case when rw.pilots then 0 else t.pilot_fixed_inr_day end
             + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end,
         coalesce(u.bh, 0)
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u on u.aircraft_id = ac.id
    left join pg_temp._ops ox on ox.airline_id = tm.airline_id
   where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and exists (select 1 from public.airlines a0 where a0.id = ac.airline_id and a0.first_flight_day <= p_day);

  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr, aircraft_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.sales_x),
         round(c.acx)
    from pg_temp._prod p
    join (select x.route_id, sum(x.c_fuel + x.c_crew + x.c_maint + x.c_airport + x.c_slots) as var,
                 -- each aircraft's holding cost, shared across its routes by the hours it flew on each
                 sum(a.fixed * 2 * x.f * x.block_h / nullif(a.bh, 0)) as acx
            from pg_temp._rot x join pg_temp._acx a on a.aircraft_id = x.aircraft_id
           where x.flown group by x.route_id) c on c.route_id = p.route_id;

  -- Each aircraft's day (migration 0017): its share of its routes' revenue and of their sales and service costs (by seats
  -- it flew in each cabin), its own flying costs, and its holding cost. Idle and grounded aircraft get a row too.
  insert into public.aircraft_daily (aircraft_id, game_day, airline_id, flights, block_h, seats, pax, revenue_inr, flying_cost_inr, aircraft_cost_inr)
  select a.aircraft_id, p_day, a.airline_id, coalesce(z.flights, 0), round(a.bh, 2), coalesce(z.seats, 0), round(coalesce(z.pax, 0)),
         round(coalesce(z.rev, 0)), round(coalesce(z.cost, 0)), round(a.fixed)
    from pg_temp._acx a
    left join (select x.aircraft_id, sum(2 * x.f) as flights, round(sum(2 * x.f * (x.seats_e + x.seats_b))) as seats,
                      sum(s.e * p.pe + s.b * p.pb) as pax,
                      sum(s.e * (p.pe * p.fare_e + p.pe * p.ref * p.an_y) + s.b * p.pb * p.fare_b * (1 + g.anc_biz_share)) as rev,
                      sum(x.c_fuel + x.c_crew + x.c_maint + x.c_airport + x.c_slots
                          + s.all_ * (g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.sales_x)) as cost
                 from pg_temp._rot x
                 join pg_temp._prod p on p.route_id = x.route_id
                 cross join lateral (select coalesce(x.f * x.seats_e / nullif(p.cap_e, 0), 0) as e,
                                            coalesce(x.f * x.seats_b / nullif(p.cap_b, 0), 0) as b,
                                            coalesce(x.f * (x.seats_e + x.seats_b) / nullif(p.cap_e + p.cap_b, 0), 0) as all_) s
                where x.flown group by x.aircraft_id) z on z.aircraft_id = a.aircraft_id
   where a.airline_id is not null;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid, refunds_inr,
    fuel_kg, hedge_inr, groundings, usd_cost_usd, usd_cost_inr, usd_hedge_inr, fx_effect_inr)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0) + coalesce(ox.fixed_day, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost + pr.sales_x, 0)), al.marketing_inr_day,
         -- 0029: head office grows with the fleet up to overhead_full_fleet aircraft, from overhead_min_share of the full cost
         round(g.overhead_fixed_inr_day * greatest(g.overhead_min_share, least(1, coalesce(fl.n, 0) / g.overhead_full_fleet))
               + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0)), round(coalesce(pr.refund, 0)),
         round(coalesce(rc.kg, 0)), round(coalesce(rc.kg * rw.fuel_inr_kg - rc.fuel, 0)), coalesce(gr.n, 0),
         -- 0026: dollar-linked costs (rent, maintenance, dollar loan interest, depreciation), what the dollar hedge saved on the
         -- cash ones (repayments included), and what the rupee's move against the reference rate added
         round(coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0), 2),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)),
         round((coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.prin_usd, 0)) * rw.fx_inr_usd
               - (coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.prin_d, 0))),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)
               - (coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0)) * game.param('fx_ref_inr_usd'))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost, sum(refund) as refund, sum(sales_x) as sales_x
                 from (select airline_id, pe, pb, cap_e, cap_b, km, rev, anc, anc_cost, refund, sales_x from pg_temp._prod
                       union all select airline_id, 0, 0, 0, 0, 0, 0, 0, 0, refund, 0 from pg_temp._cxl) u
                group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(fuel_kg) as kg, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n, sum(ac.seats_econ + ac.seats_biz) as seats,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month / 30.33
                            when 'wet' then tm.wet_usd_bh * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent_usd,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month / 30.33
                            when 'wet' then tm.wet_usd_bh * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) * max(coalesce(ox.fx, rw.fx_inr_usd)) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * g.depreciation_year / 364 else 0 end) as depr_usd,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end) as int_usd,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd)) as int_d,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end) as prin_usd,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd)) as prin_d,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd))
                        + sum(case when tm.holding = 'owned' then tm.loan_inr * game.wparam(p_world, 'loan_rate_inr_year') / 364 else 0 end) as loan_int,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd))
                        + sum(case when tm.holding = 'owned' and tm.loan_inr > 0 then least(tm.loan_inr, tm.loan_pay_inr_day) else 0 end) as loan_prin,
                      sum(case when tm.holding = 'wet' then 0 else
                            case when rw.pilots then 0 else t.pilot_fixed_inr_day end
                            + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
                 left join pg_temp._ops ox on ox.airline_id = tm.airline_id
                where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
                group by tm.airline_id) fl on fl.airline_id = al.id
    left join (select ap.airline_id,   -- pilot salaries: market pay x the airline's pay level; foreign captains at their own rate
                      sum(pm.pay_index * ((ap.captains - ap.expats) * pf.pay_c_inr_day * pfin.pilot_pay
                                          + ap.expats * pf.pay_c_inr_day * game.param('pilot_expat_mult')
                                          + ap.fos * pf.pay_f_inr_day * pfin.pilot_pay)) as pay
                 from public.airline_pilots ap
                 join public.airline_finance pfin on pfin.airline_id = ap.airline_id
                 join public.pilot_families pf on pf.id = ap.family
                 join public.pilot_market pm on pm.world_id = p_world and pm.family = ap.family
                where rw.pilots
                group by ap.airline_id) sal on sal.airline_id = al.id
    left join (select airline_id, -sum(pnl_inr) as other from public.transactions where game_day = p_day group by airline_id) tx
           on tx.airline_id = al.id
    left join pg_temp._ops ox on ox.airline_id = al.id
    left join (select airline_id, count(*) as n from public.aircraft where world_id = p_world and grounded_day = p_day group by airline_id) gr
           on gr.airline_id = al.id
   where al.world_id = p_world and al.status = 'active' and al.first_flight_day <= p_day;

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + case when rw.selling then -d.refunds_inr else d.rev_ticket end + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  update public.aircraft_terms tm set loan_usd = tm.loan_usd - least(tm.loan_usd, tm.loan_pay_usd_day)
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_usd > 0;
  update public.aircraft_terms tm set loan_inr = tm.loan_inr - least(tm.loan_inr, tm.loan_pay_inr_day)   -- 0026: rupee loans
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_inr > 0;

  -- punctuality: tight schedules run late. Brand drifts toward a target built from punctuality,
  -- cancellations, cabin comfort and marketing per passenger.
  update public.airlines al set otp = round((1 - g.otp_smooth) * al.otp + g.otp_smooth * least(0.99, greatest(0, s.otp)), 4)
    from (select u.airline_id, sum(u.fl * (g.otp_base - g.otp_util_k * greatest(0, u.util - 0.85) / 0.15)) / sum(u.fl)
                 + coalesce(max(o.otp_d), 0) as otp
            from (select x.airline_id, x.aircraft_id, sum(2 * x.f) as fl,
                         sum(2 * x.f * (x.block_h + x.turn_min / 60)) / max(t.day_window_h) as util
                    from pg_temp._rot x join public.aircraft_types t on t.id = x.type_id
                   where x.flown group by x.airline_id, x.aircraft_id) u
            left join pg_temp._ops o on o.airline_id = u.airline_id
           group by u.airline_id) s
   where al.id = s.airline_id;

  update public.airlines al
     set brand = round(least(100, greatest(0, al.brand + g.brand_drift * (
           50 + coalesce((select o.brand_d from pg_temp._ops o where o.airline_id = al.id), 0)
              + g.brand_otp_k * (al.otp - g.brand_otp_ref)
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
  delete from public.aircraft_daily ad using public.airlines al
   where al.id = ad.airline_id and al.world_id = p_world and ad.game_day <= p_day - g.route_keep_days::int;
end $$;

-- bot_selling from 0027: computer-run airlines defend only markets they hold (0029)
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
         fight_pos = case when game.param('bot_fight_random') > 0 then power(random(), least(1, b.aggression * game.wparam(p_world, 'bot_aggression_mult')) * game.param('bot_fight_skew')) end
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.is_ai and al.status = 'active'
    join public.bot_airlines b on b.code = al.code
    join mv on mv.a = least(r.origin, r.dest) and mv.b = greatest(r.origin, r.dest)
   where pl.route_id = r.id and r.world_id = p_world and r.status = 'open' and pl.fight_until is null
     -- 0029: it defends only markets it holds: at least bot_defend_share of the market's seats this week
     and coalesce((select sum(w.seats_e + w.seats_b) from public.route_weeks w where w.route_id = r.id and w.week = v_w), 0)
         >= game.param('bot_defend_share')
            * coalesce((select sum(w2.seats_e + w2.seats_b) from public.route_weeks w2 join public.routes r2 on r2.id = w2.route_id
                         where r2.world_id = p_world and r2.status = 'open' and w2.week = v_w
                           and least(r2.origin, r2.dest) = mv.a and greatest(r2.origin, r2.dest) = mv.b), 0)
     and random() < least(1, b.aggression * game.wparam(p_world, 'bot_aggression_mult'));

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

-- bot_quarter from 0024: concentrate instead of thinning (0029)
create or replace function game.bot_quarter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; r record; v_n int := 0; v_min int := game.param('bot_min_weekly')::int;
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
    -- 0029: concentrate. A route losing more than bot_close_margin, or one a cut would leave below bot_keep_weekly round
    -- trips, closes outright (never one of the eight busiest domestic markets, never below bot_keep_routes routes); its
    -- aircraft go to the routes that earn, or back to the lessors (bot_balance). The rest of the losing routes are cut.
    if game.param('bot_concentrate') >= 1 then
      v_min := game.param('bot_keep_weekly')::int;
      for r in
        select s.route_id from pg_temp._bst s join public.routes rt on rt.id = s.route_id and rt.status = 'open'
         where s.days >= 21 and s.margin < game.param('bot_cut_margin')
           and (s.margin < game.param('bot_close_margin') or round(s.trips * (1 - game.param('bot_cut_share'))) < v_min)
           and (least(rt.origin, rt.dest), greatest(rt.origin, rt.dest)) not in
               (select m.a, m.b from public.markets m where not m.intl order by m.n_biz + m.n_lei + m.n_bud desc limit 8)
         order by s.margin
      loop
        exit when (select count(*) from public.routes o where o.airline_id = al.id and o.status = 'open') <= game.param('bot_keep_routes');
        perform game.bot_close(al.id, r.route_id, p_day);
        v_n := v_n + 1;
      end loop;
    end if;
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

