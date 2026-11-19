-- Pilots (owner request, 19 Nov 2026; spec section 14.8). Pilots become a scarce resource with lead times, as in India in
-- 2025: each fleet family needs captains and first officers for the hours it flies; an airline short of crew cancels
-- flights. Pilots come from a world market (28 days), command upgrades (91 days), cadets (364 days) or, if the airline
-- allows it, foreign captains at a premium. They resign more when paid below the market or below a rival, and serve a
-- notice period (captains 364 days, first officers 182). Every scarce number scales with the world's places (principle 7).
-- Also: admin_set_places ties a world's places and demand together. Adds and updates only. This file is what went live
-- through the Supabase tool on 19 Nov 2026; the day engine, administration and seeding follow in 0014.

insert into public.game_params (key, num, note) values
('pilot_bh_day', 2.4, 'block hours one pilot flies a day on average under the duty-time rules'),
('pilot_reserve', 0.15, 'extra pilots needed for leave, training and sickness'),
('pilot_aug_bh', 8, 'flights longer than this many block hours carry an extra pilot'),
('pilot_aug_mult', 1.5, 'pilots per flight deck seat on those flights'),
('pilot_plan_util', 0.7, 'share of its daily flying window an aircraft with no flights yet is assumed to fly, when planning crews'),
('pilot_plan_days', 63, 'aircraft arriving within this many days count when hiring'),
('pilot_join_days', 28, 'days for a pilot hired from the market to join'),
('pilot_hire_max_qtr', 60, 'most pilots of one rank and fleet family an airline can hire from the market in any 91 days'),
('pilot_expat_mult', 1.8, 'pay of a foreign captain against the market rate'),
('pilot_expat_days', 56, 'days for a foreign captain to join'),
('pilot_upgrade_days', 91, 'command training, first officer to captain'),
('pilot_upgrade_inr', 1000000, 'cost of one command upgrade'),
('pilot_upgrade_share_qtr', 0.10, 'most first officers an airline can put into command training in any 91 days, as a share (at least one)'),
('pilot_cadet_days', 364, 'days from cadet to first officer'),
('pilot_cadet_inr', 3000000, 'cost of training one cadet'),
('pilot_cadets_max_qtr', 60, 'most cadets an airline can start a quarter'),
('pilot_notice_c', 364, 'notice a captain serves before leaving'),
('pilot_notice_f', 182, 'notice a first officer serves before leaving'),
('pilot_quit_year', 0.05, 'share of pilots who resign in a year at market pay'),
('pilot_quit_pay_k', 5, 'resignations scale by exp(-k x (pay level - 1))'),
('pilot_quit_poach_k', 4, 'and by exp(k x (best rival pay level - own)) when a rival pays more'),
('pilot_quit_stretch', 1.5, 'resignations multiply by this while an airline has fewer pilots than it needs'),
('pilot_quit_trouble', 2, 'and by this while its cash is below zero'),
('pilot_pool_start_mult', 2.5, 'pilots in the market at world start, against the target'),
('pilot_pool_in_qtr', 0.25, 'newly qualified pilots entering the market each quarter, as a share of the target'),
('pilot_pool_out_qtr', 0.25, 'pilots leaving the market each quarter (abroad, other work), as a share of the pool'),
('pilot_pay_k', 0.6, 'market pay rises by k x shortage^2, shortage = 1 - captains in the market / target'),
('pilot_pay_smooth', 0.03, 'share of the gap market pay closes each day'),
('pilot_pay_min', 0.8, 'lowest pay level an airline can set, against the market'),
('pilot_pay_max', 1.5, 'highest pay level'),
('pilot_buffer_max', 0.4, 'most spare pilots an airline can keep, as a share of need'),
('pilot_furlough_slack', 1.25, 'pilots above need x (1 + spare) x this are let go'),
('pilot_severance_days', 91, 'days of pay owed to each pilot let go'),
('event_duty_prob_day', 0.0011, 'chance a day that the regulator tightens duty-time rules (at most once a season)'),
('event_duty_mult', 0.9, 'hours a pilot may fly after the change, against before'),
('event_duty_notice', 91, 'days between the announcement and the change')
on conflict (key) do update set num = excluded.num, note = excluded.note;

