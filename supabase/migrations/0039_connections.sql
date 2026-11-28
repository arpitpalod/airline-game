-- Migration 0039 (spec 14.31): connections, step 4 of the regions plan (open item 29), part 1 of 3.
--
-- What changes:
--  * route_plans: network (sell the route network-based, off by default for players), conn_pct (a connection pays the
--    route this share of its own fare that week, 0.8 by default) and conn_share (connections take at most this share of
--    the route's seats, 0.3), net_day (when last set). route_weeks: bk_cx and bk_cxb (connecting passengers booked, in
--    the route's bookings), rev_cx (their part of the fares, in its takings) and disp (its own travellers turned away
--    while connections had seats).
--  * public.set_network(airline, route, on, pct, share): the player's settings, route by route (computer-run airlines
--    use it too).
--  * game.sell_week (from 0037): an airline's two routes through one airport, both network-based, sell connections in
--    the market between their other ends, for the same flight week, when that market exists. Travellers weigh a
--    connection like a nonstop less a stop and a detour (G, by traveller type); its fare is the two routes' shares of
--    their own fares; seats go in proportion within each route's share for connections; travellers turned away by a
--    full nonstop choose again among the connections. On markets with neither end in the world's home region the real
--    airlines that fly them are a choice too (outside_*, G). Nothing else in selling changes: with no route
--    network-based, every booking is as before.
--  * game.bot_network: computer-run airlines sell every route network-based from the start (bot_net_pct,
--    bot_net_share) and review each route every 13 weeks: fewer seats for connections at a higher fare when the locals
--    turned away were worth more than half of what the connections paid, more seats at a lower fare when the route
--    flew under 75% full. Running worlds: their computer-run airlines start connecting at the next week of selling.

alter table public.route_plans
  add column network boolean not null default false,
  add column conn_pct numeric not null default 0.8 check (conn_pct between 0.3 and 1.2),
  add column conn_share numeric not null default 0.3 check (conn_share between 0 and 1),
  add column net_day int;
alter table public.route_weeks
  add column bk_cx numeric not null default 0,
  add column bk_cxb numeric not null default 0,
  add column rev_cx numeric not null default 0,
  add column disp numeric not null default 0;

insert into public.game_params (key, num, note) values
  ('conn_stop_biz', 0.9, 'a stop on the way, as a share of the market''s reference fare, for business travellers (0039): at equal fares 19 in 20 take the nonstop'),
  ('conn_stop_lei', 0.23, 'a stop on the way for leisure travellers (0039): at equal fares 4 in 5 take the nonstop; a connection about 25% cheaper splits them evenly'),
  ('conn_stop_bud', 0.094, 'a stop on the way for budget travellers (0039): at equal fares 7 in 10 take the nonstop'),
  ('conn_detour_biz', 1.5, 'each 100% of extra distance on a connection, as a share of the reference fare, for business travellers (0039)'),
  ('conn_detour_lei', 0.5, 'each 100% of extra distance, for leisure travellers (0039)'),
  ('conn_detour_bud', 0.3, 'each 100% of extra distance, for budget travellers (0039)'),
  ('conn_calc_detour', 2.5, 'the engine leaves out connections longer than this many times the direct distance: they sell next to nothing (0039; players are not limited)'),
  ('conn_recapture', 1, 'travellers turned away by a full nonstop choose again among the connections: 1 on, 0 off (0039)'),
  ('conn_min_leg_km', 150, 'each of a connection''s two routes is at least this long: a hop to another airport of the same city connects nobody (0039)'),
  ('conn_pct_min', 0.5, 'the lowest share of its own fare a route can take from a connection (0039)'),
  ('conn_pct_max', 1.0, 'the highest share (0039)'),
  ('outside_on', 1, 'airlines outside the world on markets with neither end in the world''s home region: 1 on, 0 off (0039)'),
  ('outside_freq', 2, 'their flights a day (0039)'),
  ('outside_fare', 1.0, 'their fare, against the reference fare and the world''s fare index (0039)'),
  ('outside_comfort', 0.5, 'their seat comfort, on the engine''s scale (pitch above 28 inches / 6) (0039)'),
  ('outside_brand', 60, 'their brand (0039)'),
  ('outside_nonstop_km', 13000, 'beyond this distance they stop once on the way (0039)'),
  ('bot_net_pct', 0.8, 'computer-run airlines: share of the route''s fare a connection pays, from the start (0039)'),
  ('bot_net_share', 0.3, 'computer-run airlines: share of seats open to connections, from the start (0039)'),
  ('bot_net_share_max', 0.6, 'computer-run airlines open at most this share of seats to connections (0039)'),
  ('bot_net_lf_low', 0.75, 'computer-run airlines open more seats to connections when a route flew under this load (0039)'),
  ('bot_net_disp_ratio', 0.5, 'computer-run airlines close seats to connections when the locals turned away were worth more than this share of the connections'' takings (0039)');

