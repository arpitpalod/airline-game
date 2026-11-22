// The Claude consultant (spec 14.25): pay a fee in game money for a report on your airline from Claude. Three problems
// with evidence and up to three actions; each action runs only when you tap Do it, through the usual public function.
// Open to admins only while consultant_open is 0 (testing).
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { askConsultant, call, rows, supabase } from '../lib/api';
import { useFleet, useGame, useInvalidate, useMaintPlans, useOpStyles, usePosOptions, useRoutes } from '../lib/data';
import { STRAT_SHORT } from '../lib/insights';
import { inr, pct, weekOf } from '../lib/format';
import type { StrategyKey } from '../lib/types';
import { useAction, useToast } from '../components/toast';
import { Badge, Button, Empty, Loading, PageHeader, Sheet } from '../components/ui';

export interface ConsultantStatus {
  fee_inr: number; can_ask: boolean; reason: string | null; asked_today: number; per_day: number; this_quarter: number; admin: boolean; busy: boolean;
  on?: boolean; fee_share?: number; fee_min_inr?: number;   // the world's rule (0032)
}
type Tag = 'Certain' | 'Likely' | 'Guessing';
export interface ConsultantAction { title: string; fn: string; args: Record<string, string | number>; why: string; effect: string; risk: string; tag: Tag }
export interface ConsultantReport {
  id: string; game_day: number; created_at: string; status: 'working' | 'done' | 'failed'; fee_inr: number; model: string | null;
  tokens_in: number; tokens_cached: number; tokens_out: number; cost_usd: number; error: string | null;
  report: { summary: string; problems: { title: string; evidence: string; tag: Tag }[]; actions: ConsultantAction[];
            missing: string | null; turns?: number; seconds?: number; dropped?: { title: string; fn: string; reason: string }[] } | null;
}

const TAG_TONE: Record<Tag, 'good' | 'info' | 'warn'> = { Certain: 'good', Likely: 'info', Guessing: 'warn' };
const STUCK_MS = 10 * 60_000;

function useStatus() {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'consultant_status', world.game_day],
    queryFn: () => call<ConsultantStatus>('consultant_status', { p_airline: airline.id }),
  });
}
function useReports() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'consultant_reports'],
    queryFn: () => rows<ConsultantReport>(supabase.from('consultant_reports').select('*').eq('airline_id', airline.id)
      .order('created_at', { ascending: false }).limit(10)),
    refetchInterval: (q) => ((q.state.data as ConsultantReport[] | undefined)?.some((r) => r.status === 'working') ? 4000 : false),
  });
}

