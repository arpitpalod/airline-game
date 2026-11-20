-- Migration 0022: fixes from the first playtest (spec section 14.16).
-- 1. International demand grows faster than domestic: 12% a game year against 7% (G).
-- 2. Festivals and events (G, table demand_events): Holi, Eid, Diwali, business summits and others raise or lower
--    demand by traveller type on the markets they touch, for the days they last, every game year. Selling ahead sees them.
-- 3. Routes can be opened and closed, and aircraft put on them, while a world is still in setup.
-- 4. Starting a world runs its first game week at once (G), so rivals and seats on sale appear straight away.

insert into public.game_params (key, num, note) values
('growth_year_intl', 0.12, 'international market growth a game year'),
('start_first_week', 1, 'starting a world runs its first game week at once (1) or leaves it to the scheduler (0)')
on conflict (key) do update set num = excluded.num, note = excluded.note;
update public.game_params set note = 'domestic market growth a game year' where key = 'growth_year';

-- Festivals and events (G). start_doy: day of the game year it starts (1 = 1 January); days: how long it lasts.
-- It touches a market when every condition set matches: domestic (true: domestic markets only; false: international
-- only), airports (either end is one of them), regions (either end is in one of them). biz, lei, bud multiply the demand
-- of business, leisure and budget travellers on each day it runs.
create table public.demand_events (
  id        serial primary key,
  name      text not null,
  start_doy int not null check (start_doy between 1 and 364),
  days      int not null check (days between 1 and 60),
  domestic  boolean,
  airports  text[],
  regions   text[],
  biz       numeric not null default 1 check (biz > 0),
  lei       numeric not null default 1 check (lei > 0),
  bud       numeric not null default 1 check (bud > 0),
  note      text not null default ''
);
insert into public.demand_events (name, start_doy, days, domestic, airports, regions, biz, lei, bud, note) values
('Sankranti and Pongal',     13,  5, true,  null,              '{S,TN}',      0.90, 1.30, 1.40, 'Families travel home across the South'),
('Holi',                     69,  5, true,  null,              null,          0.90, 1.30, 1.30, 'More family and leisure travellers on domestic routes'),
('Mumbai fintech summit',   112,  3, null,  '{BOM}',           null,          1.45, 1.00, 1.00, '45% more business travellers to and from Mumbai'),
('Eid',                     134,  7, false, null,              '{GULF}',      1.00, 1.50, 1.50, 'Busy Gulf routes, mostly families'),
('Onam',                    238,  6, null,  null,              '{KL}',        1.00, 1.40, 1.50, 'Keralites fly home from across India and the Gulf'),
('Durga Puja',              288,  6, true,  '{CCU}',           null,          0.90, 1.40, 1.50, 'Kolkata fills with families coming home'),
('Diwali',                  303,  7, true,  null,              null,          0.80, 1.40, 1.50, 'The busiest week of the year for families; offices close'),
('Delhi trade fair',        318, 14, null,  '{DEL}',           null,          1.20, 1.00, 1.00, '20% more business travellers to and from Delhi'),
('Bengaluru tech summit',   322,  3, null,  '{BLR}',           null,          1.40, 1.00, 1.00, '40% more business travellers to and from Bengaluru'),
('Christmas and New Year',  354, 14, null,  '{GOI,GOX}',       null,          0.80, 1.60, 1.40, 'Goa fills up; few business travellers'),
('Year-end holidays abroad', 354, 14, false, null,             '{SEA,EUR}',   0.85, 1.35, 1.20, 'Indians holiday in South-East Asia and Europe');

alter table public.demand_events enable row level security;
revoke all on public.demand_events from anon, authenticated;
grant select on public.demand_events to authenticated;
create policy read_all on public.demand_events for select to authenticated using (true);

-- Selling ahead (sell_week, from 0020): international markets grow at their own rate, and festivals and events change
-- each flight week's demand.

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
  select x.route_id, x.week, x.week - v_w as n, x.airline_id, c.a, c.b, m.intl, m.ref_fare::float8 as ref, p.strategy,
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
    pe = round(z.ref * (z.em + (z.lm - z.em) * c.ramp) * z.adj_e / 10) * 10,
    pb = round(z.ref * g.biz_fare_mult * (z.bem + (z.blm - z.bem) * c.ramp) * z.adj_b / 10) * 10
    from pg_temp._curve c where c.n = z.n;
  -- follow the market: the rivals' average for the same flight week
  update pg_temp._sell z set
    pe = round(least(z.mx * z.ref, greatest(z.mn * z.ref, q.e * (1 + z.gap))) / 10) * 10,
    pb = coalesce(round(least(z.mx * z.ref * g.biz_fare_mult, greatest(z.mn * z.ref * g.biz_fare_mult, q.b * (1 + z.gap))) / 10) * 10, z.pb)
    from (select z1.route_id, z1.week, avg(z2.pe) as e, avg(z2.pb) filter (where z2.sb > 0) as b
            from pg_temp._sell z1 join pg_temp._sell z2 on z2.a = z1.a and z2.b = z1.b and z2.week = z1.week and z2.airline_id <> z1.airline_id
           where z1.strategy = 'follow' and z2.se > 0
           group by z1.route_id, z1.week) q
   where z.route_id = q.route_id and z.week = q.week;

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

