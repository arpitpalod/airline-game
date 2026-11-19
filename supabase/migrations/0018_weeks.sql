-- Migration 0018: the week is the game's unit (spec sections 3 and 14.12). Time moves a week at a time: the clock is set in
-- hours per game week, and the scheduler only ever runs whole weeks (inside a week the engine still works through its
-- seven days, so every rule keeps its daily form). A world opens with a pre-launch: 13 weeks that pass in one hour of real
-- time, with nothing flying; first flights are on day 92 (week 14). An airline founded after that flies from the start of
-- the week four weeks later. Costs start with an airline's first flights. Calendar: day 1 is Wed 1 Jan 3000.
-- Test World is replaced by a fresh one; World 1 (still in setup) moves to 4-hour weeks with a pre-launch.

insert into public.game_params (key, num, note) values
('late_join_days', 28, 'an airline founded after first flights starts flying at the start of the week this many days later'),
('wet_lead_days', 28, 'a wet-leased aircraft arrives this many days after it is ordered'),
('tick_max_days', 28, 'most game days processed per world per scheduler run (whole weeks)'),
('season_start_month', 1, 'the month of game day 1: January (day 1 is 1 Jan 3000)')
on conflict (key) do update set num = excluded.num, note = excluded.note;

alter table public.worlds
  add column prelaunch_weeks int not null default 13 check (prelaunch_weeks between 0 and 26),
  add column prelaunch_minutes numeric not null default 60 check (prelaunch_minutes > 0),
  add column start_date date not null default '3000-01-01';
alter table public.worlds alter column speed set default 42;   -- game days per real day: a game week in 4 hours
comment on column public.worlds.speed is 'game days per real day after the pre-launch: 168 / hours per game week';

alter table public.airlines add column first_flight_day int not null default 1;

-- An airline flies from its world's first flight day. A player's airline founded after the first flights flies from the
-- start of the week four weeks on. Computer-run airlines always fly from the world's first flight day.
create or replace function game.airline_first_flight() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  w public.worlds%rowtype;
  v_ffd int;
begin
  select * into w from public.worlds where id = new.world_id;
  v_ffd := w.prelaunch_weeks * 7 + 1;
  if not new.is_ai and w.status in ('running', 'paused') and w.game_day >= v_ffd then
    new.first_flight_day := ceil((w.game_day + game.param('late_join_days')) / 7.0)::int * 7 + 1;
  else
    new.first_flight_day := v_ffd;
  end if;
  return new;
end $$;
create trigger airlines_first_flight before insert on public.airlines for each row execute function game.airline_first_flight();

-- Week numbers: week 1 is days 1 to 7. A week starts on day 1, 8, 15 and so on.
create or replace function game.week_of(p_day int) returns int language sql immutable as $$ select (greatest(p_day, 1) - 1) / 7 + 1 $$;
create or replace function game.week_start_from(p_day int) returns int language sql immutable as $$
  select case when p_day <= 1 then p_day else ceil((p_day - 1) / 7.0)::int * 7 + 1 end $$;

-- Nothing moves for a day: an aircraft that arrives, comes back from a refit or a grounding, or returns to the lessors'
-- pool does so at the start of a week (day 1, 8, 15 and so on), rounded up.
create or replace function game.aircraft_week_start() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.available_day := game.week_start_from(new.available_day);
  return new;
end $$;
create trigger aircraft_week_start before insert or update of available_day on public.aircraft
  for each row execute function game.aircraft_week_start();

-- The clock. Before the pre-launch ends, game days pass at prelaunch_weeks x 7 per prelaunch_minutes; after it, at speed
-- game days per real day. Only whole weeks are due.
create or replace function game.clock_day(w public.worlds, p_seconds numeric) returns numeric
language sql immutable set search_path = '' as $$
  select case when w.prelaunch_weeks > 0 and p_seconds < w.prelaunch_minutes * 60
              then p_seconds * w.prelaunch_weeks * 7 / (w.prelaunch_minutes * 60)
              else w.prelaunch_weeks * 7
                   + (p_seconds - case when w.prelaunch_weeks > 0 then w.prelaunch_minutes * 60 else 0 end) * w.speed / 86400 end
