-- Pilot tuning (owner, 19 Nov 2026), after the season runs in spec 17 item 23:
-- 1. Pilot pay 10% lower, so a well-run airline pays about the crew cost it paid before pilots.
-- 2. Pilots are one lever, not a screen to manage: players set pay and spare pilots only. Foreign captains become the
--    automatic last resort for every airline (always available, 1.8x pay, 56 days); cadets stay off (not a setting).
-- Updates only.

update public.pilot_families f set pay_c_inr_day = v.c, pay_f_inr_day = v.f
  from (values ('ATR', 13800, 6300), ('A320', 17800, 8100), ('A350', 23500, 10700)) as v(id, c, f)
 where f.id = v.id;

alter table public.airline_finance alter column pilot_expats set default true;
update public.airline_finance set pilot_expats = true where not pilot_expats;
