// Row shapes of the tables and functions the app reads. Numbers arrive as JSON numbers.

export interface World {
  id: string; name: string; status: 'setup' | 'running' | 'paused' | 'ended';
  speed: number; started_at: string | null; paused_at: string | null; paused_seconds: number;
  game_day: number; season: number; season_days: number; demand_scale: number;
  fuel_inr_kg: number; fx_inr_usd: number; fuel_walk: number; fx_walk: number; fuel_avg: number | null; fare_index: number; max_airlines: number; pilots: boolean;
  prelaunch_weeks: number; prelaunch_minutes: number; start_date: string; selling: boolean;
  // worlds founded by players (migration 0027)
  founder_id: string | null; turn_mode: 'clock' | 'ready'; min_players: number | null; join_deadline: string | null;
  closed_at: string | null; rules: Partial<Record<WorldSetting, string>>; bot_scale: number;
}

/** The choices a founder makes for a world (migration 0027, G). `vals` are the game values the choice sets. */
export type WorldSetting = 'region' | 'pace' | 'turn' | 'places' | 'money' | 'banks' | 'growth' | 'seats' | 'shocks' | 'bots' | 'consultant';
/** Seats between India and a country with a limit, this world (0028): the limit, all airlines' seats and the airline's own, a week each way. */
export interface SeatRoom { country: string; name: string; limit: number; used: number; mine: number }
export interface WorldOption {
  setting: WorldSetting; option: string; sort: number; label: string; blurb: string;
  vals: Record<string, number>; available: boolean; is_default: boolean;
}
/** How close a player is to founding a world: an airline run for 4 quarters, the last 2 with an operating profit. */
export interface FounderStatus {
  need_quarters: number; need_profit_quarters: number; live_world: string | null; airline: string | null; world: string | null;
  quarters: number; last: { quarter: number; op_profit: number }[]; ok: boolean; admin: boolean;
}

export interface Airline {
  id: string; world_id: string; user_id: string | null; is_ai: boolean; name: string; code: string;
  livery: { color?: string }; status: 'active' | 'administration' | 'closed'; brand: number; otp: number;
  marketing_inr_day: number; created_day: number; administrations: number; first_flight_day: number;
  ready_day: number | null;   // When all are ready: the game day this airline was ready to play on from (0027)
}

export interface Finance {
  airline_id: string; cash_inr: number; debt_inr: number; credit_limit_inr: number; insolvent_days: number;
  pilot_pay: number; pilot_buffer: number; pilot_cadets: number; pilot_expats: boolean;
  credit_cut_from: number | null;   // the credit line before the bank cut it (0027)
}

export interface Base { airline_id: string; iata: string; opened_day: number }

export type AircraftStatus = 'pool' | 'delivering' | 'active' | 'grounded' | 'refit' | 'returned';
export interface Aircraft {
  id: string; world_id: string; type_id: string; airline_id: string | null; reg: string; built_day: number;
  status: AircraftStatus; available_day: number; base_iata: string | null; biz_rows: number;
  biz_pitch: number | null; econ_pitch: number; seats_biz: number; seats_econ: number;
}

export interface Terms {
  aircraft_id: string; airline_id: string; holding: 'lease' | 'owned' | 'wet'; lease_usd_month: number | null;
  lease_end_day: number | null; deposit_inr: number; price_usd: number | null; start_day: number | null;
  wet_usd_bh: number | null; ordered_day: number | null; pay_plan: 'cash' | 'slb' | null;
  finance_loan: boolean; loan_usd: number | null; loan_pay_usd_day: number | null;
  /** 0026: an order's loan currency, and a rupee loan's balance */
  loan_ccy: 'usd' | 'inr'; loan_inr: number; loan_pay_inr_day: number | null;
  /** 0028: weeks the maker put a new aircraft back (0: on time; null: not yet told) */
  delay_weeks: number | null;
}

export interface Route {
  id: string; world_id: string; airline_id: string; origin: string; dest: string; fare_econ: number;
  fare_biz: number | null; opened_day: number; status: 'open' | 'closed'; first_flight_day: number;
}