create table public.pilot_families (       -- reference: pilots fly one family; every number (G)
  id            text primary key,
  name          text not null,
  sort          int not null,
  pay_c_inr_day numeric not null,           -- captain's pay a day at a market pay index of 1
  pay_f_inr_day numeric not null,           -- first officer's
  pool_c        numeric not null,           -- captains in the world market at its target, per airline place
  pool_f        numeric not null            -- first officers
);
insert into public.pilot_families values
('ATR',  'ATR 72',      1, 15300,  7000,  4,  6),
('A320', 'A320 family', 2, 19800,  9000, 20, 30),
('A350', 'A350',        3, 26100, 11900,  3,  4);

alter table public.aircraft_types add column pilot_family text references public.pilot_families;
update public.aircraft_types set pilot_family = case id when 'AT76' then 'ATR' when 'A359' then 'A350' else 'A320' end;

alter table public.worlds add column pilots boolean not null default true;   -- false: the flat pilot cost per aircraft of 0004

alter table public.airline_finance
  add column pilot_pay numeric not null default 1,         -- pay level against the market
  add column pilot_buffer numeric not null default 0.1,    -- spare pilots to keep, share of need
  add column pilot_cadets int not null default 0,          -- cadets to start a quarter
  add column pilot_expats boolean not null default false;  -- hire foreign captains when the market runs short

create table public.airline_pilots (       -- private: pilots on strength by fleet family
  airline_id uuid not null references public.airlines on delete cascade,
  family     text not null references public.pilot_families,
  captains   int not null default 0,       -- including foreign captains and anyone serving notice
  fos        int not null default 0,       -- first officers
  expats     int not null default 0,       -- foreign captains (part of captains)
  need       int not null default 0,       -- per rank, for aircraft flying or arriving soon, with reserve
  primary key (airline_id, family)
);

create table public.pilot_moves (          -- private: pilots joining or leaving later
  id         bigint generated always as identity primary key,
  airline_id uuid not null references public.airlines on delete cascade,
  world_id   uuid not null references public.worlds on delete cascade,
  family     text not null references public.pilot_families,
  rank       text not null check (rank in ('c', 'f')),
  kind       text not null check (kind in ('hire', 'expat', 'cadet', 'upgrade', 'leave', 'release')),
  n          int not null check (n > 0),
  start_day  int not null,
  due_day    int not null,
  done       boolean not null default false
);
create index pilot_moves_due_idx on public.pilot_moves (world_id, done, due_day);
create index pilot_moves_airline_idx on public.pilot_moves (airline_id, family);

create table public.pilot_market (         -- public: pilots looking for work in a world, and the market pay
  world_id  uuid not null references public.worlds on delete cascade,
  family    text not null references public.pilot_families,
  captains  numeric not null,
  fos       numeric not null,
  pay_index numeric not null default 1,
  primary key (world_id, family)
);

alter table public.pilot_families enable row level security;
alter table public.pilot_market enable row level security;
alter table public.airline_pilots enable row level security;
alter table public.pilot_moves enable row level security;
grant select on public.pilot_families, public.pilot_market, public.airline_pilots, public.pilot_moves to authenticated;
create policy read_all on public.pilot_families for select to authenticated using (true);
create policy read_all on public.pilot_market for select to authenticated using (true);
create policy read_own on public.airline_pilots for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));
create policy read_own on public.pilot_moves for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

-- Hours one pilot may fly a day on a game day, after any tightening of the duty-time rules that has started by then.
create or replace function game.pilot_bh(p_world uuid, p_day int) returns numeric
language sql stable set search_path = '' as $$
  select game.param('pilot_bh_day') * coalesce(exp(sum(ln((e.payload ->> 'mult')::numeric))), 1)
    from public.events e where e.world_id = p_world and e.kind = 'duty_rules' and e.starts_day <= p_day
