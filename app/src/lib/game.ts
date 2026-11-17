// Display helpers that mirror server rules (spec sections 5 and 7). The server re-checks everything;
// these only let screens show what a choice means before it is sent.
import type { Aircraft, AircraftType, Market, World } from './types';

export const pairKey = (a: string, b: string) => (a < b ? `${a}-${b}` : `${b}-${a}`);

/** Seat geometry of a layout: rows for the seat map. Mirrors public.layout_calc. */
export function layoutRows(t: AircraftType, bizRows: number, bizPitch: number | null, econPitch: number) {
  const bp = bizRows > 0 ? (t.biz_kind === 'lieflat' ? 44 : bizPitch ?? 38) : 0;
  const seatsBiz = bizRows * t.biz_abreast;
  const econRows = Math.floor((t.cabin_len_in - bizRows * bp) / econPitch);
  const seatsEcon = Math.max(0, Math.min(econRows * t.econ_abreast, t.max_seats - seatsBiz));
  return { econRows: Math.ceil(seatsEcon / t.econ_abreast), seatsEcon, seatsBiz, seats: seatsEcon + seatsBiz };
}

export function minTurn(t: AircraftType, seats: number) {
  return Math.max(t.base_turn_min - 5, t.base_turn_min + 0.1 * (seats - t.ref_seats));
}

export function cabinRange(t: AircraftType, seats: number) {
  return Math.round(t.range_km * Math.min(1.1, 1 - (0.4 * (seats - t.ref_seats)) / t.ref_seats));
}

export function crewFor(seats: number) {
  return Math.ceil(seats / 50);
}

/** Hours one round trip takes, turnarounds included. */
export function tripHours(t: AircraftType, km: number, turnMin: number) {
  return 2 * (km / t.cruise_kmh + t.block_offset_h + turnMin / 60);
}

export function weekHours(t: AircraftType) {
  return 7 * t.day_window_h;
}

/** Round trips a week this aircraft could add on a route, given hours already planned elsewhere. */
export function maxWeekly(t: AircraftType, ac: Aircraft, km: number, usedHours: number) {
  const trip = tripHours(t, km, minTurn(t, ac.seats_econ + ac.seats_biz));
  return Math.max(0, Math.min(84, Math.floor((weekHours(t) - usedHours + 1e-9) / trip)));
}

export function marketTotal(m: Market) {
  return m.n_biz + m.n_lei + m.n_bud;
}

/** Age in years at a game day; aircraft built before the world have negative build days. */
export function ageYears(ac: Aircraft, day: number) {
  return Math.max(0, (day - ac.built_day) / 364);
}

/** Pool rent estimate: base rent x shortage x age discount (3% a year, floor 50%). */
export function poolRentUsd(t: AircraftType, rentMult: number, age: number) {
  return t.lease_usd_month * rentMult * Math.max(0.5, 1 - 0.03 * Math.floor(age));
}

/** Where the world clock stands. Results for a day appear when the scheduler next runs (every 5 minutes). */
export function clock(w: World, now = Date.now()) {
  const secPerDay = 86400 / w.speed;
  if (w.status !== 'running' || !w.started_at) return { dueDay: w.game_day, nextInSec: null as number | null, secPerDay };
  const elapsed = (now - Date.parse(w.started_at)) / 1000 - w.paused_seconds;
  const dueDay = Math.floor(elapsed / secPerDay);
  const nextDue = (w.game_day + 1) * secPerDay - elapsed;   // when the next day falls due
  const nextInSec = Math.max(0, nextDue) + 150;             // plus half a scheduler interval on average
  return { dueDay, nextInSec, secPerDay };
}

export const LIVERY_COLORS = ['#0E7C70', '#1E5AA8', '#7A3FD1', '#B4530F', '#C2185B', '#2E7D32', '#37474F', '#D4A017'];

export const STATUS_LABEL: Record<string, string> = {
  pool: 'With the lessor', delivering: 'On its way', active: 'In service', grounded: 'Grounded', refit: 'In refit', returned: 'Returned',
};

export const HOLDING_LABEL: Record<string, string> = { lease: 'Leased', owned: 'Owned', wet: 'Wet lease' };
export const holdingLabel = (a: { status: string; terms: { holding: string; ordered_day: number | null } | null }) =>
  a.status === 'delivering' && a.terms?.ordered_day != null ? 'On order' : HOLDING_LABEL[a.terms?.holding ?? 'lease'];