-- The player's network settings, route by route. A connection needs both its routes network-based.
create or replace function public.set_network(p_airline uuid, p_route uuid, p_on boolean, p_pct numeric default null, p_share numeric default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_pct numeric;
  v_share numeric;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  if not exists (select 1 from public.routes where id = p_route and airline_id = p_airline and status = 'open') then
    raise exception 'That route is not yours';
  end if;
  select coalesce(p_pct, conn_pct), coalesce(p_share, conn_share) into v_pct, v_share from public.route_plans where route_id = p_route;
  if v_pct < game.param('conn_pct_min') or v_pct > game.param('conn_pct_max') then
    raise exception 'A connection pays the route % to % of its own fare', round(100 * game.param('conn_pct_min')) || '%', round(100 * game.param('conn_pct_max')) || '%';
  end if;
  if v_share < 0 or v_share > 1 then raise exception 'Seats open to connections run from none to all'; end if;
  update public.route_plans set network = p_on, conn_pct = round(v_pct, 2), conn_share = round(v_share, 2), net_day = rw.game_day
   where route_id = p_route;
  return jsonb_build_object('route_id', p_route, 'network', p_on, 'conn_pct', round(v_pct, 2), 'conn_share', round(v_share, 2));
end $$;
revoke all on function public.set_network(uuid, uuid, boolean, numeric, numeric) from public, anon;
grant execute on function public.set_network(uuid, uuid, boolean, numeric, numeric) to authenticated, service_role;

-- Computer-run airlines' network selling (0039), run at each week of selling before the fares. They use the players'
-- function, so they meet the same limits.
create or replace function game.bot_network(p_world uuid, p_week int) returns void
language plpgsql set search_path = '' as $$
declare
  r record;
begin
  -- routes not yet set: network-based from the start, at the moderate setting
  for r in select p.route_id, p.airline_id from public.route_plans p
             join public.routes rt on rt.id = p.route_id and rt.world_id = p_world and rt.status = 'open'
             join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
            where p.net_day is null loop
    perform public.set_network(r.airline_id, r.route_id, true, game.param('bot_net_pct')::numeric, game.param('bot_net_share')::numeric);
  end loop;
  if p_week % 13 <> 0 then return; end if;
  -- every 13 weeks, each route's last 13 flown weeks: when the locals its connections turned away were worth more than
  -- bot_net_disp_ratio of what the connections paid it, fewer seats for connections at a higher share of the fare; when
  -- the route flew under bot_net_lf_low full, more seats at a lower share
  for r in select p.route_id, p.airline_id, p.conn_pct, p.conn_share, sum(w.rev_cx) as rcx,
                  sum(w.disp * w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0)) as dv,
                  sum(coalesce(w.flown_e, 0) + coalesce(w.flown_b, 0)) / nullif(sum(w.seats_e + w.seats_b), 0) as lf
             from public.route_plans p
             join public.routes rt on rt.id = p.route_id and rt.world_id = p_world and rt.status = 'open'
             join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
             join public.route_weeks w on w.route_id = p.route_id and w.flown_e is not null and w.week > p_week - 14
            where p.network
            group by p.route_id, p.airline_id, p.conn_pct, p.conn_share loop
    if coalesce(r.dv, 0) > game.param('bot_net_disp_ratio') * coalesce(r.rcx, 0) and r.conn_share > 0.05 then
      perform public.set_network(r.airline_id, r.route_id, true, least(game.param('conn_pct_max')::numeric, r.conn_pct + 0.05),
                                 greatest(0, r.conn_share - 0.1));
    elsif r.lf < game.param('bot_net_lf_low') and r.conn_share < game.param('bot_net_share_max') then
      perform public.set_network(r.airline_id, r.route_id, true, greatest(game.param('conn_pct_min')::numeric, r.conn_pct - 0.05),
                                 least(game.param('bot_net_share_max')::numeric, r.conn_share + 0.1));
    end if;
  end loop;
end $$;