$$;

-- Block hours a day each airline's dry fleet needs crews for, by family: aircraft in service plus those arriving within
-- p_horizon days. An aircraft with flights counts what it flies (long flights count extra pilots); one without is planned
-- at pilot_plan_util of its daily flying window. Wet-leased aircraft bring their own crew.
create or replace function game.pilot_need(p_world uuid, p_day int, p_horizon int)
returns table (airline_id uuid, family text, bh numeric)
language sql stable set search_path = '' as $$
  select ac.airline_id, t.pilot_family, sum(coalesce(s.bh, t.day_window_h * game.param('pilot_plan_util')))
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id and tm.holding <> 'wet'
    join public.aircraft_types t on t.id = ac.type_id
    left join (select ro.aircraft_id,
                      sum(2 * ro.weekly_trips / 7.0 * b.h * case when b.h > game.param('pilot_aug_bh') then game.param('pilot_aug_mult') else 1 end) as bh
                 from public.rotations ro
                 join public.routes r on r.id = ro.route_id and r.status = 'open' and r.world_id = p_world
                 join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
                 join public.aircraft x on x.id = ro.aircraft_id
                 join public.aircraft_types t2 on t2.id = x.type_id
                 cross join lateral (select m.km::numeric / t2.cruise_kmh + t2.block_offset_h as h) b
                group by ro.aircraft_id) s on s.aircraft_id = ac.id
   where ac.world_id = p_world and ac.airline_id is not null
     and (ac.status in ('active', 'grounded', 'refit') or (ac.status = 'delivering' and ac.available_day <= p_day + p_horizon))
   group by ac.airline_id, t.pilot_family
$$;

create or replace function game.pilot_market_init(p_world uuid) returns void
language sql set search_path = '' as $$
  insert into public.pilot_market (world_id, family, captains, fos)
  select w.id, f.id, round(f.pool_c * w.max_airlines * game.param('pilot_pool_start_mult')),
         round(f.pool_f * w.max_airlines * game.param('pilot_pool_start_mult'))
    from public.worlds w cross join public.pilot_families f
   where w.id = p_world
  on conflict (world_id, family) do nothing
$$;

