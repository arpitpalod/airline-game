-- Migration 0040 (spec 14.32): the hub and route study, connections part 2 of 3 (open item 31).
--
-- What changes:
--  * public.hub_studies (read-own): each study an airline paid for, its figures as one JSON document.
--  * public.hub_study(airline, hub): for Rs 1.5 crore (hub_study_inr, G), every route out of one airport that has a
--    market of its own (feeders and onward routes): its own travellers a week, the connecting travellers it could
--    carry through the hub, who flies it; the top connecting markets through the hub, their nonstops and the airlines
--    outside the world on them; the connecting travellers a week to expect with the airline's routes there now and
--    with a suggested set of hub_study_spokes routes; how many airlines fly from the hub and how many sell connections
--    there. Every figure carries its own error of about ±15% (hub_study_width), so two studies differ, and the
--    figures follow rivals' moves.
--  * game.bot_hub: once a year from week 26, each computer-run airline buys a study of its biggest base and opens the
--    best suggested route it does not fly (bot_hub_adds), like a player would; its aircraft come at the next quarter
--    end (bot_balance). Called from game.bot_network (0039), redefined here.
--  * No change to selling or to the day's engine.

create table public.hub_studies (
  id         bigserial primary key,
  airline_id uuid not null references public.airlines on delete cascade,
  world_id   uuid not null references public.worlds on delete cascade,
  hub        text not null references public.airports,
  game_day   int not null,
  cost_inr   numeric not null,
  result     jsonb not null
);
create index hub_studies_airline_idx on public.hub_studies (airline_id, hub, game_day);
alter table public.hub_studies enable row level security;
grant select on public.hub_studies to authenticated;
create policy read_own on public.hub_studies for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

insert into public.game_params (key, num, note) values
  ('hub_study_inr', 15000000, 'cost of a hub and route study (0040)'),
  ('hub_study_width', 0.15, 'a hub study''s figures are within about this share of the truth; each carries its own error (0040)'),
  ('hub_study_spokes', 12, 'routes in a hub study''s suggested network (0040)'),
  ('hub_study_list', 40, 'routes listed in a hub study, best first (0040)'),
  ('hub_study_markets', 15, 'connecting markets listed in a hub study (0040)'),
  ('hub_study_conn_pct', 0.8, 'a hub study prices each connection at this share of the two routes'' reference fares (0040)'),
  ('bot_hub_first', 26, 'computer-run airlines buy their first hub study in this week (0040)'),
  ('bot_hub_weeks', 52, 'and then every this many weeks (0040)'),
  ('bot_hub_min_cash', 200000000, 'a computer-run airline buys a hub study only with this much cash in hand, as a careful player would (0040)'),
  ('bot_hub_adds', 1, 'routes a computer-run airline opens from each hub study (0040)');