$$;
-- and back: real seconds from the start to the end of game day p_day
create or replace function game.clock_seconds(w public.worlds, p_day numeric) returns numeric
language sql immutable set search_path = '' as $$
  select case when w.prelaunch_weeks > 0 and p_day < w.prelaunch_weeks * 7
              then p_day * w.prelaunch_minutes * 60 / (w.prelaunch_weeks * 7)
              else case when w.prelaunch_weeks > 0 then w.prelaunch_minutes * 60 else 0 end
                   + (p_day - w.prelaunch_weeks * 7) * 86400 / w.speed end
$$;

create or replace function game.due_day(p_world uuid) returns int
language sql stable set search_path = '' as $$
  select least(w.season_days,
               7 * floor(game.clock_day(w, extract(epoch from now() - w.started_at)::numeric - w.paused_seconds) / 7)::int)
  from public.worlds w where w.id = p_world and w.status = 'running'
$$;

create or replace function game.tick() returns int
language plpgsql set search_path = '' as $$
declare
  rec record;
  v_due int; v_done int := 0; v_n int;
  v_max int := 7 * greatest(1, game.param('tick_max_days')::int / 7);   -- whole weeks
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

-- Hours per game week (after the pre-launch). The clock restarts at the processed day, as if it had always run at this pace.
create or replace function public.admin_set_week_hours(p_world uuid, p_hours numeric) returns numeric
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_speed numeric;
begin
  perform game.require_admin();
  if p_hours is null or p_hours < 0.25 or p_hours > 168 then
    raise exception 'Choose between 15 minutes and 7 days for a game week';
  end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  v_speed := round(168 / p_hours, 4);
  w.speed := v_speed;
  if w.status in ('running', 'paused') then
    update public.worlds
       set speed = v_speed, paused_seconds = 0,
           started_at = now() - make_interval(secs => game.clock_seconds(w, w.game_day)),
           paused_at = case when w.status = 'paused' then now() else null end
     where id = p_world;
  else
    update public.worlds set speed = v_speed where id = p_world;
  end if;
  insert into public.news (world_id, game_day, kind, body, private)
  values (p_world, w.game_day, 'world', format('The clock changes: a game week now takes %s of real time.',
          case when p_hours < 1 then round(p_hours * 60) || ' minutes' when p_hours = 1 then '1 hour' else round(p_hours, 1) || ' hours' end), false);
  return v_speed;
end $$;

-- Kept for older callers: minutes per game day, as hours per week.
create or replace function public.admin_set_speed(p_world uuid, p_minutes_per_day numeric) returns numeric
language sql security definer set search_path = '' as $$
  select public.admin_set_week_hours(p_world, p_minutes_per_day * 7 / 60)
$$;

-- Redefined from 0014: nothing is priced and no quarter is reported before a world's first flights.
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
  if v_day >= v_ffd then perform game.bot_prices(p_world, v_day); end if;
  perform game.day_pilots(p_world, v_day);
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