-- Crews for airlines already flying when pilots start: the computer-run airlines on their first day, and every airline of a
-- world that was running before migration 0013. They get their need plus 10%, outside the market, like their aircraft.
create or replace function game.pilot_seed(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare v_pbh numeric := game.pilot_bh(p_world, p_day); v_res numeric := game.param('pilot_reserve');
begin
  if not (select pilots from public.worlds where id = p_world) then return; end if;
  perform game.pilot_market_init(p_world);
  insert into public.airline_pilots (airline_id, family, captains, fos, need)
  select n.airline_id, n.family, ceil(x.need * 1.1), ceil(x.need * 1.1), x.need
    from game.pilot_need(p_world, p_day, game.param('pilot_plan_days')::int) n
    cross join lateral (select ceil(n.bh / v_pbh * (1 + v_res))::int as need) x
  on conflict (airline_id, family) do update
    set captains = greatest(public.airline_pilots.captains, excluded.captains),
        fos = greatest(public.airline_pilots.fos, excluded.fos), need = excluded.need;
  update public.airline_finance fin set pilot_expats = true
    from public.airlines al where al.id = fin.airline_id and al.world_id = p_world and al.is_ai;
end $$;

-- One day of pilots, run before the day's flying: duty-rule events, joiners and leavers, the market, need, resignations,
-- hiring (best payers first), cadets and letting surplus pilots go.
create or replace function game.day_pilots(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype; rec record; fam record; rk text;
  v_res numeric := game.param('pilot_reserve'); v_plan int := game.param('pilot_plan_days')::int;
  v_pbh numeric; v_m numeric; v_n int; v_e int; v_take int; v_gap int; v_pool numeric; v_cost numeric; v_target int;
begin
  select * into rw from public.worlds where id = p_world;
  if not rw.pilots then return; end if;
  perform game.pilot_market_init(p_world);

  -- the regulator tightens duty-time rules, announced ahead, at most once a season
  if random() < game.param('event_duty_prob_day') and p_day + game.param('event_duty_notice') < rw.season_days
     and not exists (select 1 from public.events where world_id = p_world and kind = 'duty_rules') then
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'duty_rules', p_day, p_day + game.param('event_duty_notice')::int, null,
            jsonb_build_object('mult', game.param('event_duty_mult')));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', format('The regulator tightens pilot duty-time rules from day %s: each pilot may fly about %s%% fewer hours. Airlines without spare pilots will cancel flights.',
            p_day + game.param('event_duty_notice')::int, round((1 - game.param('event_duty_mult')) * 100)));
  end if;

  -- pilots joining, promoted or leaving today
  for rec in select * from public.pilot_moves where world_id = p_world and not done and due_day <= p_day order by id loop
    insert into public.airline_pilots (airline_id, family) values (rec.airline_id, rec.family) on conflict do nothing;
    if rec.kind = 'leave' then
      update public.airline_pilots
         set captains = captains - case when rec.rank = 'c' then least(rec.n, captains - expats) else 0 end,
             fos = fos - case when rec.rank = 'f' then least(rec.n, fos) else 0 end
       where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market
         set captains = captains + case when rec.rank = 'c' then rec.n else 0 end, fos = fos + case when rec.rank = 'f' then rec.n else 0 end
       where world_id = p_world and family = rec.family;
    elsif rec.kind = 'upgrade' then
      update public.airline_pilots set captains = captains + least(rec.n, fos), fos = fos - least(rec.n, fos)
       where airline_id = rec.airline_id and family = rec.family;
    else
      update public.airline_pilots
         set captains = captains + case when rec.rank = 'c' then rec.n else 0 end,
             fos = fos + case when rec.rank = 'f' then rec.n else 0 end,
             expats = expats + case when rec.kind = 'expat' then rec.n else 0 end
       where airline_id = rec.airline_id and family = rec.family;
    end if;
    update public.pilot_moves set done = true where id = rec.id;
  end loop;
  delete from public.pilot_moves where world_id = p_world and done and due_day < p_day - 182;

  -- the market: newly qualified pilots arrive, some leave for other work; market pay follows the captain shortage
  update public.pilot_market pm
     set captains = pm.captains * (1 - game.param('pilot_pool_out_qtr') / 91) + f.pool_c * rw.max_airlines * game.param('pilot_pool_in_qtr') / 91,
         fos = pm.fos * (1 - game.param('pilot_pool_out_qtr') / 91) + f.pool_f * rw.max_airlines * game.param('pilot_pool_in_qtr') / 91,
         pay_index = round(pm.pay_index + game.param('pilot_pay_smooth')
                     * (1 + game.param('pilot_pay_k') * power(1 - least(1, pm.captains / (f.pool_c * rw.max_airlines)), 2) - pm.pay_index), 4)
    from public.pilot_families f
   where pm.world_id = p_world and f.id = pm.family;

  -- what each airline needs, planned at the duty-time rules that will apply when its next aircraft arrive
  v_pbh := game.pilot_bh(p_world, p_day + v_plan);
  update public.airline_pilots ap set need = 0
    from public.airlines al where al.id = ap.airline_id and al.world_id = p_world and ap.need <> 0;
  insert into public.airline_pilots (airline_id, family, need)
  select n.airline_id, n.family, ceil(n.bh / v_pbh * (1 + v_res))
    from game.pilot_need(p_world, p_day, v_plan) n
    join public.airlines al on al.id = n.airline_id and al.status = 'active'
  on conflict (airline_id, family) do update set need = excluded.need;

  -- resignations: pay below the market or below a rival, too few colleagues, an airline in trouble
  for rec in
    select ap.airline_id, ap.family, ap.captains, ap.fos, ap.expats, ap.need, fin.pilot_pay, fin.cash_inr, al.is_ai, pf.name,
           (select max(f2.pilot_pay) from public.airline_finance f2 join public.airlines a2 on a2.id = f2.airline_id
             where a2.world_id = p_world and a2.status = 'active' and a2.id <> ap.airline_id) as best,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'c'), 0) as out_c,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'f'), 0) as out_f
      from public.airline_pilots ap
      join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
      join public.airline_finance fin on fin.airline_id = ap.airline_id
      join public.pilot_families pf on pf.id = ap.family
     where ap.captains + ap.fos > 0
  loop
    v_m := game.param('pilot_quit_year') / 364
           * exp(-game.param('pilot_quit_pay_k') * (rec.pilot_pay - 1))
           * exp(game.param('pilot_quit_poach_k') * greatest(0, coalesce(rec.best, 0) - rec.pilot_pay))
           * case when least(rec.captains, rec.fos) < rec.need then game.param('pilot_quit_stretch') else 1 end
           * case when rec.cash_inr < 0 then game.param('pilot_quit_trouble') else 1 end;
    foreach rk in array array['c', 'f'] loop
      v_n := floor(greatest(0, case when rk = 'c' then rec.captains - rec.expats - rec.out_c else rec.fos - rec.out_f end) * v_m + random())::int;
      if v_n > 0 then
        insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
        values (rec.airline_id, p_world, rec.family, rk, 'leave', v_n, p_day, p_day + game.param('pilot_notice_' || rk)::int);
        if not rec.is_ai then
          insert into public.news (world_id, game_day, airline_id, kind, body, private)
          values (p_world, p_day, rec.airline_id, 'pilots',
                  v_n || ' ' || rec.name || ' ' || case when rk = 'c' then case when v_n = 1 then 'captain has' else 'captains have' end
                                                         else case when v_n = 1 then 'first officer has' else 'first officers have' end end
                  || ' resigned. They keep flying until day ' || (p_day + game.param('pilot_notice_' || rk)::int) || ', then leave.'
                  || case when coalesce(rec.best, 0) > rec.pilot_pay then ' Another airline pays more.' else '' end, true);
        end if;
      end if;
    end loop;
  end loop;

  -- hiring up to need x (1 + spare): the market first, best payers first; captains next from command upgrades of the
  -- airline's own first officers; then foreign captains if the airline allows them
  for fam in select id, name from public.pilot_families order by sort loop
    foreach rk in array array['c', 'f'] loop
      select case when rk = 'c' then captains else fos end into v_pool from public.pilot_market where world_id = p_world and family = fam.id;
      for rec in
        select ap.airline_id, fin.pilot_expats, ap.captains, ap.fos, ceil(ap.need * (1 + fin.pilot_buffer))::int as target,
               coalesce(sum(mv.n) filter (where not mv.done and mv.rank = rk and mv.kind in ('hire', 'expat', 'cadet')), 0)
                 + coalesce(sum(mv.n) filter (where not mv.done and mv.kind = 'upgrade'), 0) * case when rk = 'c' then 1 else -1 end
                 - coalesce(sum(mv.n) filter (where not mv.done and mv.rank = rk and mv.kind = 'leave'), 0) as pending,
               coalesce(sum(mv.n) filter (where mv.kind = 'hire' and mv.rank = rk and mv.start_day > p_day - 91), 0) as hired_qtr,
               coalesce(sum(mv.n) filter (where mv.kind = 'upgrade' and mv.start_day > p_day - 91), 0) as upg_qtr,
               coalesce(sum(mv.n) filter (where not mv.done and mv.kind = 'upgrade'), 0) as upg_now,
               coalesce(sum(mv.n) filter (where not mv.done and mv.rank = 'f' and mv.kind = 'leave'), 0) as out_f
          from public.airline_pilots ap
          join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
          join public.airline_finance fin on fin.airline_id = ap.airline_id
          left join public.pilot_moves mv on mv.airline_id = ap.airline_id and mv.family = ap.family
         where ap.family = fam.id and ap.need > 0
         group by ap.airline_id, fin.pilot_expats, ap.captains, ap.fos, ap.need, fin.pilot_buffer, fin.pilot_pay
         order by fin.pilot_pay desc, random()
      loop
        v_gap := rec.target - case when rk = 'c' then rec.captains else rec.fos end - rec.pending;
        continue when v_gap <= 0;
        v_take := least(v_gap, floor(v_pool)::int, greatest(0, game.param('pilot_hire_max_qtr')::int - rec.hired_qtr));
        if v_take > 0 then
          insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
          values (rec.airline_id, p_world, fam.id, rk, 'hire', v_take, p_day, p_day + game.param('pilot_join_days')::int);
          v_pool := v_pool - v_take; v_gap := v_gap - v_take;
        end if;
        if rk = 'c' and v_gap > 0 then
          v_n := least(v_gap, ceil((rec.fos - rec.out_f - rec.upg_now) * game.param('pilot_upgrade_share_qtr'))::int - rec.upg_qtr);
          if v_n > 0 then
            insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
            values (rec.airline_id, p_world, fam.id, 'c', 'upgrade', v_n, p_day, p_day + game.param('pilot_upgrade_days')::int);
            v_cost := v_n * game.param('pilot_upgrade_inr');
            perform game.book(rec.airline_id, p_day, -v_cost, 'training',
                              format('Command training for %s %s first officer%s', v_n, fam.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
            v_gap := v_gap - v_n;
          end if;
          if v_gap > 0 and rec.pilot_expats then
            insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
            values (rec.airline_id, p_world, fam.id, 'c', 'expat', v_gap, p_day, p_day + game.param('pilot_expat_days')::int);
          end if;
        end if;
      end loop;
      update public.pilot_market set captains = case when rk = 'c' then v_pool else captains end, fos = case when rk = 'f' then v_pool else fos end
       where world_id = p_world and family = fam.id;
    end loop;
  end loop;

  -- cadets start through the quarter at the airline's rate, for its biggest fleet family
  for rec in
    select fin.airline_id, fin.pilot_cadets,
           coalesce((select ap.family from public.airline_pilots ap where ap.airline_id = fin.airline_id
                      order by ap.need desc, ap.family = 'A320' desc limit 1), 'A320') as family
      from public.airline_finance fin
      join public.airlines al on al.id = fin.airline_id and al.world_id = p_world and al.status = 'active'
     where fin.pilot_cadets > 0
  loop
    v_n := floor(p_day * rec.pilot_cadets / 91.0)::int - floor((p_day - 1) * rec.pilot_cadets / 91.0)::int;
    if v_n > 0 then
      insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
      values (rec.airline_id, p_world, rec.family, 'f', 'cadet', v_n, p_day, p_day + game.param('pilot_cadet_days')::int);
      v_cost := v_n * game.param('pilot_cadet_inr');
      perform game.book(rec.airline_id, p_day, -v_cost, 'training', format('Training for %s cadet%s', v_n, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
  end loop;

  -- pilots well above need are let go, with severance; foreign captains go first, local pilots return to the market
  for rec in
    select ap.airline_id, ap.family, ap.captains, ap.fos, ap.expats, ap.need, fin.pilot_buffer, fin.pilot_pay, pm.pay_index,
           pf.pay_c_inr_day, pf.pay_f_inr_day, pf.name, al.is_ai,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'c'), 0) as out_c,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.rank = 'f' and (mv.kind = 'leave' or mv.kind = 'upgrade')), 0) as out_f
      from public.airline_pilots ap
      join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
      join public.airline_finance fin on fin.airline_id = ap.airline_id
      join public.pilot_market pm on pm.world_id = p_world and pm.family = ap.family
      join public.pilot_families pf on pf.id = ap.family
     where ap.captains + ap.fos > 0
  loop
    v_target := ceil(rec.need * (1 + rec.pilot_buffer) * game.param('pilot_furlough_slack'))::int;
    v_n := rec.captains - rec.out_c - v_target;
    if v_n > 0 then
      v_e := least(v_n, rec.expats);
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_c_inr_day
                      * (v_e * game.param('pilot_expat_mult') + (v_n - v_e) * rec.pilot_pay));
      update public.airline_pilots set captains = captains - v_n, expats = expats - v_e where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set captains = captains + (v_n - v_e) where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s captain%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
    v_n := rec.fos - rec.out_f - v_target;
    if v_n > 0 then
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_f_inr_day * rec.pilot_pay * v_n);
      update public.airline_pilots set fos = fos - v_n where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set fos = fos + v_n where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s first officer%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
  end loop;