export function Consultant() {
  const { airline } = useGame();
  const status = useStatus();
  const reports = useReports();
  const invalidate = useInvalidate();
  const toast = useToast();
  const [confirm, setConfirm] = useState(false);
  const [asking, setAsking] = useState(false);
  const s = status.data;
  const list = reports.data ?? [];
  const working = list.some((r) => r.status === 'working' && Date.now() - Date.parse(r.created_at) < STUCK_MS);

  async function ask() {
    setAsking(true);
    try {
      await askConsultant(airline.id);
      toast('Claude is reading your books. The report takes about a minute.');
      setConfirm(false);
      await invalidate();
    } catch (e) {
      toast((e as Error).message, 'error');
    } finally {
      setAsking(false);
    }
  }

  return (
    <div className="stack-lg">
      <PageHeader title="Consultant" back sub="Claude reads your airline's books and the public market, finds your three biggest money problems and suggests up to three actions. Nothing changes until you tap Do it." />
      {status.isError ? <div className="card small">The consultant could not load: {(status.error as Error).message}</div> : !s ? <Loading /> : (
        <div className="card stack" style={{ gap: 10 }}>
          <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
            <div><div className="tiny muted">Fee for a report</div><div className="kpi-s" style={{ fontSize: 22 }}>{inr(s.fee_inr)}</div></div>
            {s.admin && <Badge tone="accent">Admin test</Badge>}
          </div>
          <p className="small muted">{feeRule(s)} One report a game quarter, and at most {s.per_day} a day.</p>
          {s.can_ask && !working
            ? <Button block onClick={() => setConfirm(true)}>Ask Claude</Button>
            : <div className="small">{working ? 'A report is being written.' : s.reason}</div>}
        </div>
      )}
      {reports.isLoading ? <Loading /> : list.length === 0
        ? <Empty title="No reports yet">Your reports will show here, newest first.</Empty>
        : list.map((r, i) => <ReportCard key={r.id} r={r} open={i === 0} admin={!!s?.admin} />)}
      {confirm && s && (
        <Sheet title="Ask Claude for a report" onClose={() => setConfirm(false)}>
          <div className="stack">
            <p>{inr(s.fee_inr)} comes off your cash now. Claude looks only at your own airline and what every airline can see; it never sees the names players gave their airlines.</p>
            <Button block busy={asking} onClick={ask}>Pay {inr(s.fee_inr)} and ask</Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

function feeRule(s: ConsultantStatus) {
  if (s.on === false) return 'This world was founded without the consultant.';
  const share = s.fee_share ?? 0.01, min = s.fee_min_inr ?? 2500000;
  if (share <= 0 && min <= 0) return 'Free in this world.';
  return `${pct(share)} of your revenue last quarter, at least ${inr(min)}, booked as a one-off cost. Refunded if the report fails.`;
}

function ReportCard({ r, open, admin }: { r: ConsultantReport; open: boolean; admin: boolean }) {
  const [show, setShow] = useState(open);
  const stuck = r.status === 'working' && Date.now() - Date.parse(r.created_at) >= STUCK_MS;
  const head = (
    <div className="row link" style={{ justifyContent: 'space-between', alignItems: 'center' }} onClick={() => setShow(!show)}>
      <div><h2 style={{ margin: 0 }}>Week {weekOf(r.game_day)}</h2><div className="tiny muted">{new Date(r.created_at).toLocaleString()}</div></div>
      {r.status === 'working' && !stuck ? <Badge tone="info">Writing…</Badge>
        : r.status === 'failed' || stuck ? <Badge tone="bad">Fee refunded</Badge> : <Badge tone="good">{inr(r.fee_inr)}</Badge>}
    </div>
  );
  if (r.status === 'working' && !stuck) return <div className="card stack">{head}<p className="small muted">Claude is reading your books. This page updates by itself.</p></div>;
  if (r.status !== 'done' || !r.report) {
    return <div className="card stack">{head}<p className="small muted">{stuck ? 'The report did not finish. Ask again to get the fee back.' : `No report this time (${r.error ?? 'unknown error'}). The fee was refunded.`}</p></div>;
  }
  const rep = r.report;
  return (
    <div className="card stack">
      {head}
      {show && (
        <>
          <p>{rep.summary}</p>
          <h3>Problems</h3>
          {rep.problems.map((p, i) => (
            <div key={i} className="stack" style={{ gap: 4 }}>
              <div className="row" style={{ justifyContent: 'space-between', gap: 8 }}><strong>{i + 1}. {p.title}</strong><Badge tone={TAG_TONE[p.tag]}>{p.tag}</Badge></div>
              <div className="small">{p.evidence}</div>
            </div>
          ))}
          <h3>What to do</h3>
          {rep.actions.length === 0 ? <p className="small muted">No action this time.</p>
            : rep.actions.map((a, i) => <ActionRow key={i} a={a} reportId={r.id} n={i} />)}
          {rep.missing && <p className="small muted">Missing: {rep.missing}</p>}
          {admin && (rep.dropped ?? []).map((d, i) => <p key={i} className="tiny muted">Left out: {d.title || 'actions'} ({d.fn || 'none'}): {d.reason}</p>)}
          {admin && <p className="tiny muted">{r.model} · {rep.turns ?? '?'} turns · {rep.seconds ?? '?'} s · {r.tokens_in.toLocaleString()} in, {r.tokens_cached.toLocaleString()} cached, {r.tokens_out.toLocaleString()} out · ${Number(r.cost_usd).toFixed(3)}</p>}
        </>
      )}
    </div>
  );
}

const DONE_KEY = 'consultant-done';
const doneSet = () => { try { return new Set<string>(JSON.parse(localStorage.getItem(DONE_KEY) ?? '[]')); } catch { return new Set<string>(); } };

function ActionRow({ a, reportId, n }: { a: ConsultantAction; reportId: string; n: number }) {
  const { airline } = useGame();
  const routes = useRoutes();
  const fleet = useFleet();
  const plans = useMaintPlans();
  const styles = useOpStyles();
  const pos = usePosOptions();
  const { run, busy } = useAction();
  const key = `${reportId}:${n}`;
  const [done, setDone] = useState(() => doneSet().has(key));
  const [sure, setSure] = useState(false);
  const route = routes.data?.routes.find((x) => x.id === a.args.route_id);
  const reg = fleet.data?.find((x) => x.id === a.args.aircraft_id)?.reg;
  const rname = route ? `${route.origin}–${route.dest}` : 'a route you no longer fly';
  const v = a.args;
  const what: Record<string, string> = {
    set_strategy: `Sell ${rname} as ${STRAT_SHORT[v.strategy as StrategyKey] ?? v.strategy}`,
    set_rotation: `Fly ${reg ?? 'an aircraft'} ${v.round_trips_a_week} round trips a week on ${rname}`,
    open_route: `Open ${v.from}–${v.to}`,
    close_route: `Close ${rname} (tickets sold are refunded)`,
    set_sell_where: `Sell ${rname}: ${pos.data?.find((x) => x.key === v.where)?.name ?? v.where}`,
    return_aircraft: `Return ${reg ?? 'an aircraft'}`,
    set_hedge: `Hedge ${pct(Number(v.share))} of fuel`,
    set_usd_hedge: `Hedge ${pct(Number(v.share))} of dollars`,
    set_maint_plan: `Maintenance: ${plans.data?.find((x) => x.key === v.plan)?.name ?? v.plan}`,
    set_op_style: `Operating style: ${styles.data?.find((x) => x.key === v.style)?.name ?? v.style}`,
    set_marketing: `Marketing ${inr(Number(v.inr_day))} a day`,
    borrow: `Borrow ${inr(Number(v.amount_inr))}`,
    repay: `Repay ${inr(Number(v.amount_inr))}`,
  };
  const args: Record<string, Record<string, unknown>> = {
    set_strategy: { p_route: v.route_id, p_strategy: v.strategy },
    set_rotation: { p_aircraft: v.aircraft_id, p_route: v.route_id, p_weekly_trips: v.round_trips_a_week },
    open_route: { p_origin: v.from, p_dest: v.to },
    close_route: { p_route: v.route_id },
    set_sell_where: { p_route: v.route_id, p_where: v.where },
    return_aircraft: { p_aircraft: v.aircraft_id },
    set_hedge: { p_share: v.share }, set_usd_hedge: { p_share: v.share },
    set_maint_plan: { p_plan: v.plan }, set_op_style: { p_style: v.style },
    set_marketing: { p_inr_day: v.inr_day }, borrow: { p_amount: v.amount_inr }, repay: { p_amount: v.amount_inr },
  };
  async function doIt() {
    const r = await run(key, () => call(a.fn, { p_airline: airline.id, ...args[a.fn] }), `Done: ${what[a.fn]}`);
    if (r !== undefined) {
      const s = doneSet(); s.add(key);
      try { localStorage.setItem(DONE_KEY, JSON.stringify([...s].slice(-60))); } catch { /* private mode */ }
      setDone(true); setSure(false);
    }
  }
  return (
    <div className="stack" style={{ gap: 4, borderTop: '1px solid var(--line)', paddingTop: 8 }}>
      <div className="row" style={{ justifyContent: 'space-between', gap: 8 }}><strong>{a.title}</strong><Badge tone={TAG_TONE[a.tag]}>{a.tag}</Badge></div>
      <div className="small">{a.why}</div>
      <div className="small"><span className="muted">Should change:</span> {a.effect}</div>
      <div className="small"><span className="muted">Could go wrong:</span> {a.risk}</div>
      {done ? <div className="small good">Done</div>
        : <div><Button size="sm" kind="secondary" onClick={() => setSure(true)}>Do it</Button></div>}
      {sure && (
        <Sheet title="Do this?" onClose={() => setSure(false)}>
          <div className="stack">
            <p><strong>{what[a.fn]}</strong></p>
            <p className="small muted">It runs exactly as if you made the change on its own screen, and you can change it back there.</p>
            <Button block busy={busy === key} onClick={doIt}>Do it</Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}
