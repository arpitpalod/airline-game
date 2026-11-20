// Every read the app makes, as React Query hooks. Keys: ['ref'] reference data, ['w', world, ...] world data,
// ['a', airline, ...] the player's own books. Actions invalidate ['a', id] and ['w', world].
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { createContext, useContext } from 'react';
import { call, rows, supabase } from './api';
import { pairKey } from './game';
import type { SectorInsight } from './insights';
import type {
  Aircraft, AircraftDaily, AircraftType, Airline, AirlineDaily, Airport, Base, Finance, GameEvent, Layout, Market, MarketQuote,
  News, Profile, Quarterly, Rotation, Route, RouteDaily, Terms, Txn, World,
  AirlineWeek, MarketMove, MarketWatch, RoutePlan, RouteWeek, Strategy,
} from './types';

export interface Ref {
  types: AircraftType[]; type: Record<string, AircraftType>;
  airports: Airport[]; airport: Record<string, Airport>;
  param: Record<string, number>;
}

export async function loadRef(): Promise<Ref> {
  const [types, airports, params] = await Promise.all([
    rows<AircraftType>(supabase.from('aircraft_types').select('*').order('sort')),
    rows<Airport>(supabase.from('airports').select('iata,city,country,region,is_india,lat,lon,pax_m,mass,biz_idx,tour_idx,runway_class,slot_cap,opens_day').order('iata')),
    rows<{ key: string; num: number }>(supabase.from('game_params').select('key,num')),
  ]);
  return {
    types, type: Object.fromEntries(types.map((t) => [t.id, t])),
    airports, airport: Object.fromEntries(airports.map((a) => [a.iata, a])),
    param: Object.fromEntries(params.map((p) => [p.key, Number(p.num)])),
  };
}

export const useRefData = (enabled: boolean) =>
  useQuery({ queryKey: ['ref'], queryFn: loadRef, staleTime: Infinity, gcTime: Infinity, enabled });

export interface Game {
  uid: string; email: string; airline: Airline; world: World; ref: Ref; profile: Profile | null;
  myAirlines: Airline[]; switchAirline: (id: string) => void;
}
export const GameContext = createContext<Game | null>(null);
export function useGame() {
  const g = useContext(GameContext);
  if (!g) throw new Error('useGame outside a game');
  return g;
}

export const useMyAirlines = (uid: string | undefined) =>
  useQuery({
    queryKey: ['me', uid, 'airlines'], enabled: !!uid,
    queryFn: () => rows<Airline>(supabase.from('airlines').select('*').eq('user_id', uid!).order('created_day')),
  });

export const useProfile = (uid: string | undefined) =>
  useQuery({
    queryKey: ['me', uid, 'profile'], enabled: !!uid,
    queryFn: async () => (await rows<Profile>(supabase.from('profiles').select('*').eq('user_id', uid!)))[0] ?? null,
  });

export const useWorldRow = (id: string | undefined) =>
  useQuery({
    queryKey: ['world', id], enabled: !!id, refetchInterval: 60_000,
    queryFn: async () => (await rows<World>(supabase.from('worlds').select('*').eq('id', id!)))[0],
  });

export const useAllWorlds = (enabled: boolean) =>
  useQuery({ queryKey: ['worlds'], enabled, queryFn: () => rows<World>(supabase.from('worlds').select('*').order('name')) });

// ---------- The player's own airline ----------

export function useFinance() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'finance'],
    queryFn: async () => (await rows<Finance>(supabase.from('airline_finance').select('*').eq('airline_id', airline.id)))[0],
  });
}

export function useAirlineRow() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'row'], initialData: airline,
    queryFn: async () => (await rows<Airline>(supabase.from('airlines').select('*').eq('id', airline.id)))[0],
  });
}