end $$;

create or replace function public.set_pilot_policy(p_airline uuid, p_pay numeric, p_buffer numeric, p_cadets int, p_expats boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform game.actor(p_airline, false);
  if p_pay is null or p_pay < game.param('pilot_pay_min') or p_pay > game.param('pilot_pay_max') then
    raise exception 'Pilot pay must be between % and % times the market rate', game.param('pilot_pay_min'), game.param('pilot_pay_max');
  end if;
  if p_buffer is null or p_buffer < 0 or p_buffer > game.param('pilot_buffer_max') then
    raise exception 'Spare pilots must be between 0 and % of need', game.param('pilot_buffer_max');
  end if;
  if p_cadets is null or p_cadets < 0 or p_cadets > game.param('pilot_cadets_max_qtr') then
    raise exception 'Cadets a quarter must be between 0 and %', game.param('pilot_cadets_max_qtr');
  end if;
  update public.airline_finance
     set pilot_pay = round(p_pay, 2), pilot_buffer = round(p_buffer, 2), pilot_cadets = p_cadets, pilot_expats = coalesce(p_expats, false)
   where airline_id = p_airline;
  return jsonb_build_object('pay', round(p_pay, 2), 'buffer', round(p_buffer, 2), 'cadets', p_cadets, 'expats', coalesce(p_expats, false));
end $$;

-- Principle 7: a world's places set its demand (demand_scale = places / 50) and, through max_airlines, its lessor pool,
-- delivery slots, pilot market and airport capacity. Any change before the start; only up once it is running.
create or replace function public.admin_set_places(p_world uuid, p_places int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_players int;
begin
  perform game.require_admin();
  if p_places is null or p_places < 2 or p_places > 200 then raise exception 'Choose between 2 and 200 places'; end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  if w.status <> 'setup' and p_places < w.max_airlines then raise exception 'Once a world has started, places can only go up'; end if;
  select count(*) into v_players from public.airlines where world_id = p_world and not is_ai;
  if p_places < v_players then raise exception 'This world already has % airlines', v_players; end if;
  update public.worlds set max_airlines = p_places, demand_scale = round(p_places / 50.0, 3) where id = p_world;
  -- pilots for the new places join the market at once; aircraft follow through the quarterly lessor refill and delivery slots
  update public.pilot_market pm
     set captains = pm.captains + f.pool_c * greatest(0, p_places - w.max_airlines), fos = pm.fos + f.pool_f * greatest(0, p_places - w.max_airlines)
    from public.pilot_families f where pm.world_id = p_world and f.id = pm.family;
  if w.status <> 'setup' then
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, w.game_day, 'world', format('The world grows to %s places: more travellers, aircraft to lease and order, pilots and airport capacity.', p_places));
  end if;
  return jsonb_build_object('places', p_places, 'demand_scale', round(p_places / 50.0, 3));
end $$;
