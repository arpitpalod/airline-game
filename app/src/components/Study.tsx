import { call } from '../lib/api';
import { useGame, useStudies, type RouteStudy } from '../lib/data';
import { inr, num, pct } from '../lib/format';
import { pairKey } from '../lib/game';
import { useAction } from './toast';
import { Badge, Button } from './ui';

const range = (lo: number | null, hi: number | null, f: (x: number) => string = (x) => num(x)) =>
  lo == null || hi == null ? '–' : lo === hi ? f(lo) : `${f(lo)} to ${f(hi)}`;

function Findings({ s }: { s: RouteStudy }) {
  return (
    <div className="stack">
      {s.flying_lo == null && <p className="small">Nobody flies it now. With one airline flying it twice a day at the reference fare,
        about <strong>{range(s.untapped_lo, s.untapped_hi)}</strong> travellers a day would fly each way.</p>}
      <div className="kv">
        {s.flying_lo != null && <>
          <span>Airlines flying it</span><span>{s.carriers}</span>
          <span>Flying it a day, each way</span><span>{range(s.flying_lo, s.flying_hi)}</span>
          <span>Turned away a day, each way</span><span>{range(s.turned_lo, s.turned_hi)}</span>
          <span>Seats filled, all airlines</span><span>{range(s.lf_lo, s.lf_hi, (x) => pct(x))}</span>
        </>}
        {s.biz_share != null && <>
          <span>Business · leisure · budget</span><span>{pct(s.biz_share)} · {pct(s.lei_share)} · {pct(s.bud_share)}</span>
          <span>Demand next quarter</span><span>{s.next_qtr! >= 1 ? '+' : '−'}{pct(Math.abs(s.next_qtr! - 1))} vs today</span>
        </>}
      </div>
    </div>
  );
}

export function StudyCard({ a, b, flat }: { a: string; b: string; flat?: boolean }) {
  const { ref, world, airline } = useGame();
  const studies = useStudies();
  const { run, busy } = useAction();
  const key = pairKey(a, b);
  const last = (studies.data ?? []).find((s) => pairKey(s.a, s.b) === key);
  const age = last ? world.game_day + 1 - last.game_day : null;
  const fresh = last && age! <= ref.param.study_valid_days;
  const commission = (depth: 'quick' | 'full') => run(depth, () => call('route_study', { p_airline: airline.id, p_a: a, p_b: b, p_depth: depth }),
    'Study done. The findings are below.');
  return (
    <div className={flat ? 'stack' : 'card stack'}>
      <div className="card-title" style={{ marginBottom: 0 }}>
        <h2>Route study</h2>
        {last && <Badge tone={fresh ? 'info' : 'warn'}>{last.depth === 'full' ? 'Full' : 'Quick'} · {age === 0 ? 'today' : `${age} days old`}</Badge>}
      </div>
      {last && fresh ? <Findings s={last} />
        : <p className="small muted">{last ? 'Your last study of this route is out of date. ' : ''}A study estimates what the market is doing: how many travellers fly it with every airline, how many are turned away and how full the flights are. Estimates come as a range and can be off.</p>}
      <div className="row wrap">
        <Button size="sm" kind="secondary" busy={busy === 'quick'} onClick={() => commission('quick')}>Quick study · {inr(ref.param.study_quick_inr)}</Button>
        <Button size="sm" kind="secondary" busy={busy === 'full'} onClick={() => commission('full')}>Full study · {inr(ref.param.study_full_inr)}</Button>
      </div>
      <p className="tiny muted">Quick: within about ±{Math.round(ref.param.study_quick_width * 100)}%. Full: within about ±{Math.round(ref.param.study_full_width * 100)}%, plus the traveller mix and next quarter's demand.</p>
    </div>
  );
}