revoke all on function game.sell_week(uuid, int) from public, anon, authenticated;

-- Route studies: next quarter's demand grows at the international rate on international markets.
create or replace function public.route_study(p_airline uuid, p_a text, p_b text, p_depth text default 'quick') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype; m public.markets%rowtype; s public.route_studies%rowtype;
  v_day int; v_w numeric; v_cost numeric; v_e numeric;
  v_fly numeric; v_turn numeric; v_seats numeric; v_days int; v_grow numeric; v_untap numeric; v_block numeric;
  v_sb numeric; v_sl numeric; v_su numeric;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  if p_depth is null or p_depth not in ('quick', 'full') then raise exception 'A study is quick or full'; end if;
  select * into m from public.markets where a = least(upper(p_a), upper(p_b)) and b = greatest(upper(p_a), upper(p_b));
  if not found then raise exception 'There is no market between % and %', p_a, p_b; end if;
  v_cost := game.param('study_' || p_depth || '_inr');
  v_w := game.param('study_' || p_depth || '_width');
  perform game.book(p_airline, v_day, -v_cost, 'study',
                    format('%s route study, %s-%s', initcap(p_depth), m.a, m.b), -v_cost);

  select sum(d.pax_econ + d.pax_biz), sum(d.spill), sum(d.seats_econ + d.seats_biz), count(distinct d.game_day)
    into v_fly, v_turn, v_seats, v_days
    from public.routes r join public.route_daily d on d.route_id = r.id and d.game_day > rw.game_day - 28
   where r.world_id = rw.id and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b;

  s.airline_id := p_airline; s.world_id := rw.id; s.a := m.a; s.b := m.b; s.game_day := v_day; s.depth := p_depth;
  select count(distinct r.airline_id) into s.carriers from public.routes r
   where r.world_id = rw.id and r.status = 'open' and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b
     and exists (select 1 from public.rotations ro where ro.route_id = r.id);

  -- each figure gets its own error, then the range around it
  if coalesce(v_fly, 0) > 0 then
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.flying_lo := round(v_fly / v_days / 2 * v_e * (1 - v_w)); s.flying_hi := round(v_fly / v_days / 2 * v_e * (1 + v_w));
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.turned_lo := round(v_turn / v_days / 2 * v_e * (1 - v_w)); s.turned_hi := round(v_turn / v_days / 2 * v_e * (1 + v_w));
    v_e := greatest(0.3, 1 + v_w / 4 * game.rand_normal());
    s.lf_lo := round(least(1, v_fly / v_seats * v_e * (1 - v_w / 2)), 3); s.lf_hi := round(least(1, v_fly / v_seats * v_e * (1 + v_w / 2)), 3);
  else
    -- one airline, two round trips a day, reference fare, standard A320neo cabin: P(fly) = e^U / (1 + e^U) per segment
    v_grow := power(1 + game.param(case when m.intl then 'growth_year_intl' else 'growth_year' end), (v_day - 1) / 364.0) * rw.demand_scale;
    v_block := m.km / 830.0 + 0.7;
    select f.biz, f.lei, f.bud into v_sb, v_sl, v_su from public.season_factors f
     where f.month = ((game.param('season_start_month')::int - 1 + (((v_day - 1) % 364) * 12) / 364) % 12) + 1;
    select sum(n * exp(u) / (1 + exp(u))) into v_untap from (values
      (m.n_biz * v_sb, game.param('seg_biz_a') - game.param('seg_biz_price') + game.param('seg_biz_freq') * ln(3)
                       + game.param('seg_biz_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_lei * v_sl, game.param('seg_lei_a') - game.param('seg_lei_price') + game.param('seg_lei_freq') * ln(3)
                       + game.param('seg_lei_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_bud * v_su, game.param('seg_bud_a') - game.param('seg_bud_price') + game.param('seg_bud_freq') * ln(3)
                       + game.param('seg_bud_comfort') * (1 / 6.0) * sqrt(v_block))) as x(n, u);
    v_untap := v_untap * v_grow;
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.untapped_lo := round(v_untap * v_e * (1 - v_w)); s.untapped_hi := round(v_untap * v_e * (1 + v_w));
  end if;

  if p_depth = 'full' then
    s.biz_share := round(m.n_biz / (m.n_biz + m.n_lei + m.n_bud), 2);
    s.lei_share := round(m.n_lei / (m.n_biz + m.n_lei + m.n_bud), 2);
    s.bud_share := round(1 - s.biz_share - s.lei_share, 2);
    s.next_qtr := round(game.season_mix(v_day + 91, m.n_biz, m.n_lei, m.n_bud) / game.season_mix(v_day, m.n_biz, m.n_lei, m.n_bud)
                        * power(1 + game.param(case when m.intl then 'growth_year_intl' else 'growth_year' end), 91 / 364.0), 2);
  end if;

  insert into public.route_studies (airline_id, world_id, a, b, game_day, depth, carriers, flying_lo, flying_hi, turned_lo, turned_hi,
                                    lf_lo, lf_hi, untapped_lo, untapped_hi, biz_share, lei_share, bud_share, next_qtr)
  values (s.airline_id, s.world_id, s.a, s.b, s.game_day, s.depth, s.carriers, s.flying_lo, s.flying_hi, s.turned_lo, s.turned_hi,
          s.lf_lo, s.lf_hi, s.untapped_lo, s.untapped_hi, s.biz_share, s.lei_share, s.bud_share, s.next_qtr)
  returning id into s.id;
  return to_jsonb(s);
end $$;

-- Planning before the world starts: routes can be opened and closed, and aircraft put on them, while the world is in setup.
create or replace function public.open_route(p_airline uuid, p_origin text, p_dest text,
                                             p_fare_econ int default null, p_fare_biz int default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rk public.markets%rowtype;
  f record;
  v_day int; v_o text := upper(trim(p_origin)); v_d text := upper(trim(p_dest)); v_id uuid;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if; v_day := rw.game_day + 1;
  if not exists (select 1 from public.bases where airline_id = p_airline and iata = v_o) then
    raise exception 'Routes must start at one of your bases';
  end if;
  select * into rk from public.markets where a = least(v_o, v_d) and b = greatest(v_o, v_d);
  if not found then raise exception 'There is no market between % and %', v_o, v_d; end if;
  if exists (select 1 from public.airports where iata in (v_o, v_d) and opens_day > v_day) then
    raise exception 'That airport has not opened yet';
  end if;
  select * into f from game.check_fares(rk.ref_fare, p_fare_econ, p_fare_biz);
  select id into v_id from public.routes
   where airline_id = p_airline and least(origin, dest) = rk.a and greatest(origin, dest) = rk.b;
  if found then
    update public.routes set status = 'open', origin = v_o, dest = v_d, fare_econ = f.econ, fare_biz = f.biz, opened_day = v_day
     where id = v_id and status = 'closed';
    if not found then raise exception 'You already fly this route'; end if;
  else
    insert into public.routes (world_id, airline_id, origin, dest, fare_econ, fare_biz, opened_day)
    values (rw.id, p_airline, v_o, v_d, f.econ, f.biz, v_day) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.close_route(p_airline uuid, p_route uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  update public.routes set status = 'closed' where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  delete from public.rotations where route_id = p_route;
end $$;

create or replace function public.set_rotation(p_airline uuid, p_aircraft uuid, p_route uuid, p_weekly_trips int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rr public.routes%rowtype;
  l record;
  v_issue text;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('delivering', 'active', 'grounded', 'refit') then
    raise exception 'That aircraft is not in your fleet';
  end if;
  select * into rr from public.routes where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  if coalesce(p_weekly_trips, 0) = 0 then
    delete from public.rotations where aircraft_id = rc.id and route_id = rr.id;
    return jsonb_build_object('weekly_trips', 0);
  end if;
  if p_weekly_trips not between 1 and 84 then raise exception 'Round trips a week must be between 0 and 84'; end if;
  if rc.base_iata is null or rc.base_iata not in (rr.origin, rr.dest) then
    raise exception 'This aircraft is based at %, which is not on this route', rc.base_iata;
  end if;
  if (select min(runway_class) from public.airports where iata in (rr.origin, rr.dest))
     < (select runway_class from public.aircraft_types where id = rc.type_id) then
    raise exception 'A runway on this route is too short for this aircraft';
  end if;
  select * into l from public.layout_calc(rc.type_id, rc.biz_rows, rc.biz_pitch, rc.econ_pitch, rw.crew_rule);
  v_issue := game.schedule_issue(rc.id, l.range_km, l.min_turn_min, rr.id, p_weekly_trips);
  if v_issue is not null then raise exception '%', v_issue; end if;
  insert into public.rotations (aircraft_id, route_id, weekly_trips) values (rc.id, rr.id, p_weekly_trips)
    on conflict (aircraft_id, route_id) do update set weekly_trips = excluded.weekly_trips;
  return jsonb_build_object('weekly_trips', p_weekly_trips);
end $$;

-- Starting a world runs its first game week at once: the clock is set to the end of week 1 and the week is played, so the
-- computer-run airlines, seats on sale and prices appear straight away. If the week fails, the scheduler plays it later.
create or replace function public.admin_start_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w public.worlds%rowtype;
  i int;
begin
  perform game.require_admin();
  perform game.start_world(p_world);
  if coalesce(game.param('start_first_week'), 0) >= 1 then
    select * into w from public.worlds where id = p_world;
    update public.worlds set started_at = now() - make_interval(secs => game.clock_seconds(w, 7)) where id = p_world;
    -- the week is played as the scheduler plays it: as the server, so the computer-run airlines can act (an admin's
    -- request would otherwise be refused for them). Only for the rest of this call.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    begin
      for i in 1..7 loop perform game.run_day(p_world); end loop;
    exception when others then
      insert into game.engine_log (world_id, game_day, message)
      select p_world, game_day + 1, sqlerrm from public.worlds where id = p_world;
    end;
  end if;
end $$;