export interface FleetItem extends Aircraft { terms: Terms | null }
export function useFleet() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'fleet'],
    queryFn: async () => {
      const [ac, terms] = await Promise.all([
        rows<Aircraft>(supabase.from('aircraft').select('*').eq('airline_id', airline.id).order('reg')),
        rows<Terms>(supabase.from('aircraft_terms').select('*').eq('airline_id', airline.id)),
      ]);
      const t = Object.fromEntries(terms.map((x) => [x.aircraft_id, x]));
      return ac.filter((a) => a.status !== 'returned').map((a) => ({ ...a, terms: t[a.id] ?? null })) as FleetItem[];
    },
  });
}

export function useBases() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'bases'],
    queryFn: () => rows<Base>(supabase.from('bases').select('*').eq('airline_id', airline.id).order('opened_day')),
  });
}

export function useRoutes() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'routes'],
    queryFn: async () => {
      const routes = await rows<Route>(supabase.from('routes').select('*').eq('airline_id', airline.id).eq('status', 'open').order('opened_day'));
      const rot = routes.length
        ? await rows<Rotation>(supabase.from('rotations').select('*').in('route_id', routes.map((r) => r.id)))
        : [];
      return { routes, rotations: rot };
    },
  });
}

export function useAirlineDaily(days = 28) {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'daily', days, world.game_day],
    queryFn: () => rows<AirlineDaily>(supabase.from('airline_daily').select('*').eq('airline_id', airline.id)
      .gte('game_day', Math.max(0, world.game_day - days + 1)).order('game_day')),
  });
}

export function useRouteDaily() {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'route_daily', world.game_day],
    queryFn: () => rows<RouteDaily>(supabase.from('route_daily').select('*').eq('airline_id', airline.id)
      .gte('game_day', Math.max(0, world.game_day - 27)).order('game_day')),
  });
}

export function useTxns() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'txns'],
    queryFn: () => rows<Txn>(supabase.from('transactions').select('*').eq('airline_id', airline.id).order('id', { ascending: false }).limit(60)),
  });
}

// ---------- The world ----------

export function useWorldAirlines() {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'airlines'],
    queryFn: () => rows<Airline>(supabase.from('airlines').select('*').eq('world_id', world.id).order('name')),
  });
}

export function useNews(limit = 30) {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'news', limit, world.game_day],
    queryFn: () => rows<News>(supabase.from('news').select('*').eq('world_id', world.id).order('id', { ascending: false }).limit(limit)),
  });
}

export function useEvents() {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'events', world.game_day],
    queryFn: () => rows<GameEvent>(supabase.from('events').select('*').eq('world_id', world.id).order('starts_day', { ascending: false }).limit(20)),
  });
}

export function useQuarterlies() {
  const { world } = useGame();
  const airlines = useWorldAirlines();
  const ids = (airlines.data ?? []).map((a) => a.id);
  return useQuery({
    queryKey: ['w', world.id, 'quarterly', ids.length, world.game_day],
    enabled: !!airlines.data,
    queryFn: () => (ids.length ? rows<Quarterly>(supabase.from('quarterly_reports').select('*').in('airline_id', ids).order('quarter', { ascending: false })) : Promise.resolve([])),
  });
}

/** Markets touching any of these airports (each airport has at most 161). */
export function useMarketsFrom(iatas: string[]) {
  const key = [...new Set(iatas)].sort();
  return useQuery({
    queryKey: ['markets', key.join(',')], enabled: key.length > 0, staleTime: Infinity,
    queryFn: async () => {
      const [a, b] = await Promise.all([
        rows<Market>(supabase.from('markets').select('*').in('a', key)),
        rows<Market>(supabase.from('markets').select('*').in('b', key)),
      ]);
      const m: Record<string, Market> = {};
      for (const x of [...a, ...b]) m[pairKey(x.a, x.b)] = x;
      return m;
    },
  });
}

