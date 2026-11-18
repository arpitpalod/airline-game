-- Bulk orders and leases, and extras (ancillaries) players choose and price (owner requests, 19 Nov 2026).
-- Adds tables, functions and game values, and redefines game.day_ops so extras replace the flat 8% ancillary share.
-- Defaults (every extra sold at its reference price) give the same revenue as the old 8% on a fare 1.2x the reference,
-- so the tuning in spec 14.3 holds for an airline that never touches its extras. Adds and updates only.

insert into public.game_params (key, num, note) values
('bulk_max', 10, 'most aircraft in one bulk order or one bulk lease'),
('anc_k', 0.6, 'how fast take-up of a paid extra falls with its price: share x exp(-k x (price multiple - 1))'),
('anc_mult_min', 0.25, 'lowest price for an extra, as a multiple of its reference price'),
('anc_mult_max', 3, 'highest price for an extra, as a multiple of its reference price'),
('anc_biz_share', 0.08, 'extras revenue from a business-cabin passenger, as a share of the business fare')
on conflict (key) do update set num = excluded.num, note = excluded.note;

-- ---------- Bulk orders and leases ----------

-- Several new aircraft of one type and cabin in one go. Each takes the next delivery slot, so later ones may arrive
-- later. All or nothing: if one cannot be ordered (cash, fleet limit), none is.
create or replace function public.order_aircraft_bulk(p_airline uuid, p_type text, p_base text, p_count int, p_biz_rows int,
                                                      p_biz_pitch int, p_econ_pitch int, p_pay text default 'cash')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := '[]'::jsonb;
begin
  if p_count is null or p_count < 1 or p_count > game.param('bulk_max') then
    raise exception 'Order between 1 and % aircraft at a time', game.param('bulk_max')::int;
  end if;
  for i in 1..p_count loop
    v := v || jsonb_build_array(public.order_aircraft(p_airline, p_type, p_base, p_biz_rows, p_biz_pitch, p_econ_pitch, p_pay));
  end loop;
  return v;
end $$;