// ---------- Selling ahead (migration 0019) ----------
export type StrategyKey = 'fill' | 'balanced' | 'top' | 'follow';
export interface Strategy {
  key: StrategyKey; name: string; blurb: string; sort: number; target_lf: number; early_mult: number; late_mult: number;
  biz_early_mult: number; biz_late_mult: number; min_mult: number; max_mult: number; step: number; band: number;
  follow_gap: number; overbook: number;
}
export interface RoutePlan { route_id: string; airline_id: string; strategy: StrategyKey; sell_where: PosKey }
/** Where an international route sells its tickets (0026, G). */
export type PosKey = 'india' | 'both' | 'abroad';
export interface PosOption { key: PosKey; sort: number; name: string; blurb: string; usd_share: number; sales_cost_share: number; util_bonus: number }
/** One route's seats on sale for one flight week; figures each way for the whole week. */
export interface RouteWeek {
  route_id: string; week: number; airline_id: string; trips: number; seats_e: number; seats_b: number;
  price_e: number | null; price_b: number | null; bk_be: number; bk_l: number; bk_u: number; bk_b: number;
  rev_e: number; rev_b: number; sold_wk: number; spill: number;
  noshow: number | null; denied: number | null; comp: number | null; flown_e: number | null; flown_b: number | null;
  rev_flown_e: number | null; rev_flown_b: number | null; strategy: StrategyKey | null;
}
export interface AirlineWeek { airline_id: string; week: number; sales_inr: number; refunds_inr: number; comp_inr: number; advance_inr: number;
  /** 0033: compensation for flights cut within the region's notice, and those flights */
  cancel_comp_inr?: number; cut_flights?: number }
export interface MarketWatch { route_id: string; airline_id: string; a: string; b: string; week: number; fare_e: number | null; fare_b: number | null; trips: number; seats: number }
export interface MarketMove { id: number; a: string; b: string; week: number; airline_id: string; kind: 'enter' | 'leave' | 'fare_up' | 'fare_down' | 'more_flights' | 'fewer_flights'; old_value: number | null; new_value: number | null }

export interface Rotation { aircraft_id: string; route_id: string; weekly_trips: number }

export interface RouteDaily {
  route_id: string; game_day: number; airline_id: string; flights: number; seats_econ: number; seats_biz: number;
  pax_econ: number; pax_biz: number; spill: number; revenue_inr: number; var_cost_inr: number; aircraft_cost_inr: number;
}
export interface AircraftDaily {
  aircraft_id: string; game_day: number; airline_id: string; flights: number; block_h: number; seats: number; pax: number;
  revenue_inr: number; flying_cost_inr: number; aircraft_cost_inr: number;
}

export interface AirlineDaily {
  airline_id: string; game_day: number; pax: number; ask: number; rpk: number; rev_ticket: number; rev_anc: number;
  c_fuel: number; c_crew: number; c_maint: number; c_airport: number; c_rent: number; c_slots: number; c_dist: number;
  c_marketing: number; c_overhead: number; c_interest: number; c_other: number; c_depr: number; cash_end: number;
  brand: number | null; otp: number | null; flights: number; cancelled: number; loan_repaid: number;
  refunds_inr: number;
  fuel_kg: number; hedge_inr: number; groundings: number;
  /** 0026: dollar-linked costs in dollars and as booked, what dollar hedging saved, and the effect of the rupee against Rs 90 */
  usd_cost_usd: number; usd_cost_inr: number; usd_hedge_inr: number; fx_effect_inr: number;
  /** 0033: hull insurance, interest earned on cash, tax (on a quarter's last day), compensation for cancellations (also in c_other) */
  c_insurance?: number; i_cash?: number; c_tax?: number; c_comp?: number;
}

export interface Txn { id: number; airline_id: string; game_day: number; kind: string; amount_inr: number; pnl_inr: number; note: string }

export interface Quarterly {
  airline_id: string; quarter: number; revenue: number; op_profit: number; net_profit: number; pax: number;
  load_factor: number | null; rask: number | null; cask: number | null; otp: number | null; brand: number | null;
  net_worth: number | null; score: number | null; rank: number | null;
}

export interface News { id: number; world_id: string; game_day: number; airline_id: string | null; kind: string; body: string; private: boolean }
export interface GameEvent { id: string; world_id: string; kind: string; announced_day: number; starts_day: number; ends_day: number | null; payload: Record<string, unknown> }