-- The hub and route study (0040). Estimates assume the airline flies each route twice a day at the reference fare and
-- sells connections daily at hub_study_conn_pct of the two routes' reference fares, against today's nonstops and the
-- airlines outside the world, at this season's demand.
create or replace function public.hub_study(p_airline uuid, p_hub text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_hub text := upper(p_hub);
  v_day int; v_cost numeric; v_w numeric; v_grow numeric; v_grow_i numeric; v_fi numeric; v_region text;
  v_sb numeric; v_sl numeric; v_su numeric; v_lam float8 := game.param('nest_lambda');
  v_res jsonb; v_sug text[];
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1; v_region := game.world_region(rw.id);
  if not exists (select 1 from public.airports where iata = v_hub and v_region = any (seen_in)) then
    raise exception 'There is no airport % in this world', p_hub;
  end if;
  v_cost := game.param('hub_study_inr');
  v_w := game.param('hub_study_width');
  perform game.book(p_airline, v_day, -v_cost, 'study', format('Hub and route study, %s', v_hub), -v_cost);

  v_grow := power(1 + game.wparam(rw.id, 'growth_year'), (v_day - 1) / 364.0) * rw.demand_scale;
  v_grow_i := power(1 + game.wparam(rw.id, 'growth_year_intl'), (v_day - 1) / 364.0) * rw.demand_scale;
  v_fi := coalesce(rw.fare_index, 1);
  select f.biz, f.lei, f.bud into v_sb, v_sl, v_su from public.season_factors f
   where f.month = ((game.param('season_start_month')::int - 1 + (((v_day - 1) % 364) * 12) / 364) % 12) + 1;

  -- every route out of the hub with a market of its own, to an airport this world shows
  drop table if exists pg_temp._hs;
  create temp table _hs on commit drop as
  select case when m.a = v_hub then m.b else m.a end as x, m.km::float8 as km, m.ref_fare::float8 as ref, m.intl,
         m.n_biz::float8 * v_sb as nb, m.n_lei::float8 * v_sl as nl, m.n_bud::float8 * v_su as nu,
         case when m.intl then v_grow_i else v_grow end as gr,
         0::float8 as loc, 0::float8 as con
    from public.markets m
    join public.airports ap on ap.iata = case when m.a = v_hub then m.b else m.a end
   where v_hub in (m.a, m.b) and v_region = any (ap.seen_in);
  -- its own travellers a week each way: one airline, two round trips a day, reference fare (as the route study)
  update pg_temp._hs set loc = 7 * gr * (
      nb * exp(u.b) / (1 + exp(u.b)) + nl * exp(u.l) / (1 + exp(u.l)) + nu * exp(u.u) / (1 + exp(u.u)))
    from (select x as xx,
                 game.param('seg_biz_a') - game.wparam(rw.id, 'seg_biz_price') * v_fi + game.param('seg_biz_freq') * ln(3)
                   + game.param('seg_biz_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as b,
                 game.param('seg_lei_a') - game.wparam(rw.id, 'seg_lei_price') * v_fi + game.param('seg_lei_freq') * ln(3)
                   + game.param('seg_lei_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as l,
                 game.param('seg_bud_a') - game.wparam(rw.id, 'seg_bud_price') * v_fi + game.param('seg_bud_freq') * ln(3)
                   + game.param('seg_bud_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as u
            from pg_temp._hs) u
   where u.xx = x;

  -- the markets between two of them that a connection through the hub could serve: daily connections at
  -- hub_study_conn_pct of the two reference fares, against the world's nonstops on the market and the airlines outside it
  drop table if exists pg_temp._hp;
  create temp table _hp on commit drop as
  with nst as (
    select least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b, sum(ro.weekly_trips)::float8 / 7 as f,
           count(distinct r.airline_id) as n
      from public.routes r join public.rotations ro on ro.route_id = r.id
     where r.world_id = rw.id and r.status = 'open'
     group by 1, 2)
  select s1.x as a, s2.x as b, mk.km::float8 as km, (s1.km + s2.km) / mk.km as det,
         game.param('hub_study_conn_pct') * (s1.ref + s2.ref) / mk.ref_fare as pf,
         coalesce(nst.f, 0) as nf, coalesce(nst.n, 0) as nn,
         pa.home is distinct from v_region and pb.home is distinct from v_region and game.param('outside_on') > 0 as outside,
         mk.n_biz::float8 * v_sb as nb, mk.n_lei::float8 * v_sl as nl, mk.n_bud::float8 * v_su as nu,
         case when mk.intl then v_grow_i else v_grow end as gr, 0::float8 as wk
    from pg_temp._hs s1
    join pg_temp._hs s2 on s1.x < s2.x
    join public.markets mk on mk.a = s1.x and mk.b = s2.x
    join public.airports pa on pa.iata = mk.a
    join public.airports pb on pb.iata = mk.b
    left join nst on nst.a = mk.a and nst.b = mk.b
   where s1.km + s2.km <= game.param('conn_calc_detour') * mk.km
     and s1.km >= game.param('conn_min_leg_km') and s2.km >= game.param('conn_min_leg_km');
  -- travellers a week each way, the three types summed
  update pg_temp._hp p set wk = 7 * p.gr * t.v
    from (select q.a as qa, q.b as qb, sum(case s.seg when 'biz' then q.nb when 'lei' then q.nl else q.nu end
                   * game.sell_x(c.u, v_lam) * game.sell_k(game.sell_x(c.u, v_lam)
                     + case when q.nf > 0 then game.sell_x(n.u, v_lam) else 0 end
                     + case when q.outside then game.sell_x(o.u, v_lam) else 0 end, v_lam)) as v
            from pg_temp._hp q
           cross join (values ('biz'), ('lei'), ('bud')) s(seg)
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price')
                                        * (q.pf + game.param('conn_stop_' || s.seg) + game.param('conn_detour_' || s.seg) * (q.det - 1))
                                      + game.param('seg_' || s.seg || '_freq') * ln(2) as u) c
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price') * v_fi
                                      + game.param('seg_' || s.seg || '_freq') * ln(1 + q.nf) as u) n
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price')
                                        * (v_fi * game.param('outside_fare') + case when q.km > game.param('outside_nonstop_km') then game.param('conn_stop_' || s.seg) else 0 end)
                                      + game.param('seg_' || s.seg || '_freq') * ln(1 + game.param('outside_freq'))
                                      + game.param('seg_' || s.seg || '_brand') * (game.param('outside_brand') - 50) / 50 as u) o
           group by q.a, q.b) t
   where t.qa = p.a and t.qb = p.b;
  update pg_temp._hs s set con = coalesce((select sum(p.wk) from pg_temp._hp p where s.x in (p.a, p.b)), 0);

  -- the suggested network: the best hub_study_spokes routes by own and connecting travellers
  select array_agg(x order by loc + con desc) into v_sug
    from (select x, loc, con from pg_temp._hs order by loc + con desc limit game.param('hub_study_spokes')::int) q;

  -- each figure gets its own error
  with mine as (
    select case when r.origin = v_hub then r.dest else r.origin end as x, pl.network
      from public.routes r join public.route_plans pl on pl.route_id = r.id
     where r.airline_id = p_airline and r.status = 'open' and v_hub in (r.origin, r.dest)),
  fly as (
    select case when r.origin = v_hub then r.dest else r.origin end as x, count(distinct r.airline_id) as n
      from public.routes r where r.world_id = rw.id and r.status = 'open' and v_hub in (r.origin, r.dest)
       and exists (select 1 from public.rotations ro where ro.route_id = r.id)
     group by 1),
  e as (select x, greatest(0.3, 1 + v_w / 2 * game.rand_normal()) as e1, greatest(0.3, 1 + v_w / 2 * game.rand_normal()) as e2 from pg_temp._hs)
  select jsonb_build_object(
    'hub', v_hub, 'game_day', v_day, 'cost_inr', v_cost, 'width', v_w,
    'spokes', (select coalesce(jsonb_agg(jsonb_build_object(
                  'x', s.x, 'km', round(s.km), 'intl', s.intl, 'own_wk', round(s.loc * e.e1), 'conn_wk', round(s.con * e.e2),
                  'carriers', coalesce(f.n, 0), 'yours', mi.x is not null, 'network', coalesce(mi.network, false),
                  'suggested', s.x = any (v_sug)) order by s.loc + s.con desc), '[]'::jsonb)
                 from (select * from pg_temp._hs order by loc + con desc limit game.param('hub_study_list')::int) s
                 join e on e.x = s.x
                 left join fly f on f.x = s.x
                 left join mine mi on mi.x = s.x),
    'markets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'a', p.a, 'b', p.b, 'conn_wk', round(p.wk * greatest(0.3, 1 + v_w / 2 * game.rand_normal())),
                  'detour', round(p.det::numeric, 2), 'nonstops', p.nn, 'outside', p.outside) order by p.wk desc), '[]'::jsonb)
                 from (select * from pg_temp._hp order by wk desc limit game.param('hub_study_markets')::int) p),
    'now', (select jsonb_build_object('spokes', count(*),
                     'conn_wk', round(coalesce((select sum(p.wk) from pg_temp._hp p
                                                 where p.a in (select x from mine) and p.b in (select x from mine)), 0)
                                      * greatest(0.3, 1 + v_w / 2 * game.rand_normal())))
              from mine),
    'suggested', jsonb_build_object('spokes', to_jsonb(v_sug),
                   'conn_wk', round(coalesce((select sum(p.wk) from pg_temp._hp p where p.a = any (v_sug) and p.b = any (v_sug)), 0)
                                    * greatest(0.3, 1 + v_w / 2 * game.rand_normal()))),
    'rivals', jsonb_build_object(
      'flying', (select count(distinct r.airline_id) from public.routes r
                  where r.world_id = rw.id and r.status = 'open' and r.airline_id <> p_airline and v_hub in (r.origin, r.dest)),
      'connecting', (select count(distinct r.airline_id) from public.routes r join public.route_plans pl on pl.route_id = r.id
                      where r.world_id = rw.id and r.status = 'open' and r.airline_id <> p_airline and v_hub in (r.origin, r.dest)
                        and pl.network)))
    into v_res;

  insert into public.hub_studies (airline_id, world_id, hub, game_day, cost_inr, result)
  values (p_airline, rw.id, v_hub, v_day, v_cost, v_res);
  return v_res;
