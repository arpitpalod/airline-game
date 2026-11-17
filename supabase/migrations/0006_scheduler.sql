-- Scheduler: every 5 minutes, process every game day that has fallen due in every running world.
-- Skipped where pg_cron is not installed (the local test database).

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('game-tick', '*/5 * * * *', 'select game.tick()');
  end if;
end $$;