-- Selling (from 0037), with connections (0039).
CREATE OR REPLACE FUNCTION game.sell_week(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
declare
  rw public.worlds%rowtype;
  g record;
  v_w int := game.week_of(p_day);
  v_h int := game.param('sale_weeks')::int;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record(game.params_for(p_world)) as x(   -- 0027: the world's own values (growth)
    seg_biz_a float8, seg_biz_price float8, seg_biz_freq float8, seg_biz_comfort float8, seg_biz_brand float8,
    seg_lei_a float8, seg_lei_price float8, seg_lei_freq float8, seg_lei_comfort float8, seg_lei_brand float8,
    seg_bud_a float8, seg_bud_price float8, seg_bud_freq float8, seg_bud_comfort float8, seg_bud_brand float8,
    biz_fare_mult float8, nest_lambda float8, biz_downgrade_share float8, seg_biz_cabin_a float8,
    growth_year float8, growth_year_intl float8, season_start_month float8, demand_noise_sd float8,
    book_shape_biz float8, book_scale_biz float8, book_shape_lei float8, book_scale_lei float8,
    book_shape_bud float8, book_scale_bud float8, fare_ramp_power float8,
    noshow_biz float8, noshow_lei float8, noshow_bud float8, noshow_market_sd float8, noshow_week_sd float8,
    denied_comp_inr float8, rm_history_weeks float8, watch_ahead_weeks float8,
    news_fare_move float8, news_flights_move float8, insight_min_routes float8,
    cancel_notice_days float8, denied_fare_mult float8,   -- 0033
    conn_stop_biz float8, conn_stop_lei float8, conn_stop_bud float8, conn_detour_biz float8, conn_detour_lei float8,
    conn_detour_bud float8, conn_calc_detour float8, outside_on float8, outside_freq float8, outside_fare float8,
    outside_comfort float8, outside_brand float8, outside_nonstop_km float8, conn_recapture float8, conn_min_leg_km float8);   -- 0039
  perform game.bot_network(p_world, v_w);   -- 0039: computer-run airlines' network selling, before the fares

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
  create temp table _money (airline_id uuid, sales float8 default 0, refunds float8 default 0, comp float8 default 0,
                       ccomp float8 default 0, cut float8 default 0) on commit drop;   -- 0033: compensation and flights for cuts

  -- 1. Routes closed: their tickets are refunded. 0033: the flights of a closed route that fly within the region's notice
  -- (cancel_notice_days from today) also pay compensation, and count as cut for brand.
  with gone as (
    delete from public.route_weeks x using public.routes r, public.markets m
     where x.world_id = p_world and x.flown_e is null and r.id = x.route_id and r.status <> 'open'
       and m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    returning x.airline_id, 2 * (x.rev_e + x.rev_b) as amt,
              least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7 as sh,
              2 * ((x.bk_be + x.bk_l + x.bk_u) * game.cancel_comp(p_world, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
                   + x.bk_b * game.cancel_comp(p_world, m.km, x.rev_b / nullif(x.bk_b, 0))) as cc,
              case when x.bk_be + x.bk_l + x.bk_u + x.bk_b = 0 then 0 else 2 * x.trips end as cut)
  insert into pg_temp._money (airline_id, refunds, ccomp, cut)
  select airline_id, sum(amt), sum(sh * cc), sum(sh * cut) from gone group by airline_id;

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
        seats_max_b = greatest(public.route_weeks.seats_max_b, excluded.seats_b),
        -- 0033: seats and flights cut since last week, for the share of the week's flights within the region's notice
        cut_in_e = public.route_weeks.cut_in_e + greatest(0, public.route_weeks.seats_e - excluded.seats_e)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7,
        cut_in_b = public.route_weeks.cut_in_b + greatest(0, public.route_weeks.seats_b - excluded.seats_b)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7,
        cut_in_trips = public.route_weeks.cut_in_trips + greatest(0, public.route_weeks.trips - excluded.trips)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7;
  update public.route_weeks x set trips = 0, seats_e = 0, seats_b = 0,
         cut_in_e = x.cut_in_e + x.seats_e * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7,
         cut_in_b = x.cut_in_b + x.seats_b * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7,
         cut_in_trips = x.cut_in_trips + x.trips * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7
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
         -- 0026: where the route sells: reach abroad, and the rupees a ticket brings when part is priced in dollars
         coalesce(po.util_bonus, 0)::float8 as pu,
         case when m.intl then 1 + coalesce(po.usd_share, 0) * (rw.fx_inr_usd / game.wparam(p_world, 'fx_ref_inr_usd') - 1) else 1 end::float8 as fxm,
         s.target_lf::float8 as tlf, s.early_mult::float8 as em, s.late_mult::float8 as lm,
         s.biz_early_mult::float8 as bem, s.biz_late_mult::float8 as blm, s.min_mult::float8 as mn, s.max_mult::float8 as mx,
         s.step::float8 as st, s.band::float8 as bd, s.follow_gap::float8 as gap, s.overbook::float8 as ob,
         c.trips / 7 as f, c.seats_e as se, c.seats_b as sb, c.comf_e as ce, c.comf_b as cb, c.block_h as bh,
         al.brand::float8 as brand, ax.d_biz::float8 as adb, ax.d_lei::float8 as adl, ax.d_bud::float8 as adu,
         (x.bk_be + x.bk_l + x.bk_u)::float8 as sold_e, x.bk_b::float8 as sold_b, x.adj_e::float8 as adj_e, x.adj_b::float8 as adj_b, x.listed,
         p.network as nw, p.conn_pct::float8 as cpct, p.conn_share::float8 as cshare, x.bk_cx::float8 as sold_cx, m.km::float8 as km,   -- 0039
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         -- the market's own (hidden) no-show factor, and the no-show share the engine expects in economy from the traveller mix
         mf.v as mf,
         (m.n_biz * g.noshow_biz + m.n_lei * g.noshow_lei + m.n_bud * g.noshow_bud) / nullif(m.n_biz + m.n_lei + m.n_bud, 0) * mf.v as ns,
         0::float8 as pe, 0::float8 as pb, 0::float8 as room_e, 0::float8 as room_b,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu,
         0::float8 as got_be, 0::float8 as got_l, 0::float8 as got_u, 0::float8 as got_b, 0::float8 as lost,
         1::float8 as fac, 0::float8 as dg, 0::float8 as disp   -- 0039
    from public.route_weeks x
    join pg_temp._cap c on c.route_id = x.route_id and c.week = x.week
    join public.route_plans p on p.route_id = x.route_id
    join public.rm_strategies s on s.key = p.strategy
    join public.markets m on m.a = c.a and m.b = c.b
    left join public.pos_options po on po.key = p.sell_where and m.intl
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

  -- 0028: fare caps in a crisis. While a cap is in force, economy on domestic routes to and from its airport sells at
  -- most at the cap (its multiple of the reference fare), for every flight week on sale.
  update pg_temp._sell z set pe = least(z.pe, floor(fc.mult * z.ref / 10) * 10)
    from (select e.payload ->> 'airport' as ap, min((e.payload ->> 'mult')::float8) as mult
            from public.events e
           where e.world_id = p_world and e.kind = 'fare_cap' and e.starts_day <= p_day and e.ends_day >= p_day
           group by 1) fc
   where not z.intl and fc.ap in (z.a, z.b);

  -- 4. This week's bookings. Seats can be sold beyond the cabin by the strategy's overbooking share of expected no-shows.
  update pg_temp._sell set
    room_e = greatest(0, se * (1 + ob * ns) - sold_e),
    room_b = greatest(0, sb * (1 + ob * g.noshow_biz * mf) - sold_b);
  update pg_temp._sell set
    xb_e = case when room_e > 0.5 then game.sell_x(g.seg_biz_a - g.seg_biz_price * (pe / ref + adb) + g.seg_biz_freq * ln(1 + f)
             + g.seg_biz_comfort * ce * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xb_b = case when room_b > 0.5 then game.sell_x(g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * pb / (ref * g.biz_fare_mult)
             + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * cb * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xl   = case when room_e > 0.5 then game.sell_x(g.seg_lei_a - g.seg_lei_price * (pe / ref + adl) + g.seg_lei_freq * ln(1 + f)
             + g.seg_lei_comfort * ce * sqrt(bh) + g.seg_lei_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xu   = case when room_e > 0.5 then game.sell_x(g.seg_bud_a - g.seg_bud_price * (pe / ref + adu) + g.seg_bud_freq * ln(1 + f)
             + g.seg_bud_comfort * ce * sqrt(bh) + g.seg_bud_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end;

  -- 0039: a flight week opens for sale on its market when no airline had it on sale before (a new market, or the
  -- world's first week): travellers who would have booked earlier book now
  drop table if exists pg_temp._op;
  create temp table _op on commit drop as
  select route_id, week, min(listed) over (partition by a, b, week) = v_w as opening from pg_temp._sell;

  -- 0039: connections. An airline's two routes through one airport, both selling network-based, make a connection in
  -- the market between their other ends for the same flight week, when that market exists. Its fare is each route's
  -- share (conn_pct) of that route's own fare that week, cabin by cabin, and each route keeps its part. Travellers
  -- weigh it like a nonstop less a stop and a detour (conn_stop_*, conn_detour_*: shares of the market's reference
  -- fare, G); its frequency is the lower of the two. Connections take at most conn_share of a route's seats. The engine
  -- leaves out detours beyond conn_calc_detour times the direct distance: they sell next to nothing. Each of the two
  -- routes is at least conn_min_leg_km long.
  drop table if exists pg_temp._cn;
  create temp table _cn on commit drop as
  with legs as (
    select s.route_id, s.airline_id, s.week, s.n, s.f, s.ce, s.cb, s.bh, s.brand, s.adb, s.adl, s.adu, s.pu, s.km,
           s.cpct * s.pe as pc, case when s.sb > 0 then s.cpct * s.pb end as pcb,
           least(s.room_e, greatest(0, s.cshare * s.se * (1 + s.ob * s.ns) - s.sold_cx)) > 0.5 as ok_e,
           s.sb > 0 and s.room_b > 0.5 as ok_b,
           h.hub, case when s.a = h.hub then s.b else s.a end as far
      from pg_temp._sell s cross join lateral (values (s.a), (s.b)) h(hub)
     where s.nw and s.km >= g.conn_min_leg_km)   -- a hop to the next airport in the same city connects nobody
  select l1.airline_id, l1.week, l1.n, l1.route_id as r1, l2.route_id as r2, l1.hub,
         m.a, m.b, m.intl, m.km::float8 as km, m.ref_fare::float8 as ref,
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         (l1.km + l2.km) / m.km as det,
         least(l1.f, l2.f) as f, least(l1.ce, l2.ce) as ce, least(l1.cb, l2.cb) as cb, greatest(l1.bh, l2.bh) as bh,
         l1.brand, (l1.adb + l2.adb) / 2 as adb, (l1.adl + l2.adl) / 2 as adl, (l1.adu + l2.adu) / 2 as adu,
         greatest(l1.pu, l2.pu) as pu,
         l1.pc as pe1, l2.pc as pe2, l1.pcb as pb1, l2.pcb as pb2,
         l1.ok_e and l2.ok_e as ok_e, l1.ok_b and l2.ok_b as ok_b,
         o1.opening and o2.opening as opening,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu
    from legs l1
    join legs l2 on l2.airline_id = l1.airline_id and l2.week = l1.week and l2.hub = l1.hub and l1.far < l2.far
    join public.markets m on m.a = l1.far and m.b = l2.far
    join pg_temp._op o1 on o1.route_id = l1.route_id and o1.week = l1.week
    join pg_temp._op o2 on o2.route_id = l2.route_id and o2.week = l2.week
   where (l1.ok_e and l2.ok_e or l1.ok_b and l2.ok_b)
     and l1.km + l2.km <= g.conn_calc_detour * m.km;
  update pg_temp._cn set
    xb_e = case when ok_e then game.sell_x(g.seg_biz_a - g.seg_biz_price * ((pe1 + pe2) / ref + adb + g.conn_stop_biz + g.conn_detour_biz * (det - 1))
             + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * ce * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xb_b = case when ok_b then game.sell_x(g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * ((pb1 + pb2) / (ref * g.biz_fare_mult) + g.conn_stop_biz
             + g.conn_detour_biz * (det - 1)) + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * cb * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu,
             g.nest_lambda) else 0 end,
    xl   = case when ok_e then game.sell_x(g.seg_lei_a - g.seg_lei_price * ((pe1 + pe2) / ref + adl + g.conn_stop_lei + g.conn_detour_lei * (det - 1))
             + g.seg_lei_freq * ln(1 + f) + g.seg_lei_comfort * ce * sqrt(bh) + g.seg_lei_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xu   = case when ok_e then game.sell_x(g.seg_bud_a - g.seg_bud_price * ((pe1 + pe2) / ref + adu + g.conn_stop_bud + g.conn_detour_bud * (det - 1))
             + g.seg_bud_freq * ln(1 + f) + g.seg_bud_comfort * ce * sqrt(bh) + g.seg_bud_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end;

  -- 0039: airlines outside the world. On a market with neither end in the world's home region, travellers also have
  -- the real airlines that fly it (outside_*, G): the reference fare, outside_freq flights a day, one stop beyond
  -- outside_nonstop_km. They have every seat they need, and their passengers are not counted.
  drop table if exists pg_temp._ox;
  create temp table _ox on commit drop as
  select q.a, q.b, q.week, q.n, q.intl, q.nb, q.nl, q.nu, q.opening,
         game.sell_x(g.seg_biz_a - g.seg_biz_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_biz else 0 end)
           + g.seg_biz_freq * ln(1 + g.outside_freq) + g.seg_biz_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_biz_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xb,
         game.sell_x(g.seg_lei_a - g.seg_lei_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_lei else 0 end)
           + g.seg_lei_freq * ln(1 + g.outside_freq) + g.seg_lei_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_lei_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xl,
         game.sell_x(g.seg_bud_a - g.seg_bud_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_bud else 0 end)
           + g.seg_bud_freq * ln(1 + g.outside_freq) + g.seg_bud_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_bud_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xu
    from (select a, b, week, n, intl, nb, nl, nu, km, bool_and(opening) as opening from pg_temp._cn
           group by a, b, week, n, intl, nb, nl, nu, km) q
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    cross join lateral (select coalesce(rw.fare_index, 1)::float8 * g.outside_fare as fare, q.km / 830 + 0.6 as bh) o
   where g.outside_on > 0
     and pa.home is distinct from game.world_region(p_world) and pb.home is distinct from game.world_region(p_world);

  -- festivals and events (G): each day of a flight week inside an event adds a seventh of the event's extra demand
  drop table if exists pg_temp._ev;
  create temp table _ev on commit drop as
  select q.a, q.b, q.week,
         (1 + sum(e.biz - 1) / 7.0)::float8 as fb, (1 + sum(e.lei - 1) / 7.0)::float8 as fl, (1 + sum(e.bud - 1) / 7.0)::float8 as fu
    from (select a, b, week, intl from pg_temp._sell union select a, b, week, intl from pg_temp._cn) q   -- 0039: and connections' markets
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    cross join generate_series(0, 6) dd
    join public.demand_events e
      on (((q.week - 1) * 7 + dd) % 364 + 1 - e.start_doy + 364) % 364 < e.days
     and e.region = game.world_region(p_world)   -- 0037: the world's region's calendar
     and (e.domestic is null or e.domestic = not q.intl)
     and (e.airports is null or q.a = any (e.airports) or q.b = any (e.airports))
     and (e.regions is null or pa.region = any (e.regions) or pb.region = any (e.regions))
   group by q.a, q.b, q.week;

  -- travellers who decide this week on each market and flight week: the week's demand (7 days, season of its middle day,
  -- growth, a swing fixed per market and week) times the share of each type who book n weeks ahead (when the week first
  -- opens on its market, everyone who would have booked by then). 0039: market by market, with every choice in it
  -- (nonstops, connections, airlines outside the world) in one nest
  drop table if exists pg_temp._mkt;
  create temp table _mkt on commit drop as
  with u as (
    select z.a, z.b, z.week, z.n, z.intl, z.nb, z.nl, z.nu, o.opening, z.xb_e + z.xb_b as xb, z.xl, z.xu
      from pg_temp._sell z join pg_temp._op o on o.route_id = z.route_id and o.week = z.week
    union all
    select a, b, week, n, intl, nb, nl, nu, opening, xb_e + xb_b, xl, xu from pg_temp._cn
    union all
    select a, b, week, n, intl, nb, nl, nu, opening, xb, xl, xu from pg_temp._ox),
  mk as (
    select a, b, week, n, intl, nb, nl, nu, bool_and(opening) as opening, sum(xb) as xb, sum(xl) as xl, sum(xu) as xu
      from u group by a, b, week, n, intl, nb, nl, nu),
  wk as (
    select w, (w - 1) * 7 + 4 as mid,
           power(1 + g.growth_year, ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow,
           power(1 + coalesce(g.growth_year_intl, g.growth_year), ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow_i
      from generate_series(v_w, v_w + v_h - 1) w),
  sf as (
    select wk.w, wk.grow, wk.grow_i, s.biz, s.lei, s.bud from wk join public.season_factors s
      on s.month = ((g.season_start_month::int - 1 + (((wk.mid - 1) % 364) * 12) / 364) % 12) + 1)
  select mk.a, mk.b, mk.week,
         7 * mk.nb * sf.biz * coalesce(ev.fb, 1) * k.v * case when mk.opening then c.pre_b + c.arr_b else c.arr_b end as ab,
         7 * mk.nl * sf.lei * coalesce(ev.fl, 1) * k.v * case when mk.opening then c.pre_l + c.arr_l else c.arr_l end as al_,
         7 * mk.nu * sf.bud * coalesce(ev.fu, 1) * k.v * case when mk.opening then c.pre_u + c.arr_u else c.arr_u end as au,
         game.sell_k(mk.xb, g.nest_lambda) as kb, game.sell_k(mk.xl, g.nest_lambda) as kl, game.sell_k(mk.xu, g.nest_lambda) as ku
    from mk
    join sf on sf.w = mk.week
    join pg_temp._curve c on c.n = mk.n
    left join pg_temp._ev ev on ev.a = mk.a and ev.b = mk.b and ev.week = mk.week
    cross join lateral (select case when mk.intl then sf.grow_i else sf.grow end * exp(g.demand_noise_sd / sqrt(7) * game.hash_normal(p_world::text || mk.a || mk.b || mk.week)
                                             - g.demand_noise_sd ^ 2 / 14) as v) k;

  -- what each nonstop and each connection is asked for
  drop table if exists pg_temp._dem;
  create temp table _dem on commit drop as
  select z.route_id, z.week, k.ab * z.xb_e * k.kb as d_be, k.ab * z.xb_b * k.kb as d_bb, k.al_ * z.xl * k.kl as d_l, k.au * z.xu * k.ku as d_u
    from pg_temp._sell z join pg_temp._mkt k on k.a = z.a and k.b = z.b and k.week = z.week;
  drop table if exists pg_temp._cd;
  create temp table _cd on commit drop as
  select c.r1, c.r2, c.week, c.a, c.b, c.pe1, c.pe2, c.pb1, c.pb2, c.xb_e, c.xl, c.xu,
         k.ab * c.xb_e * k.kb as dbe, k.ab * c.xb_b * k.kb as dbb, k.al_ * c.xl * k.kl as dl, k.au * c.xu * k.ku as du,
         0::float8 as fe, 0::float8 as fb
    from pg_temp._cn c join pg_temp._mkt k on k.a = c.a and k.b = c.b and k.week = c.week;

  -- 0039: seats. Each route's seats go to its own travellers and its connections in proportion; connections first within
  -- conn_share of the seats. A connection gets what both its routes can give it; its own travellers then get the rest.
  drop table if exists pg_temp._lg;
  create temp table _lg on commit drop as
  with cl as (
    select v.r as route_id, d.week, sum(d.dbe + d.dl + d.du) as ce_d, sum(d.dbb) as cb_d
      from pg_temp._cd d cross join lateral (values (d.r1), (d.r2)) v(r) group by v.r, d.week)
  select z.route_id, z.week, z.room_e, z.room_b,
         greatest(0, z.cshare * z.se * (1 + z.ob * z.ns) - z.sold_cx) as croom,
         d.d_be, d.d_bb, d.d_l, d.d_u,
         g.biz_downgrade_share * greatest(d.d_bb - z.room_b, 0) as dg0,
         coalesce(cl.ce_d, 0) as ce_d, coalesce(cl.cb_d, 0) as cb_d,
         1::float8 as fce, 1::float8 as fcb, 0::float8 as a_e, 0::float8 as a_b
    from pg_temp._sell z
    join pg_temp._dem d on d.route_id = z.route_id and d.week = z.week
    left join cl on cl.route_id = z.route_id and cl.week = z.week;
  update pg_temp._lg l set
    fce = case when ce_d > 0 then least(1, croom / ce_d) * least(1, room_e / nullif(d_be + dg0 + d_l + d_u + ce_d * least(1, croom / ce_d), 0)) else 1 end,
    fcb = case when cb_d > 0 then least(1, room_b / nullif(d_bb + cb_d, 0)) else 1 end;
  update pg_temp._cd d set fe = least(l1.fce, l2.fce), fb = least(l1.fcb, l2.fcb)
    from pg_temp._lg l1, pg_temp._lg l2
   where l1.route_id = d.r1 and l1.week = d.week and l2.route_id = d.r2 and l2.week = d.week;
  update pg_temp._lg l set a_e = x.ae, a_b = x.abz
    from (select v.r, d.week, sum((d.dbe + d.dl + d.du) * d.fe) as ae, sum(d.dbb * d.fb) as abz
            from pg_temp._cd d cross join lateral (values (d.r1), (d.r2)) v(r) group by v.r, d.week) x
   where x.r = l.route_id and x.week = l.week;

  -- business cabin first (after its connections); part of its overflow takes economy on the same airline
  with bz as (
    select l.route_id, l.week, l.d_be, l.d_l, l.d_u, l.d_bb, l.a_e,
           least(l.d_bb, greatest(0, l.room_b - l.a_b)) as got_b,
           g.biz_downgrade_share * greatest(l.d_bb - least(l.d_bb, greatest(0, l.room_b - l.a_b)), 0) as dg,
           greatest(0, l.room_e - l.a_e) as re
      from pg_temp._lg l)
  update pg_temp._sell z
     set got_b = bz.got_b,
         got_be = (bz.d_be + bz.dg) * e.fac, got_l = bz.d_l * e.fac, got_u = bz.d_u * e.fac,
         lost = (bz.d_bb - bz.got_b - bz.dg) + (bz.d_be + bz.dg + bz.d_l + bz.d_u) * (1 - e.fac),
         fac = e.fac, dg = bz.dg,
         disp = case when bz.a_e > 0 and bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.re
                     then least(bz.d_be + bz.dg + bz.d_l + bz.d_u - bz.re, bz.a_e) else 0 end
    from bz cross join lateral (select case when bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.re
                                            then bz.re / (bz.d_be + bz.dg + bz.d_l + bz.d_u) else 1 end as fac) e
   where bz.route_id = z.route_id and bz.week = z.week;

  -- 0039: travellers turned away by a full nonstop choose again among the connections on their market (and the airlines
  -- outside the world), in the seats the connections' routes still have
  drop table if exists pg_temp._rc;
  create temp table _rc on commit drop as
  with lost as (
    select z.a, z.b, z.week, sum((d.d_be + z.dg) * (1 - z.fac)) as lbe, sum(d.d_l * (1 - z.fac)) as ll, sum(d.d_u * (1 - z.fac)) as lu
      from pg_temp._sell z join pg_temp._dem d on d.route_id = z.route_id and d.week = z.week
     where z.fac < 0.999
     group by z.a, z.b, z.week),
  sx as (
    select d.a, d.b, d.week, sum(d.xb_e) as sb, sum(d.xl) as sl, sum(d.xu) as su from pg_temp._cd d group by d.a, d.b, d.week),
  so as (
    select s.a, s.b, s.week, s.sb + coalesce(o.xb, 0) as sb, s.sl + coalesce(o.xl, 0) as sl, s.su + coalesce(o.xu, 0) as su
      from sx s left join pg_temp._ox o on o.a = s.a and o.b = s.b and o.week = s.week)
  select d.r1, d.r2, d.week,
         lo.lbe * d.xb_e * game.sell_k(so.sb, g.nest_lambda) as rbe, lo.ll * d.xl * game.sell_k(so.sl, g.nest_lambda) as rl,
         lo.lu * d.xu * game.sell_k(so.su, g.nest_lambda) as ru, 0::float8 as fr
    from pg_temp._cd d
    join lost lo on lo.a = d.a and lo.b = d.b and lo.week = d.week
    join so on so.a = d.a and so.b = d.b and so.week = d.week
   where g.conn_recapture > 0;
  with left_ as (
    select l.route_id, l.week,
           greatest(0, least(l.room_e - l.a_e - z.got_be - z.got_l - z.got_u, l.croom - l.a_e)) as lo
      from pg_temp._lg l join pg_temp._sell z on z.route_id = l.route_id and z.week = l.week),
  need as (
    select v.r, r.week, sum(r.rbe + r.rl + r.ru) as nd from pg_temp._rc r cross join lateral (values (r.r1), (r.r2)) v(r) group by v.r, r.week),
  f as (
    select n.r, n.week, case when n.nd > 0 then least(1, lf.lo / n.nd) else 1 end as f
      from need n join left_ lf on lf.route_id = n.r and lf.week = n.week)
  update pg_temp._rc r set fr = least(f1.f, f2.f)
    from f f1, f f2 where f1.r = r.r1 and f1.week = r.week and f2.r = r.r2 and f2.week = r.week;

  -- what each route carries for connections this week: travellers by type, its part of their fares, and the locals its
  -- connections left without a seat
  drop table if exists pg_temp._cl;
  create temp table _cl on commit drop as
  with t as (
    select d.r1 as route_id, d.week, d.dbe * d.fe as cbe, d.dl * d.fe as cl, d.du * d.fe as cu, d.dbb * d.fb as cb, d.pe1 as pe, d.pb1 as pb from pg_temp._cd d
    union all
    select d.r2, d.week, d.dbe * d.fe, d.dl * d.fe, d.du * d.fe, d.dbb * d.fb, d.pe2, d.pb2 from pg_temp._cd d
    union all
    select r.r1, r.week, r.rbe * r.fr, r.rl * r.fr, r.ru * r.fr, 0, d.pe1, null from pg_temp._rc r join pg_temp._cd d on d.r1 = r.r1 and d.r2 = r.r2 and d.week = r.week
    union all
    select r.r2, r.week, r.rbe * r.fr, r.rl * r.fr, r.ru * r.fr, 0, d.pe2, null from pg_temp._rc r join pg_temp._cd d on d.r1 = r.r1 and d.r2 = r.r2 and d.week = r.week)
  select route_id, week, sum(cbe) as cbe, sum(cl) as cl, sum(cu) as cu, sum(cb) as cb,
         sum((cbe + cl + cu) * pe) as rev_e, sum(cb * coalesce(pb, 0)) as rev_b
    from t group by route_id, week;

  update public.route_weeks x
     set price_e = z.pe, price_b = case when z.sb > 0 then z.pb end, adj_e = z.adj_e, adj_b = z.adj_b, strategy = z.strategy,
         bk_be = x.bk_be + z.got_be + coalesce(c.cbe, 0), bk_l = x.bk_l + z.got_l + coalesce(c.cl, 0),
         bk_u = x.bk_u + z.got_u + coalesce(c.cu, 0), bk_b = x.bk_b + z.got_b + coalesce(c.cb, 0),
         rev_e = x.rev_e + ((z.got_be + z.got_l + z.got_u) * z.pe + coalesce(c.rev_e, 0)) * z.fxm,
         rev_b = x.rev_b + (z.got_b * z.pb + coalesce(c.rev_b, 0)) * z.fxm,
         sold_wk = z.got_be + z.got_l + z.got_u + z.got_b + coalesce(c.cbe + c.cl + c.cu + c.cb, 0), spill = x.spill + z.lost,
         bk_cx = x.bk_cx + coalesce(c.cbe + c.cl + c.cu, 0), bk_cxb = x.bk_cxb + coalesce(c.cb, 0),
         rev_cx = x.rev_cx + coalesce(c.rev_e + c.rev_b, 0) * z.fxm, disp = x.disp + z.disp
    from pg_temp._sell z left join pg_temp._cl c on c.route_id = z.route_id and c.week = z.week
   where x.route_id = z.route_id and x.week = z.week;
  -- weeks with no seats on sale this week sold nothing
  update public.route_weeks x set sold_wk = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null and x.sold_wk <> 0
     and not exists (select 1 from pg_temp._sell z where z.route_id = x.route_id and z.week = x.week);
  insert into pg_temp._money (airline_id, sales)
  select z.airline_id, 2 * sum((((z.got_be + z.got_l + z.got_u) * z.pe + z.got_b * z.pb) + coalesce(c.rev_e + c.rev_b, 0)) * z.fxm)
    from pg_temp._sell z left join pg_temp._cl c on c.route_id = z.route_id and c.week = z.week
   group by z.airline_id;

  -- 5. The flight week now starting closes. No-shows by traveller type (the market's hidden factor and a weekly swing);
  -- passengers who turn up beyond the seats cannot board: a refund, plus compensation unless the seats were cut by the
  -- airline's own schedule change (then a refund only).
  with fl as (
    select x.route_id, x.airline_id, x.seats_e, x.seats_b, x.seats_max_e, x.seats_max_b,
           x.cut_in_e, x.cut_in_b, x.cut_in_trips, m.km,   -- 0033
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
  -- 0033: of those who cannot board, the overbooked (beyond the most seats ever on sale) get denied-boarding money; those
  -- whose seats were cut within the region's notice get cancellation money; earlier cuts a refund only
  dz as (
    select dn.*, greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)) as ob_e, greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)) as ob_b,
           least(dn.den_e - greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)), dn.cut_in_e) as cn_e,
           least(dn.den_b - greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)), dn.cut_in_b) as cn_b,
           coalesce(dn.rev_e / nullif(dn.sold_e, 0), 0) as fe, coalesce(dn.rev_b / nullif(dn.sold_b, 0), 0) as fb
      from dn),
  upd as (
    update public.route_weeks x
       set noshow = dn.ns_e + dn.ns_b, denied = dn.den_e + dn.den_b,
           comp = dn.ob_e + dn.ob_b,
           flown_e = dn.sold_e - dn.ns_e - dn.den_e, flown_b = dn.sold_b - dn.ns_b - dn.den_b,
           rev_flown_e = dn.rev_e - dn.den_e * dn.fe,
           rev_flown_b = dn.rev_b - dn.den_b * dn.fb
      from dz dn where x.route_id = dn.route_id and x.week = v_w
    returning x.airline_id, 2 * (x.rev_e + x.rev_b - x.rev_flown_e - x.rev_flown_b) as refund,
              2 * (dn.ob_e * (g.denied_comp_inr + g.denied_fare_mult * dn.fe) + dn.ob_b * (g.denied_comp_inr + g.denied_fare_mult * dn.fb)) as comp,
              2 * (dn.cn_e * game.cancel_comp(p_world, dn.km, dn.fe) + dn.cn_b * game.cancel_comp(p_world, dn.km, dn.fb)) as cc,
              case when dn.cn_e + dn.cn_b > 0 then 2 * dn.cut_in_trips else 0 end as cut)
  insert into pg_temp._money (airline_id, refunds, comp, ccomp, cut)
  select airline_id, sum(refund), sum(comp), sum(cc), sum(cut) from upd group by airline_id;

  -- the money: tickets sold in, refunds and compensation out (compensation is a cost; the rest moves cash only)
  update public.airline_finance fin set cash_inr = round(fin.cash_inr + m.sales - m.refunds - m.comp - m.ccomp)
    from (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp, sum(ccomp) as ccomp from pg_temp._money group by airline_id) m
   where fin.airline_id = m.airline_id;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)   -- 0033
  select airline_id, p_day, 'cancellation', -round(sum(ccomp)), 'Compensation for flights cut after the notice', -round(sum(ccomp))
    from pg_temp._money group by airline_id having sum(ccomp) >= 1;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  select airline_id, p_day, 'denied_boarding', -round(sum(comp)), 'Compensation to passengers who could not board', -round(sum(comp))
    from pg_temp._money group by airline_id having sum(comp) >= 1;
  insert into public.airline_weeks (airline_id, week, sales_inr, refunds_inr, comp_inr, cancel_comp_inr, cut_flights, advance_inr)
  select al.id, v_w, round(coalesce(m.sales, 0)), round(coalesce(m.refunds, 0)), round(coalesce(m.comp, 0)),
         round(coalesce(m.ccomp, 0)), round(coalesce(m.cut, 0)::numeric, 2),
         round(coalesce((select 2 * sum(x.rev_e + x.rev_b) from public.route_weeks x where x.airline_id = al.id and x.week > v_w), 0))
    from public.airlines al
    left join (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp, sum(ccomp) as ccomp, sum(cut) as cut
                 from pg_temp._money group by airline_id) m
           on m.airline_id = al.id
   where al.world_id = p_world and (al.status = 'active' or m.airline_id is not null)
  on conflict (airline_id, week) do update
    set sales_inr = excluded.sales_inr, refunds_inr = excluded.refunds_inr, comp_inr = excluded.comp_inr, advance_inr = excluded.advance_inr,
        cancel_comp_inr = excluded.cancel_comp_inr, cut_flights = excluded.cut_flights;

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
end $function$;