end $$;
revoke all on function public.hub_study(uuid, text) from public, anon;
grant execute on function public.hub_study(uuid, text) to authenticated, service_role;

-- Computer-run airlines use the hub study like a player (0040): once a year from week bot_hub_first, when they have
-- bot_hub_min_cash in hand, a study of the
-- base with the most routes, then the best suggested route they do not fly opens, with the cabin of that base's
-- busiest group, at bot_min_weekly round trips; bot_balance fits it onto aircraft at the next quarter end.
create or replace function game.bot_hub(p_world uuid, p_week int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; g record; v_res jsonb; v_x text; v_route uuid; v_n int := 0; v_k int;
begin
  if p_week < game.param('bot_hub_first') or (p_week - game.param('bot_hub_first')::int) % game.param('bot_hub_weeks')::int <> 0 then
    return 0;
  end if;
  for al in select a.id, b.base from public.airlines a
              cross join lateral (select p.base from game.bot_plan p where p.airline_id = a.id and p.trips > 0
                                   group by p.base order by count(*) desc, p.base limit 1) b
             where a.world_id = p_world and a.is_ai and a.status = 'active'
               and (select f.cash_inr from public.airline_finance f where f.airline_id = a.id) >= game.param('bot_hub_min_cash') loop
    begin
      v_res := public.hub_study(al.id, al.base);
    exception when others then
      continue;
    end;
    select p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, t.range_km into g
      from game.bot_plan p join public.aircraft_types t on t.id = p.type_id
     where p.airline_id = al.id and p.base = al.base and p.trips > 0
     group by p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, t.range_km order by count(*) desc limit 1;
    continue when not found;
    v_k := 0;
    for v_x in select s ->> 'x' from jsonb_array_elements(v_res -> 'spokes') s
                where (s ->> 'suggested')::boolean and not (s ->> 'yours')::boolean and (s ->> 'km')::numeric <= g.range_km
                order by (s ->> 'own_wk')::numeric + (s ->> 'conn_wk')::numeric desc loop
      exit when v_k >= game.param('bot_hub_adds');
      begin
        v_route := public.open_route(al.id, al.base, v_x);
        insert into game.bot_plan (route_id, airline_id, trips, type_id, biz_rows, biz_pitch, econ_pitch, base, since_day)
        values (v_route, al.id, game.param('bot_min_weekly')::int, g.type_id, g.biz_rows, g.biz_pitch, g.econ_pitch, al.base,
                (select game_day from public.worlds where id = p_world));
        v_k := v_k + 1; v_n := v_n + 1;
      exception when others then
        null;
      end;
    end loop;
  end loop;
  return v_n;
end $$;

-- Computer-run airlines' network selling (from 0039), with their yearly hub study (0040).
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
  perform game.bot_hub(p_world, p_week);   -- 0040: once a year, a hub study and the best route it suggests
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