export interface Airport {
  iata: string; city: string; country: string; region: string; is_india: boolean; lat: number; lon: number;
  pax_m: number | null; mass: number | null; biz_idx: number; tour_idx: number; runway_class: number;
  slot_cap: number | null; opens_day: number;
}

export interface Market { a: string; b: string; km: number; intl: boolean; n_biz: number; n_lei: number; n_bud: number; ref_fare: number }

export interface AircraftType {
  id: string; name: string; role: string; econ_abreast: number; biz_abreast: number; biz_kind: 'none' | 'recliner' | 'lieflat';
  cabin_len_in: number; max_seats: number; ref_seats: number; range_km: number; cruise_kmh: number;
  fuel_fixed_kg: number; fuel_per_km_kg: number; block_offset_h: number; base_turn_min: number; day_window_h: number;
  lease_usd_month: number; price_usd_m: number; maint_usd_fh: number; maint_usd_cycle: number; runway_class: number; sort: number;
}

export interface MarketQuote {
  type_id: string; pool_available: number; pool_target: number; rent_mult: number; lease_lead_days: number;
  order_price_usd: number; order_delivery_day: number; wet_usd_bh: number; wet_lead_days: number;
}

export interface Layout {
  valid: boolean; reason: string | null; seats_econ: number; seats_biz: number; seats: number; cabin_crew: number;
  comfort_econ: number; comfort_biz: number | null; range_km: number; min_turn_min: number;
}

export interface Profile { user_id: string; display_name: string; is_admin: boolean }

/** A festival or event (migration 0022, G): every game year from day-of-year start_doy for `days` days, it multiplies
 *  each traveller type's demand on the markets it touches. */
export interface DemandEvent {
  id: number; name: string; start_doy: number; days: number; domestic: boolean | null;
  airports: string[] | null; regions: string[] | null; biz: number; lei: number; bud: number; note: string;
}

/** Ops (migration 0023): the three fleet-wide strategies, as game values (G), and the airline's choices. */
export interface MaintPlan {
  key: 'payg' | 'contract' | 'hangar' | 'lean'; sort: number; name: string; blurb: string; good_for: string;
  rate_mult: number; age_k: number; fixed_inr_week: number; ground_mult: number; ground_len_mult: number; engine_mult: number;
  otp_delta: number; lock_weeks: number; setup_inr: number; setup_weeks: number;
}
export interface OpStyle {
  key: 'saver' | 'standard' | 'quick' | 'punctual'; sort: number; name: string; blurb: string; good_for: string;
  fuel_mult: number; hour_cost_mult: number; turn_delta_min: number; allowance_inr_turn: number; otp_delta: number; brand_delta: number;
}
export interface AirlineOps {
  airline_id: string; maint_plan: MaintPlan['key']; maint_next: MaintPlan['key'] | null; maint_next_day: number | null;
  maint_locked_until: number; op_style: OpStyle['key']; hedge_share: number; usd_hedge_share: number;
}
export interface CostBenchmark { world_id: string; line: string; week: number; airlines: number; median_inr_ask: number }
/** What each option would do for the airline now (public.ops_preview). */
export interface OpsPreview {
  day: number; aircraft: number; avg_age: number; plan: MaintPlan['key']; plan_next: MaintPlan['key'] | null; plan_next_day: number | null;
  locked_until: number; style: OpStyle['key']; hedge_share: number; fuel_price: number; fuel_normal: number;
  hedge_premium: number; hedge_lead_weeks: number; hedges: { week: number; share: number; price: number }[];
  /** 0033: the price expected in 13 weeks, and what a hedge bought now locks (premium included) */
  fuel_expected?: number; fuel_lock?: number;
  usd: { share: number; rate: number; ref: number; premium: number; step: number; max: number; week_usd: number; expected?: number; lock?: number;
         bought: { week: number; share: number; rate: number }[] };
  plans: { key: MaintPlan['key']; cost_week: number; fixed_week: number; groundings_qtr: number; days_qtr: number; otp_delta: number;
           lock_weeks: number; setup_inr: number; setup_weeks: number }[];
  styles: { key: OpStyle['key']; fuel_kg_week: number; fuel_week: number; other_week: number; trips_week: number; trips_fit: number;
            over: number; otp: number; brand_delta: number }[];
}