-- Redefined from 0007: the starting wet lease flies from the airline's first flights.
create or replace function public.found_airline(p_invite text, p_name text, p_code text, p_base text,
                                                p_display_name text default null, p_livery jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rp public.airports%rowtype;
  v_uid uuid := auth.uid();
  v_name text := trim(p_name);
  v_code text := upper(trim(p_code));
  v_day int;
  v_id uuid;
  v_type text;
  w record;
begin
  if v_uid is null and not game.is_server() then raise exception 'Sign in first'; end if;
  select x.* into rw from public.world_secrets s join public.worlds x on x.id = s.world_id
   where s.invite_code = lower(trim(p_invite)) for update of x;
  if not found then raise exception 'That invite code is not valid'; end if;
  if rw.status = 'ended' then raise exception 'This world has ended'; end if;
  v_day := rw.game_day + 1;
  if (select count(*) from public.airlines where world_id = rw.id and not is_ai) >= rw.max_airlines then
    raise exception 'This world is full';
  end if;
  if v_uid is not null and exists (select 1 from public.airlines where world_id = rw.id and user_id = v_uid) then
    raise exception 'You already have an airline in this world';
  end if;
  if v_name is null or length(v_name) not between 3 and 30 then raise exception 'Airline name must be 3 to 30 characters'; end if;
  if v_code is null or v_code !~ '^[A-Z0-9]{2,3}$' then raise exception 'Airline code must be 2 or 3 letters or digits'; end if;
  if exists (select 1 from public.airlines where world_id = rw.id and (lower(name) = lower(v_name) or code = v_code))
     or exists (select 1 from public.bot_airlines where lower(name) = lower(v_name) or code = v_code) then
    raise exception 'That name or code is already taken in this world';
  end if;
  select * into rp from public.airports where iata = upper(trim(p_base));
  if not found or not rp.is_india then raise exception 'Bases can only be opened at Indian airports'; end if;
  if rp.opens_day > v_day then raise exception '% airport has not opened yet', rp.city; end if;
  if length(coalesce(p_livery, '{}')::text) > 2000 then raise exception 'That livery is too large'; end if;

  if v_uid is not null then
    insert into public.profiles (user_id, display_name)
    values (v_uid, left(coalesce(nullif(trim(p_display_name), ''), v_name), 40)) on conflict (user_id) do nothing;
  end if;
  insert into public.airlines (world_id, user_id, name, code, livery, created_day)
  values (rw.id, v_uid, v_name, v_code, coalesce(p_livery, '{}'), v_day) returning id into v_id;
  insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr)
  values (v_id, 0, game.param('credit_limit_inr'));
  perform game.book(v_id, v_day, game.param('start_cash_inr'), 'equity', 'Founding equity');
  insert into public.bases (airline_id, iata, opened_day) values (v_id, rp.iata, v_day);
  insert into public.news (world_id, game_day, airline_id, kind, body)
  values (rw.id, v_day, v_id, 'founded', v_name || ' has been founded, based at ' || rp.city || '.');

  select t.id into v_type from public.aircraft_types t
   where t.starter_rank is not null and t.runway_class <= rp.runway_class order by t.starter_rank limit 1;
  if v_type is not null then
    for i in 1..game.param('starter_aircraft')::int loop
      select * into w from game.add_wet(v_id, rw.id, v_type, rp.iata, v_day, v_day);
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      select rw.id, v_day, v_id, 'fleet', 'A wet-leased ' || t.name || ', ' || w.o_reg || ', is ready at ' || rp.iata
             || ' and flies from your first flights in week ' || game.week_of(al.first_flight_day) || '. It costs $' || w.o_rate
             || ' a block hour, at least ' || game.param('wet_min_hours_day') || ' hours a day.', true
        from public.aircraft_types t, public.airlines al where t.id = v_type and al.id = v_id;
    end loop;
  end if;
  return v_id;
end $$;

-- Redefined from 0013: pilot news names weeks; a change of duty rules starts at the start of a week.
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
    values (p_world, 'duty_rules', p_day, game.week_start_from(p_day + game.param('event_duty_notice')::int), null,
            jsonb_build_object('mult', game.param('event_duty_mult')));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', format('The regulator tightens pilot duty-time rules from week %s: each pilot may fly about %s%% fewer hours. Airlines without spare pilots will cancel flights.',
            game.week_of(game.week_start_from(p_day + game.param('event_duty_notice')::int)), round((1 - game.param('event_duty_mult')) * 100)));
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
                  || ' resigned. They keep flying until week ' || game.week_of(p_day + game.param('pilot_notice_' || rk)::int) || ', then leave.'
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