export interface Rival { route: Route; airline: Airline | undefined; weekly: number; seatsWeek: number }
/** Every airline's open routes between these airports, with weekly round trips and seats. */
export function useRivals(iatas: string[]) {
  const { world } = useGame();
  const key = [...new Set(iatas)].sort();
  const airlines = useWorldAirlines();
  return useQuery({
    queryKey: ['w', world.id, 'rivals', key.join(','), world.game_day], enabled: key.length > 1 && !!airlines.data,
    queryFn: async () => {
      const routes = await rows<Route>(supabase.from('routes').select('*').eq('world_id', world.id).eq('status', 'open')
        .in('origin', key).in('dest', key));
      const rot = routes.length ? await rows<Rotation>(supabase.from('rotations').select('*').in('route_id', routes.map((r) => r.id))) : [];
      const acIds = [...new Set(rot.map((r) => r.aircraft_id))];
      const ac = acIds.length ? await rows<Aircraft>(supabase.from('aircraft').select('id,seats_econ,seats_biz,status').in('id', acIds)) : [];
      const seats = Object.fromEntries(ac.map((a) => [a.id, a]));
      const byId = Object.fromEntries((airlines.data ?? []).map((a) => [a.id, a]));
      const out: Record<string, Rival[]> = {};
      for (const r of routes) {
        const mine = rot.filter((x) => x.route_id === r.id);
        const weekly = mine.reduce((s, x) => s + x.weekly_trips, 0);
        const seatsWeek = mine.reduce((s, x) => s + x.weekly_trips * 2 * ((seats[x.aircraft_id]?.seats_econ ?? 0) + (seats[x.aircraft_id]?.seats_biz ?? 0)), 0);
        (out[pairKey(r.origin, r.dest)] ??= []).push({ route: r, airline: byId[r.airline_id], weekly, seatsWeek });
      }
      return out;
    },
  });
}

export function useAircraftMarket() {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'aircraft_market', world.game_day],
    queryFn: () => call<MarketQuote[]>('aircraft_market', { p_world: world.id }),
  });
}

export function usePool() {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'pool', world.game_day],
    queryFn: () => rows<Aircraft>(supabase.from('aircraft').select('*').eq('world_id', world.id).eq('status', 'pool').order('built_day', { ascending: false })),
  });
}

export function useLayout(type: string, bizRows: number, bizPitch: number | null, econPitch: number) {
  return useQuery({
    queryKey: ['layout', type, bizRows, bizPitch, econPitch], staleTime: Infinity, placeholderData: (p) => p,
    queryFn: async () => (await call<Layout[]>('layout_calc', { p_type: type, p_biz_rows: bizRows, p_biz_pitch: bizRows ? bizPitch : null, p_econ_pitch: econPitch }))[0],
  });
}

export function useInvalidate() {
  const qc = useQueryClient();
  const { airline, world } = useGame();
  return () => Promise.all([
    qc.invalidateQueries({ queryKey: ['a', airline.id] }),
    qc.invalidateQueries({ queryKey: ['w', world.id] }),
    qc.invalidateQueries({ queryKey: ['world', world.id] }),
  ]);
}

export interface AncProduct { id: string; name: string; sort: number; ref_share: number; takeup: number; inc_use: number; cost_share: number; w_biz: number; w_lei: number; w_bud: number }
export interface AirlineExtra { airline_id: string; product_id: string; included: boolean; price_mult: number }
export function useExtras() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'extras'],
    queryFn: async () => {
      const [products, mine] = await Promise.all([
        rows<AncProduct>(supabase.from('ancillary_products').select('*').order('sort')),
        rows<AirlineExtra>(supabase.from('airline_extras').select('*').eq('airline_id', airline.id)),
      ]);
      return { products, mine: Object.fromEntries(mine.map((m) => [m.product_id, m])) as Record<string, AirlineExtra> };
    },
  });
}

export interface RouteStudy {
  id: number; airline_id: string; a: string; b: string; game_day: number; depth: 'quick' | 'full'; carriers: number;
  flying_lo: number | null; flying_hi: number | null; turned_lo: number | null; turned_hi: number | null;
  lf_lo: number | null; lf_hi: number | null; untapped_lo: number | null; untapped_hi: number | null;
  biz_share: number | null; lei_share: number | null; bud_share: number | null; next_qtr: number | null;
}
export function useStudies() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'studies'],
    queryFn: () => rows<RouteStudy>(supabase.from('route_studies').select('*').eq('airline_id', airline.id).order('id', { ascending: false })),
  });
}

