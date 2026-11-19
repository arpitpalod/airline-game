// Row shapes of the tables and functions the app reads. Numbers arrive as JSON numbers.

export interface World {
  id: string; name: string; status: 'setup' | 'running' | 'paused' | 'ended';
  speed: number; started_at: string | null; paused_at: string | null; paused_seconds: number;
  game_day: number; season: number; season_days: number; demand_scale: number;
  fuel_inr_kg: number; fx_inr_usd: number; max_airlines: number; pilots: boolean; rm: boolean;
}

export interface Airline {
  id: string; world_id: string; user_id: string | null; is_ai: boolean; name: string; code: string;
  livery: { color?: string }; status: 'active' | 'administration' | 'closed'; brand: number; otp: number;
  marketing_inr_day: number; created_day: number; administrations: number;
}

export interface Finance {
  airline_id: string; cash_inr: number; debt_inr: number; credit_limit_inr: number; insolvent_days: number;
  pilot_pay: number; pilot_buffer: number; pilot_cadets: number; pilot_expats: boolean;
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
}

export interface Route {
  id: string; world_id: string; airline_id: string; origin: string; dest: string; fare_econ: number;
  fare_biz: number | null; opened_day: number; status: 'open' | 'closed';
}

export interface Rotation { aircraft_id: string; route_id: string; weekly_trips: number }

export interface RouteDaily {
  route_id: string; game_day: number; airline_id: string; flights: number; seats_econ: number; seats_biz: number;
  pax_econ: number; pax_biz: number; spill: number; revenue_inr: number; var_cost_inr: number; aircraft_cost_inr: number;
  noshow: number; denied: number;
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

// Revenue management (migration 0018). Figures on departures are each way; seats and bookings can be fractions.
export type RmMode = 'manual' | 'curve' | 'optimise';
export interface RouteRm {
  route_id: string; airline_id: string; mode: RmMode;
  e_mult: number[]; e_close: number[]; e_limit: number[]; b_mult: number[]; b_close: number[]; b_limit: number[];
  flex: number | null; target_lf: number; pace: number; outlook: number; overbook: number;
}
export interface Departure {
  route_id: string; dep_day: number; opened: number; cap_e: number; cap_b: number; sold_e: number[]; sold_b: number[];
  sav: number[]; flx: number[]; bkb: number; rev_sav: number; rev_flx: number; rev_b: number; lvl_e: number; lvl_b: number;
  fare_e: number | null; fare_b: number | null; turned_e: number; turned_b: number; min_e: number; min_b: number;
  curve: (number | null)[];
}
export interface DepartureLog {
  route_id: string; dep_day: number; opened: number; cap_e: number; cap_b: number; sold_e: number[]; sold_b: number[];
  sav: number[]; flx: number[]; bkb: number; pax_e: number; pax_b: number; noshow: number; denied: number; cancelled: number; turned: number;
  revenue: number; compensation: number; curve: (number | null)[];
}
export interface MarketFare { airline_id: string; route_id: string; dep_day: number; fare_e: number | null; fare_b: number | null }
export interface WhatIf { mult: number; fare: number; demand: number; pax: number; revenue: number }
export interface Festival { id: string; name: string; from_doy: number; to_doy: number; scope: 'all' | 'domestic' | 'international'; biz: number; lei: number; bud: number }
export interface SegFactor { biz: number; lei: number; bud: number }