-- Redefined from 0017: an airline's aircraft fly, and its costs start, from its first flight day.
create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
  v_pbh numeric; v_res numeric := game.param('pilot_reserve'); v_aug_bh numeric := game.param('pilot_aug_bh'); v_aug numeric := game.param('pilot_aug_mult');
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
    loan_rate_year numeric, anc_biz_share numeric, slot_ref_seats numeric);

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
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx;

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
    c_fuel = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * rw.fuel_inr_kg,
    c_crew = case when x.wet then 0 else 2 * x.f * x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * (1 + g.age_maint_per_year * x.age_y) * rw.fx_inr_usd end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0)) * t.ref_seats / g.slot_ref_seats   -- 0016: by aircraft size
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id;

  -- Step 6: results
  -- What holding each aircraft costs a day (migration 0017): rent, wet-lease hours, or depreciation and loan interest for
  -- an owned one, plus its cabin crew's base pay (and the flat pilot cost in a world without pilots). Pilot salaries, head
  -- office and marketing are not split by aircraft.
  insert into pg_temp._acx (aircraft_id, airline_id, fixed, bh)
  select ac.id, tm.airline_id,
         case tm.holding
           when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
           when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
           else tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364
                + case when tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 * rw.fx_inr_usd else 0 end end
         + case when tm.holding = 'wet' then 0 else
             case when rw.pilots then 0 else t.pilot_fixed_inr_day end
             + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end,
         coalesce(u.bh, 0)
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u on u.aircraft_id = ac.id
   where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and exists (select 1 from public.airlines a0 where a0.id = ac.airline_id and a0.first_flight_day <= p_day);

  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr, aircraft_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost),
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
                          + s.all_ * (g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost)) as cost
                 from pg_temp._rot x
                 join pg_temp._prod p on p.route_id = x.route_id
                 cross join lateral (select coalesce(x.f * x.seats_e / nullif(p.cap_e, 0), 0) as e,
                                            coalesce(x.f * x.seats_b / nullif(p.cap_b, 0), 0) as b,
                                            coalesce(x.f * (x.seats_e + x.seats_b) / nullif(p.cap_e + p.cap_b, 0), 0) as all_) s
                where x.flown group by x.aircraft_id) z on z.aircraft_id = a.aircraft_id
   where a.airline_id is not null;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0)),
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
                            case when rw.pilots then 0 else t.pilot_fixed_inr_day end
                            + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
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
   where al.world_id = p_world and al.status = 'active' and al.first_flight_day <= p_day;

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
  delete from public.aircraft_daily ad using public.airlines al
   where al.id = ad.airline_id and al.world_id = p_world and ad.game_day <= p_day - g.route_keep_days::int;
end $$;

revoke all on function game.day_ops(uuid, int), game.day_pilots(uuid, int), game.run_day(uuid), game.tick(), game.airline_first_flight(), game.aircraft_week_start(),
  game.clock_day(public.worlds, numeric), game.clock_seconds(public.worlds, numeric) from public, anon, authenticated;
revoke all on function public.admin_set_week_hours(uuid, numeric) from public, anon;
grant execute on function public.admin_set_week_hours(uuid, numeric) to authenticated, service_role;

-- Worlds. World 1 (setup): a game week in 4 hours, with the pre-launch; its airlines fly from day 92.
update public.worlds set speed = 42 where status = 'setup';
update public.airlines a set first_flight_day = w.prelaunch_weeks * 7 + 1 from public.worlds w where w.id = a.world_id and w.status = 'setup';
-- Running worlds keep flying (they predate the pre-launch).
update public.worlds set prelaunch_weeks = 0 where status in ('running', 'paused', 'ended');

-- The owner's playtest world restarts on weeks: the old one goes, a fresh one opens in setup (a game week in 1 hour,
-- 25 places, pilots on). Its invite code is made here, never written in the repository.
delete from public.worlds where name = 'Test World';
with w as (
  insert into public.worlds (name, speed, demand_scale, max_airlines, pilots)
  values ('Test World', 168, 0.5, 25, true) returning id)
insert into public.world_secrets (world_id, invite_code)
select id, substr(md5(random()::text || clock_timestamp()::text), 1, 8) from w;