-- Several aircraft from the lessor pool in one go, all or nothing. The pool limit (pool_lease_max_qtr in any 91 days) applies.
create or replace function public.lease_aircraft_bulk(p_airline uuid, p_aircraft uuid[], p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype; v jsonb := '[]'::jsonb; v_id uuid; v_n int; v_had int;
  v_max int := game.param('pool_lease_max_qtr')::int;
begin
  rw := game.actor(p_airline);
  v_n := coalesce(array_length(p_aircraft, 1), 0);
  if v_n < 1 or v_n > game.param('bulk_max') then
    raise exception 'Lease between 1 and % aircraft at a time', game.param('bulk_max')::int;
  end if;
  select count(*) into v_had from public.transactions
   where airline_id = p_airline and kind = 'lease' and game_day > rw.game_day + 1 - 91;
  if v_had + v_n > v_max then
    raise exception 'Lessors place at most % aircraft with one airline in a quarter: you can lease % more now.', v_max, greatest(0, v_max - v_had);
  end if;
  foreach v_id in array p_aircraft loop
    v := v || jsonb_build_array(public.lease_aircraft(p_airline, v_id, p_base));
  end loop;
  return v;
end $$;

-- ---------- Extras ----------

create table public.ancillary_products (
  id         text primary key,
  name       text not null,
  sort       int not null,
  ref_share  numeric not null,   -- reference price, as a share of the route's reference economy fare (G)
  takeup     numeric not null,   -- share of economy passengers who buy it at the reference price (G)
  inc_use    numeric not null,   -- share who use it when it is included free (G)
  cost_share numeric not null,   -- cost to the airline per use when included, as a share of the reference fare (G)
  w_biz      numeric not null,   -- share of each segment who count its price when choosing a flight (G)
  w_lei      numeric not null,
  w_bud      numeric not null
);

insert into public.ancillary_products values
('bag',      'Checked bag',                     1, 0.17, 0.35, 0.55, 0.030, 0.30, 0.50, 0.40),
('seat',     'Seat choice',                     2, 0.06, 0.30, 0.00, 0.000, 0.50, 0.30, 0.10),
('meal',     'Meal on board',                   3, 0.06, 0.22, 0.85, 0.040, 0.40, 0.30, 0.10),
('priority', 'Priority check-in and boarding',  4, 0.07, 0.07, 0.15, 0.005, 0.30, 0.05, 0.02)
on conflict (id) do nothing;

-- One row per airline and extra it has changed; no row means sold at the reference price. Public, like fares.
create table public.airline_extras (
  airline_id uuid not null references public.airlines on delete cascade,
  product_id text not null references public.ancillary_products,
  included   boolean not null default false,
  price_mult numeric not null default 1,
  primary key (airline_id, product_id)
);

alter table public.ancillary_products enable row level security;
alter table public.airline_extras enable row level security;
grant select on public.ancillary_products, public.airline_extras to authenticated;
create policy read_all on public.ancillary_products for select to authenticated using (true);
create policy read_all on public.airline_extras for select to authenticated using (true);

-- An airline's extras for its whole network, in reference fares per economy passenger:
--   d_biz, d_lei, d_bud: change in the fare a segment perceives (price paid above or below the reference price,
--                        weighted by how many in the segment want the extra; included extras count as a saving)
--   yield: extras revenue; cost: cost of extras included free.
create or replace function game.anc_terms(p_airline uuid, out d_biz numeric, out d_lei numeric, out d_bud numeric,
                                          out yield numeric, out cost numeric)
language sql stable set search_path = '' as $$
  select coalesce(sum(case when s.inc then -p.w_biz * p.ref_share else p.w_biz * p.ref_share * (s.m - 1) end), 0),
         coalesce(sum(case when s.inc then -p.w_lei * p.ref_share else p.w_lei * p.ref_share * (s.m - 1) end), 0),
         coalesce(sum(case when s.inc then -p.w_bud * p.ref_share else p.w_bud * p.ref_share * (s.m - 1) end), 0),
         coalesce(sum(case when s.inc then 0
                           else p.ref_share * s.m * least(1, p.takeup * exp(-game.param('anc_k') * (s.m - 1))) end), 0),
         coalesce(sum(case when s.inc then p.cost_share * p.inc_use else 0 end), 0)
    from public.ancillary_products p
    left join public.airline_extras e on e.product_id = p.id and e.airline_id = p_airline
    cross join lateral (select coalesce(e.included, false) as inc, coalesce(e.price_mult, 1) as m) s
$$;

-- Set extras for the whole network. p_settings: {"bag": {"included": false, "mult": 1.2}, "meal": {"included": true}, ...}
-- Extras not named keep their setting. Counts from the next game day.
create or replace function public.set_extras(p_airline uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text; v jsonb; v_m numeric; v_inc boolean;
begin
  perform game.actor(p_airline);
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then raise exception 'Send extras as an object'; end if;
  for k, v in select * from jsonb_each(p_settings) loop
    if not exists (select 1 from public.ancillary_products where id = k) then raise exception 'Unknown extra: %', k; end if;
    v_inc := coalesce((v ->> 'included')::boolean, false);
    v_m := coalesce((v ->> 'mult')::numeric, 1);
    if v_m < game.param('anc_mult_min') or v_m > game.param('anc_mult_max') then
      raise exception 'Price extras between % and % times the reference price', game.param('anc_mult_min'), game.param('anc_mult_max');
    end if;
    insert into public.airline_extras (airline_id, product_id, included, price_mult)
    values (p_airline, k, v_inc, round(v_m, 2))
    on conflict (airline_id, product_id) do update set included = excluded.included, price_mult = excluded.price_mult;
  end loop;
  return (select jsonb_object_agg(product_id, jsonb_build_object('included', included, 'mult', price_mult))
            from public.airline_extras where airline_id = p_airline);
end $$;

-- ---------- The daily engine: extras replace the flat ancillary share ----------
-- Changes from 0007: each airline's extras shift the fare its economy travellers perceive (ad_b, ad_l, ad_u),
-- extras revenue is per economy passenger (an_y) plus anc_biz_share of business fares, and extras included free
-- cost money per passenger (an_c, booked with distribution and service).

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
    overhead_aircraft_inr_day numeric, overhead_seat_inr_day numeric, base_fixed_inr_day numeric, interest_year numeric, otp_base numeric,
    otp_util_k numeric, otp_smooth numeric, brand_drift numeric, brand_otp_ref numeric, brand_otp_k numeric, brand_cancel_k numeric,
    brand_comfort_ref numeric, brand_comfort_k numeric, brand_mkt_max numeric, brand_mkt_inr_pax numeric,
    brand_mkt_min_pax numeric, route_keep_days numeric, nest_lambda numeric, biz_downgrade_share numeric, seg_biz_cabin_a numeric,
    loan_rate_year numeric, anc_biz_share numeric);

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
    xb_e numeric, xb_b numeric, xl numeric, xu numeric,     -- exp(utility / lambda) by segment and cabin
    d_be numeric, d_bb numeric, d_l numeric, d_u numeric,   -- demand by segment: business in economy, in business, leisure, budget
    dg numeric,                                             -- business travellers moved down to economy
    dem_e numeric, dem_b numeric, pax_e numeric, pax_b numeric, spill numeric,
    pe numeric, pb numeric, rev numeric,                     -- both directions
    ad_b numeric, ad_l numeric, ad_u numeric,               -- extras: change in perceived fare by segment, in reference fares
    an_y numeric, an_c numeric, anc numeric, anc_cost numeric  -- extras: revenue and cost per economy passenger (reference fares), totals
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

  update pg_temp._prod
     set spill = greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) - dg,
         pe = round(2 * pax_e), pb = round(2 * pax_b), rev = round(2 * pax_e) * fare_e + round(2 * pax_b) * fare_b,
         anc = round(2 * pax_e) * ref * an_y + round(2 * pax_b) * fare_b * g.anc_biz_share,
         anc_cost = round(2 * pax_e) * ref * an_c;

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is;
  -- a world scaled down in demand has proportionally fewer slots.
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
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost)
    from pg_temp._prod p
    join (select route_id, sum(c_fuel + c_crew + c_maint + c_airport + c_slots) as var
            from pg_temp._rot where flown group by route_id) c on c.route_id = p.route_id;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0)), round(coalesce(rc.maint, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n, sum(ac.seats_econ + ac.seats_biz) as seats,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
                            when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then tm.loan_usd * g.loan_rate_year / 364 * rw.fx_inr_usd else 0 end) as loan_int,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then least(tm.loan_usd, tm.loan_pay_usd_day) * rw.fx_inr_usd else 0 end) as loan_prin,
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
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  update public.aircraft_terms tm set loan_usd = tm.loan_usd - least(tm.loan_usd, tm.loan_pay_usd_day)
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_usd > 0;

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

revoke all on function game.anc_terms(uuid), game.day_ops(uuid, int) from public, anon, authenticated;
revoke all on function public.order_aircraft_bulk(uuid, text, text, int, int, int, int, text), public.lease_aircraft_bulk(uuid, uuid[], text),
  public.set_extras(uuid, jsonb) from public, anon;
grant execute on function public.order_aircraft_bulk(uuid, text, text, int, int, int, int, text), public.lease_aircraft_bulk(uuid, uuid[], text),
  public.set_extras(uuid, jsonb) to authenticated, service_role;
