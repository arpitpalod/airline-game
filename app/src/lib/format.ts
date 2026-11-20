// Money and numbers the way Indian readers expect: lakh and crore, en-IN grouping.

const group = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 0 });

export function num(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return new Intl.NumberFormat('en-IN', { maximumFractionDigits: digits, minimumFractionDigits: digits }).format(x);
}

/** ₹12.3 cr, ₹4.2 lakh, ₹12,345. Signed when asked. */
export function inr(x: number | null | undefined, opts: { sign?: boolean; digits?: number } = {}) {
  if (x == null || !isFinite(x)) return '–';
  const s = x < 0 ? '−' : opts.sign && x > 0 ? '+' : '';
  const a = Math.abs(x);
  let body: string;
  if (a >= 1e7) body = `${trim(a / 1e7, opts.digits ?? (a >= 1e9 ? 0 : a >= 1e8 ? 1 : 2))} cr`;
  else if (a >= 1e5) body = `${trim(a / 1e5, opts.digits ?? 1)} lakh`;
  else body = group.format(Math.round(a));
  return `${s}₹${body}`;
}

function trim(v: number, d: number) {
  return new Intl.NumberFormat('en-IN', { maximumFractionDigits: d }).format(v);
}

export function usd(x: number | null | undefined) {
  if (x == null || !isFinite(x)) return '–';
  const a = Math.abs(x);
  const s = x < 0 ? '−' : '';
  if (a >= 1e6) return `${s}$${trim(a / 1e6, 1)}M`;
  if (a >= 1e4) return `${s}$${trim(a / 1e3, 0)}k`;
  return `${s}$${group.format(Math.round(a))}`;
}

export function pct(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return `${(x * 100).toFixed(digits)}%`;
}

export function signedPct(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return `${x > 0 ? '+' : x < 0 ? '−' : ''}${Math.abs(x * 100).toFixed(digits)}%`;
}

/** Game calendar: day 1 is Wed 1 Jan 3000 (the world's start_date). Time moves a week at a time: week 1 is days 1 to 7.
 *  Years are 364 days (52 weeks), quarters 91 (13 weeks). */
export function gameDate(day: number) {
  const d = Math.max(day, 1) - 1;
  return { year: Math.floor(d / 364) + 1, quarter: Math.floor((d % 364) / 91) + 1 };
}
export const weekOf = (day: number) => Math.floor((Math.max(day, 1) - 1) / 7) + 1;
export const weekStart = (week: number) => (week - 1) * 7 + 1;
/** The week now being played: the one after the last week with results. */
export const currentWeek = (w: { game_day: number; season_days: number }) =>
  Math.min(Math.floor(w.game_day / 7) + 1, Math.max(1, Math.floor(w.season_days / 7)));

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
/** The calendar date of a game day. Year 3000 is not a leap year; JavaScript dates handle it. */
export function calDate(day: number, start = '3000-01-01') {
  const t = Date.parse(`${String(start).slice(0, 10)}T00:00:00Z`) + (Math.max(day, 1) - 1) * 86400000;
  const d = new Date(t);
  return { wd: WD[d.getUTCDay()], d: d.getUTCDate(), m: MON[d.getUTCMonth()], y: d.getUTCFullYear() };
}
export function dateLabel(day: number, start?: string, withYear = false) {
  const c = calDate(day, start);
  return `${c.wd} ${c.d} ${c.m}${withYear ? ` ${c.y}` : ''}`;
}
/** "Week 14 · 2 Apr to 8 Apr 3000" */
export function weekLabel(week: number, start?: string) {
  const a = calDate(weekStart(week), start), b = calDate(weekStart(week) + 6, start);
  const range = a.m === b.m ? `${a.d} to ${b.d} ${b.m}` : `${a.d} ${a.m} to ${b.d} ${b.m}`;
  return `Week ${week} · ${range} ${b.y}`;
}
/** Kept for screens that still name a single day. */
export function dayLabel(day: number, start?: string) {
  return `${dateLabel(day, start, true)} · week ${weekOf(day)}`;
}
/** Aircraft arrive at the start of a week (migration 0018): the week an arrival on a given day falls in, rounded up. */
export const arrivalWeek = (day: number) => (day <= 1 ? 1 : Math.ceil((day - 1) / 7) + 1);
export function arrivalLabel(day: number, start?: string) {
  const w = arrivalWeek(day);
  return `week ${w} (${dateLabel(weekStart(w), start)})`;
}
export function weeks(days: number) {
  const w = days / 7;
  return Number.isInteger(w) ? `${w} ${w === 1 ? 'week' : 'weeks'}` : `${Math.round(w * 10) / 10} weeks`;
}

/** Game days as real time at the world's speed (game days per real day). */
export function realSpan(gameDays: number, speed: number) {
  return realTime((gameDays * 86400) / speed);
}
export function realTime(seconds: number) {
  const hours = seconds / 3600;
  if (hours < 1.5) return `${Math.max(1, Math.round(hours * 60))} min`;
  if (hours < 36) return `${Math.round(hours)} hours`;
  const days = hours / 24;
  if (days < 14) return `${Math.round(days)} days`;
  return `${Math.round(days / 7)} weeks`;
}
/** Hours of real time a game week takes at a speed. */
export function weekHours(speed: number) {
  const h = 168 / speed;
  return h < 1 ? `${Math.round(h * 60)} minutes` : h === 1 ? '1 hour' : `${Math.round(h * 10) / 10} hours`;
}

export function plural(n: number, one: string, many = `${one}s`) {
  return `${num(n)} ${n === 1 ? one : many}`;
}