export interface PilotFamily { id: string; name: string; sort: number; pay_c_inr_day: number; pay_f_inr_day: number; pool_c: number; pool_f: number }
export interface AirlinePilots { airline_id: string; family: string; captains: number; fos: number; expats: number; need: number }
export interface PilotMarket { world_id: string; family: string; captains: number; fos: number; pay_index: number }
export function usePilots() {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'pilots'],
    queryFn: async () => {
      const [families, crews, market] = await Promise.all([
        rows<PilotFamily>(supabase.from('pilot_families').select('*').order('sort')),
        rows<AirlinePilots>(supabase.from('airline_pilots').select('*').eq('airline_id', airline.id)),
        rows<PilotMarket>(supabase.from('pilot_market').select('*').eq('world_id', world.id)),
      ]);
      return { families, crews: Object.fromEntries(crews.map((c) => [c.family, c])) as Record<string, AirlinePilots>,
               market: Object.fromEntries(market.map((m) => [m.family, m])) as Record<string, PilotMarket> };
    },
  });
}

export function useAircraftDaily() {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'aircraft_daily', world.game_day],
    queryFn: () => rows<AircraftDaily>(supabase.from('aircraft_daily').select('*').eq('airline_id', airline.id)
      .gte('game_day', Math.max(0, world.game_day - 6)).order('game_day')),
  });
}

// ---------- Selling ahead (migration 0019) ----------

export function useStrategies() {
  return useQuery({
    queryKey: ['strategies'], staleTime: 60_000,
    queryFn: () => rows<Strategy>(supabase.from('rm_strategies').select('*').order('sort')),
  });
}

export function useRoutePlans() {
  const { airline } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'route_plans'],
    queryFn: async () => Object.fromEntries((await rows<RoutePlan>(supabase.from('route_plans').select('*').eq('airline_id', airline.id)))
      .map((p) => [p.route_id, p.strategy])) as Record<string, RoutePlan['strategy']>,
  });
}

/** A route's flight weeks: the last 13 flown and the 26 on sale. */
export function useRouteWeeks(routeId: string | undefined) {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'route_weeks', routeId, world.game_day], enabled: !!routeId,
    queryFn: () => rows<RouteWeek>(supabase.from('route_weeks').select('*').eq('route_id', routeId!).order('week')),
  });
}

/** Ticket money week by week (last 13 weeks). */
export function useAirlineWeeks() {
  const { airline, world } = useGame();
  return useQuery({
    queryKey: ['a', airline.id, 'airline_weeks', world.game_day],
    queryFn: () => rows<AirlineWeek>(supabase.from('airline_weeks').select('*').eq('airline_id', airline.id)
      .gte('week', Math.max(1, Math.floor(world.game_day / 7) - 12)).order('week')),
  });
}

/** What every airline offers on one market, and what changed lately. */
export function useMarketWatch(a: string | undefined, b: string | undefined) {
  const { world } = useGame();
  const [x, y] = [a ?? '', b ?? ''].sort();
  return useQuery({
    queryKey: ['w', world.id, 'watch', x, y, world.game_day], enabled: !!a && !!b,
    queryFn: async () => ({
      watch: await rows<MarketWatch>(supabase.from('market_watch').select('*').eq('world_id', world.id).eq('a', x).eq('b', y)),
      moves: await rows<MarketMove>(supabase.from('market_moves').select('*').eq('world_id', world.id).eq('a', x).eq('b', y)
        .order('week', { ascending: false }).limit(20)),
    }),
  });
}

/** What works where: the last 13 flown weeks of the world's routes, by kind of sector, market shape and strategy. */
export function useSectorInsights() {
  const { world } = useGame();
  return useQuery({
    queryKey: ['w', world.id, 'insights', world.game_day],
    queryFn: () => rows<SectorInsight>(supabase.from('sector_insights').select('*').eq('world_id', world.id)),
  });
}
