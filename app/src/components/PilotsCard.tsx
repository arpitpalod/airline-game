// Crew (migration 0023): hired for the airline at market pay with 10% spare pilots; shown, not set. Pilots against need,
// their salaries, and what the rest of the crew cost last week.
import { useAirlineDaily, useFinance, useGame, usePilots } from '../lib/data';
import { inr, num } from '../lib/format';
import { Badge } from './ui';

export function usePilotSummary() {
  const { ref } = useGame();
  const pilots = usePilots();
  const fin = useFinance();
  if (!pilots.data || !fin.data) return null;
  const { families, crews, market } = pilots.data;
  let have = 0, need = 0, salary = 0, shortC = 0, shortF = 0;
  for (const fm of families) {
    const c = crews[fm.id];
    if (!c) continue;
    const idx = market[fm.id]?.pay_index ?? 1;
    have += c.captains + c.fos; need += 2 * c.need;
    shortC += Math.max(0, c.need - c.captains); shortF += Math.max(0, c.need - c.fos);
    salary += idx * ((c.captains - c.expats) * fm.pay_c_inr_day * fin.data.pilot_pay + c.expats * fm.pay_c_inr_day * ref.param.pilot_expat_mult
      + c.fos * fm.pay_f_inr_day * fin.data.pilot_pay);
  }
  return { have, need, salary, shortC, shortF, pay: fin.data.pilot_pay, buffer: fin.data.pilot_buffer };
}

export function CrewCard() {
  const { world } = useGame();
  const s = usePilotSummary();
  const daily = useAirlineDaily(7);
  const days = (daily.data ?? []).filter((d) => d.game_day > world.game_day - 7);
  const crew = days.reduce((a, d) => a + d.c_crew, 0);
  const pilotsWeek = s ? s.salary * 7 : 0;
  const short = s ? s.shortC + s.shortF : 0;
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Crew</h2><span className="small muted">hired for you</span></div>
      <div className="grid2">
        {world.pilots && s && (
          <div>
            <div className="tiny muted">Pilots</div>
            <div className="kpi-s">{num(s.have)} {short > 0 ? <Badge tone="warn">Short by {short}</Badge> : null}</div>
            <div className="tiny muted">{s.need === 0 ? 'none needed yet' : `${num(s.need)} needed · ${inr(pilotsWeek)} a week`}</div>
          </div>
        )}
        <div>
          <div className="tiny muted">All crew, last week</div>
          <div className="kpi-s">{days.length ? inr(crew) : '–'}</div>
          <div className="tiny muted">salaries, flying pay and allowances</div>
        </div>
      </div>
      <p className="tiny muted">Pilots are hired at market pay with 10% spare; wet-leased aircraft bring their own crew. A shortage shows here and on Home.</p>
    </div>
  );
}
