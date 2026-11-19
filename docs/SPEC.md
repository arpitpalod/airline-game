# Airline Game: Game Spec v0.1

Status: v0.10, 19 Nov 2026 (pilots, section 14.8, as one lever with pay 10% lower (0015); database changes applied on merge, 14.9; everything scarce scales with places, principle 7; route studies, 14.7; no aircraft trading, principle 6). Source of truth: `docs/SPEC.md` in the `airline-game` repo.

Number labels used below: **(V)** verified against a public source listed in section 17. **(G)** game value: a starting number chosen for play balance, to be tuned in Stage 2. Nothing here uses internal airline data.

## 1. Purpose and principles

A persistent multiplayer airline business game for office colleagues, built to teach commercial sense.

1. **Shared market.** Players compete for the same passengers, aircraft and slots. Nobody profits in isolation.
2. **Realism lives in the trade-offs**, not in detail for its own sake. Every feature must teach a real airline trade-off.
3. **Scarcity sets the price and never says no.** There is always a way to get capacity; the question is what it costs.
4. **Server decides everything.** Phones only display and submit decisions, so nobody can cheat and nothing depends on a phone being open.
5. **Five minutes a day** is enough to play well.
6. **Aircraft never become plentiful** (owner's rule, 19 Nov 2026). Nothing may create an easy supply of aircraft: no trading of aircraft or delivery slots between players, ever. Aircraft come only from the manufacturer queue, the lessor pool and wet leases, each limited or expensive. This is why the owner left Airlines Manager.
7. **Everything scarce scales with players** (owner's rule, 19 Nov 2026). A world has a number of places (`max_airlines`), and demand is set from it (`demand_scale = places / 50`). Every scarce supply is sized per place, so a world of 10 players is as tight as one of 100: travellers, the lessor pool, manufacturer delivery slots, the pilot market, airport slot caps and the computer-run fleets (at the start). Any new scarce resource (cargo capacity, loyalty partners) must be sized per place too. When more colleagues join than a world has places, raise its places (`admin_set_places`, only upwards once running) or open another world.

## 2. Decisions locked

| Topic | Decision |
|---|---|
| Players | One person, one airline. About 50 airlines per world. More players means more parallel worlds |
| Duration | Seasons of 26 real weeks, then reset with a hall of fame |
| Clock | 13x, set per world |
| Map | 162 real airports: 93 in India, 69 abroad. Demand is modelled from published airport traffic |
| Rivals | Fictional computer-run airlines fill the world; no real airline brands |
| Livery | Cosmetic only. Brand score moves demand, paint does not |
| Platform | Installable web app (opens from a link, sits on the home screen). Supabase back end |
| Aircraft configuration | First-class feature in the MVP (section 5) |
| Currency | Rupees, with dollar-linked costs (leases, fuel, maintenance) so currency risk is real |

## 3. World and clock

**Clock at 13x**

| Real time | Game time |
|---|---|
| 110.8 minutes | 1 day |
| 1 day | 13 days |
| 1 week | 1 quarter (91 days) |
| 4 weeks | 1 year (364 days) |
| 26 weeks (one season) | 6.5 years |

`game_day = floor((now - world_start - paused_time) x speed / 86,400 s)`. A scheduled job runs every 5 minutes and processes every game day that has fallen due, so a missed run only delays results and never loses them.

**Airports.** Each airport stores: code, city, country, region, coordinates, business index, tourism index, runway class (turboprop, narrowbody, widebody) and a daily slot cap where congested. Indian airports also store passengers handled a year and the international share; foreign airports store a weight in India's international travel. Coordinates are from public airport data (V). Passenger numbers are the published FY 2025-26 figures for the 49 busiest airports (V) and estimates for the rest (G). Indices, international shares and foreign weights are (G).

**MVP limits.** Bases can only be opened in India, and every market touches India. Two airports open during the season as events: Navi Mumbai (game day 364) and Noida (game day 546).

## 4. Demand model

Each city pair is one market with three passenger segments.

**Market size.** The model reproduces real traffic, then converts it to potential demand.

- **Domestic.** A balanced gravity model: every pair is weighted by `air_share(d)`, then scaled so each airport's pairs add up to its real domestic passengers. `air_share(d) = 1 - 1 / (1 + (d / 300 km)^3)`: road and rail win short trips, so 23% fly at 200 km, 50% at 300 km and 95% at 800 km.
- **International.** Each Indian airport's international passengers are split across foreign airports in proportion to `weight x affinity` (for example Kerala to the Gulf 2.5x, Punjab to Europe and North America 2.5x).
- **Potential.** `potential = real traffic / 0.65`, because about 65% of potential travellers fly at reference fares and service (G). A world setting scales demand to the number of airlines.
- **Segments.** `business share = 0.08 + 0.27 x average business index`; of the rest, `leisure share = 0.30 + 0.45 x higher tourism index`; the remainder is budget and family visits.
- **Seasonality and growth** are applied by the engine as monthly and yearly multipliers per segment.

Check against reality: the model gives 168.7M domestic and 80.3M international passengers a year, in line with the published all-India total of 420M passengers handled. Delhi to Mumbai comes out at 12,600 each way a day.

**Who flies with whom.** Every airline's product on the route (cabin, fare, frequency, comfort, brand) gets a utility per segment:

`U = a - b x fare / reference_fare + c x ln(1 + daily_flights) + d x comfort x sqrt(block_hours) + e x (brand - 50) / 50`

The airlines on a route form one group against the option of not flying (nested logit, Stage 2c): with `x_k = exp(U_k / λ)` and `S` the sum of `x` over the route's airlines, `P(fly) = S^λ / (1 + S^λ)` and airline k's share of those who fly is `x_k / S`. λ = 0.5 (G). Cheaper fares and more flights grow the whole market, a monopolist who overprices loses travellers to the road, but splitting the same flights among more airlines barely adds travel.

| Segment | Price b | Frequency c | Comfort d | Brand e | Cabins considered |
|---|---|---|---|---|---|
| Business | 1.6 | 0.9 | 0.50 | 0.6 | Business, economy |
| Leisure | 3.0 | 0.4 | 0.25 | 0.4 | Economy |
| Budget and family visits | 4.5 | 0.25 | 0.10 | 0.2 | Economy |

All coefficients (G). Reference economy fare (G): `Rs 2,100 + 3.3 x km` (Stage 2c; it was Rs 1,800 + 3.4 x km). Business reference: 3.5x economy. Business travellers choosing the business cabin add a constant of −2.2 (G): its comfort must outweigh its price.

**Capacity.** If demand exceeds seats, half the business-cabin overflow takes economy on the same airline. The rest of the overflow tries airlines with free seats in the same cabin, in proportion to how attractive they are: at most 60% find a seat, fewer when the airlines left are dearer or worse (G).

**Calibration targets for Stage 2** (public ballparks, to be re-checked then): a well-run narrowbody on a trunk route earns a 5 to 10% operating margin at 80 to 88% load factor; cost per seat-km around Rs 4.3 to 4.8; revenue per seat-km around Rs 4.6 to 5.2.

## 5. Aircraft and configuration

### 5.1 Types in the MVP

| Type | Role | Abreast (econ / biz) | Cabin length L (in) | Max seats | Reference seats | Range, full (km) | Cruise (km/h) | Fuel per sector (kg) | Lease ($k / month) |
|---|---|---|---|---|---|---|---|---|---|
| ATR 72-600 | Regional | 4 / none | 532 | 78 (V) | 72 (V) | 1,370 (V) | 510 (V) | 140 + 1.30 x km (V, derived) | 170 (G) |
| A320neo | Narrowbody | 6 / 4 | 880 | 194 (G, from memory) | 180 | 6,300 (V) | 830 (G) | 700 + 2.65 x km (G) | 380 (V, band) |
| A321neo | Narrowbody | 6 / 4 | 1,110 | 244 (V) | 222 | 6,850 (V) | 830 (G) | 800 + 3.15 x km (G) | 480 (V, band) |
| A321XLR | Long narrowbody | 6 / 4 | 1,110 | 244 (V) | 210 | 8,700 (V) | 830 (G) | 850 + 3.25 x km (G) | 520 (G) |
| A350-900 | Widebody | 9 / 4 | 1,400 | 440 (V) | 324 | 15,400 (V) | 900 (G) | 2,500 + 6.40 x km (G) | 1,150 (G) |

Type names are a data value and can be swapped for generic names without touching the rules. Purchase prices (G, $M): 22, 55, 65, 72, 165.

### 5.2 The layout rules

A layout is: business rows and pitch, economy pitch.

- `economy_rows = floor((L - business_rows x business_pitch) / economy_pitch)`
- `seats = economy_rows x economy_abreast + business_rows x business_abreast`, never above the certified maximum.
- Pitch ranges (G): economy 28 to 34 in; narrowbody business recliner 36 to 42 in; widebody lie-flat fixed at 44 in per row.

What the formula produces:

| Type | Layout | Seats |
|---|---|---|
| ATR 72-600 | 28 in / 29 in / 30 in | 76 / 72 / 68 |
| A320neo | 28 in / 29 in / 30 in | 186 / 180 / 174 |
| A320neo | 12 business at 38 in + economy at 30 in | 162 |
| A321neo | 28 in / 29 in / 30 in | 234 / 228 / 222 |
| A321XLR | 12 business at 38 in + economy at 30 in | 210 |
| A350-900 | all economy at 31 in | 405 |
| A350-900 | 36 lie-flat + economy at 31 in | 324 |

These land within one row of published layouts (ATR publishes 72 at 29 in and 78 at 28 in; Airbus quotes 206 to 220 for a two-class A321XLR and 300 to 350 for a three-class A350-900).

### 5.3 What each choice costs or earns

| Lever | Effect in the game |
|---|---|
| More seats | Lower cost per seat; more to sell |
| Tighter pitch | Comfort index falls: `(pitch - 28) / 6`, from 0 at 28 in to 1 at 34 in. Comfort matters more on long flights (the `sqrt(block_hours)` term) |
| Business cabin | Comfort 1.6 to 2.1 (recliner) or 2.6 (lie-flat). Only pays where the business segment is large |
| Cabin crew | `ceil(seats / 50)` (V, US and European rule). World setting for the Indian variant, which steps at 100, 150 and 200 seats |
| Weight | `fuel x (0.80 + 0.20 x passengers / reference_seats)` |
| Range | `range x (1 - 0.4 x (seats - reference) / reference)`, at most 10% above the published range |
| Turnaround | Minimum turn moves 0.1 minute per seat above or below reference (at most 5 minutes shorter); slower turns mean fewer flights a day |
| Refit | Rs 1 crore plus Rs 50,000 per seat changed, and 7 game days on the ground (G) |
| Leased used aircraft | Arrive with the previous operator's layout; changing it needs a refit |
| Sub-fleets (after MVP) | A grounded aircraft can only be covered by a spare with a matching layout, or seats get bumped |

### 5.4 The configurator screen

Sliders for business rows, business pitch and economy pitch. Live readouts: seats by cabin, cabin crew needed, range at full load, comfort index, cost per seat-km on a chosen route, and a warning when one more row would add a crew member.

## 6. Aircraft market and scarcity

Three ways to get an aircraft, always available, priced by shortage.

| Channel | Arrives in (real time) | Game time at 13x | Cost |
|---|---|---|---|
| Wet lease (aircraft with crew) | Next day | 13 days | About 2.2x the all-in hourly cost. Unlimited supply |
| Operating lease from the lessor pool | 3 to 7 days | 39 to 91 days | Base rent x shortage premium. Deposit of 3 months' rent |
| New order from the manufacturer | 6 to 8 weeks | 1.5 to 2 years | Cheapest per month. 15% deposit, balance on delivery (cash, aircraft loan, or sale-and-leaseback) |

- **Lessor pool.** Finite per type and world, sized to the number of airlines, with a mix of ages. `rent = base x (1 + 1.5 x (1 - available / target)^2)`. Refills each game quarter. One airline can lease at most 6 aircraft from the pool in any 91 game days (G).
- **Manufacturer queue.** Delivery slots per game quarter per type, sized per place (principle 7). Every order joins the queue, so a rush of orders lengthens everyone's wait and raises the price.
- **Age.** Older aircraft rent for less, burn more fuel (+0.5% a year), cost more to maintain (+3% a year) and ground more often (G).
- **Groundings.** Random technical groundings per aircraft, plus occasional fleet-wide engine events that ground a share of one type for weeks.
- **No player market for aircraft** (principle 6): players never sell, sublease or trade aircraft or delivery slots to each other. Airport slots only, if ever.

## 7. Network, scheduling and slots

- **Bases.** Aircraft live at a base. Every route starts at one of the airline's bases. Opening a base costs money.
- **Rotations.** `block_hours = km / cruise + 0.7` (0.4 for the ATR). `rotation = 2 x block + 2 x turnaround`. An aircraft's rotations must fit its window, counted over a week: 17 hours a day for narrowbodies and turboprops, 20 for the A321XLR, 22 for widebodies (G). Frequencies are set as round trips a week.
- **Check:** Delhi to Mumbai at 1,150 km gives a 2.09 hour block and a 5.2 hour rotation on a 186-seat A320neo, so three round trips a day and 12.5 block hours.
- **Slots.** Congested airports have a daily movement cap. `price per slot = base / (1 - utilisation)^2`. A full airport forces bigger aircraft, off-peak flying or a secondary airport.

## 8. Revenue

- One fare per cabin per route in the MVP, changeable any time, effective next game day.
- The route screen shows the reference fare, rivals' public fares and frequencies, and yesterday's load factor and spill.
- Extras (ancillaries): four extras each sold at a price or included free, set once for the whole network (section 14.6). Replaced the flat 8% of ticket revenue.

## 9. Costs

| Cost | Driver | Currency |
|---|---|---|
| Fuel | Sector fuel x fuel price (starts Rs 100 / kg, moves with a random walk and shocks) | Dollar-linked |
| Aircraft rent or ownership | Per month per aircraft | Dollars |
| Maintenance | Per flight hour and per flight, rising with age | Dollar-linked |
| Crew | Pilot salaries by fleet family and flying pay per block hour (14.8); cabin crew by the seat rule, per block hour plus fixed | Rupees |
| Airport and navigation | Landing by aircraft size, per passenger handling, per km | Rupees |
| Slots and bases | Section 7 | Rupees |
| Distribution and service | Share of revenue plus per passenger | Rupees |
| Marketing | Set by the player; feeds brand | Rupees |
| Overheads and interest | Fixed plus per seat in the fleet; interest on the credit line (rupees) and aircraft loans (dollars) | Rupees |

Exchange rate starts at Rs 90 per dollar (G) and moves over time.

## 10. Brand and punctuality

- **Brand score** (0 to 100) drifts toward a target built from on-time performance, cancellations, cabin comfort and marketing spend.
- **On-time performance** falls as the schedule gets tighter: aircraft used above 85% of their daily window and minimum turnarounds both cost punctuality. Padding the schedule buys punctuality at the price of flights.
- **Cancellations** happen when a grounded aircraft has no cover.

## 11. Finance and scoring

- Start: Rs 500 crore equity, a Rs 200 crore credit line and one wet-leased A320neo (an ATR at a turboprop-only base), ready to fly on the airline's first day at the normal wet-lease rate (G).
- Daily flash report; quarterly profit and loss, cash flow and route profitability. Headline quarterly results are public, like a listed company. Fares, frequencies and seat counts are public. Costs are private.
- **Insolvency.** Cash below zero with the credit line used up for 14 game days puts the airline in administration: lessors repossess, and the player restarts with reduced capital and a public mark.
- **Season score:** `net worth + 5 x profit after interest of the last four quarters` (Stage 2c; it was operating profit, which left out the interest on aircraft loans). Computer-run airlines are not ranked. Side boards for load factor, punctuality and unit margin.

## 12. Events and computer-run airlines

- **MVP events:** fuel shock, currency swing, engine grounding, new airport opening.
- **Later:** rival collapse, fare caps, demand shocks. (Stricter pilot duty-time rules: 14.8.)
- **Computer-run airlines:** six fictional carriers with fixed starting networks and rule-based pricing (they follow the lowest fare within a band and defend their bases). They keep markets contested while a world fills up, and from migration 0009 they also start flying routes where players earn well (14.5). As built: section 14.3.

## 13. Scope

**MVP**

- Worlds, sign-in, airline creation with cosmetic livery
- Map, bases, routes, fares, rotations
- The five aircraft types, full configurator, refits
- Lease, order and wet lease with shortage pricing; groundings
- Three passenger segments, shared demand, spill
- Slots at congested airports
- Fuel and currency movement, four event types
- Brand and punctuality (simple form)
- Daily and quarterly reports, leaderboard, season reset
- Six computer-run airlines
- Admin panel: speed, pause, invite codes, events

**Later layers, in rough order**

1. Player-to-player market for airport slots only (never aircraft or delivery slots: principle 6)
2. Departure-time bands, booking curve and overbooking
3. Ancillary choices, loyalty programme, corporate deals
4. Sub-fleet penalties, spare aircraft strategy
5. Crew: pilots built (14.8); cabin crew stays a cost per seat rule
6. Hub connections, cargo, codeshares, international traffic rights
7. Fuel hedging

## 14. Architecture

| Part | Choice |
|---|---|
| Data and rules | Supabase Postgres, Mumbai region |
| Game engine | Database functions run by a scheduled job. One transaction per game day per world, safe to re-run |
| Player actions | Validated server functions only. The app never writes tables directly |
| Privacy | Row-level security: each player sees their own books plus public market data |
| Sign-in | Email and password plus a world invite code. No dependency on email delivery |
| App | React and TypeScript single-page app, installable, with cached reference data and optimistic updates |
| Map | Lightweight vector map drawn on the device, no map tile service |
| Hosting | GitHub Pages from this repo. The repo is public, so no secrets are ever committed; the database is protected by row-level security, not by hiding code |

**Main tables:** worlds, seasons, world_state, airports, markets, aircraft_types, airlines, bases, aircraft, layouts, orders, lessor_pool, routes, rotations, slot_holdings, route_daily, airline_daily, ledger, quarterly_reports, events, brand_history.

### 14.1 Engine design (Stage 2b)

**Player actions.** Each is one server function that checks ownership, world state and cash before changing anything: join a world with its invite code and found an airline (first base free), open a base, lease from the pool, order new, wet lease, return an aircraft, change a layout (refit), open or close a route, set fares, set rotations, set marketing spend, borrow and repay.

**World start.** Fills the lessor pool in proportion to the number of airline places and starts the clock.

**One game day**, in one transaction per world, guarded by a lock so it can never run twice:

1. Move the fuel price and exchange rate; start and end events.
2. Deliveries, lease expiries, refits finishing, groundings starting and ending.
3. Capacity: seats per airline, route and cabin from the rotations of serviceable aircraft.
4. Demand: market potential x season x growth x world scale, split by segment across every product plus the option of not flying, then the spill pass.
5. Money: ticket and ancillary revenue; fuel, crew, maintenance, airport and slot costs per flight; rent, overheads, marketing and interest per day.
6. Write route results (kept for 28 game days) and airline results (kept all season); update cash, brand and punctuality.
7. Every 91 days: quarterly reports, ranks and news.
8. Insolvency check.

**Scheduler.** A database job every 5 minutes processes every game day that has fallen due, at most 30 per run per world.

**Speed targets:** first load under 2 seconds on 4G; screen changes under 200 ms; a game day processed in under 2 seconds for 50 airlines.

### 14.2 Stage 2b as built

**Functions the app calls.** Players: `found_airline`, `open_base`, `lease_aircraft`, `order_aircraft`, `wet_lease`, `return_aircraft`, `refit_aircraft`, `rebase_aircraft`, `open_route`, `close_route`, `set_fares`, `set_rotation`, `set_marketing`, `borrow`, `repay`. Admin: `admin_start_world`, `admin_pause_world`, `admin_resume_world`. Read: `aircraft_market` (pool, rents, order and wet-lease quotes). The engine lives in the closed `game` schema: `run_day` processes one day, `tick` catches every running world up with its clock.

**Rules settled in this stage** where sections 4 to 11 were silent. Every number is (G) and lives in `game_params`, `aircraft_types` or `season_factors`.

| Topic | Rule |
|---|---|
| Days | `worlds.game_day` is the last day processed. Actions are stamped `game_day + 1` and count when that day runs |
| Cash | An action needs the cash in hand; borrow first. A daily shortfall is drawn from the credit line automatically. Interest 11% a year |
| Lessor pool | Per airline place: ATR 1.5, A320neo 3, A321neo 1.5, A321XLR 0.5, A350 0.4. Ages 0 to 12 years, three standard cabins. Rent falls 3% per year of age (floor 50%). Arrives in 39 days when the pool is full, 91 when empty. A quarter of the target is added back each quarter |
| Operating lease | Term 728 days, then renews at the market rent. Early return: rent for the rest of the term is owed, capped at the deposit |
| New orders | Slots a quarter per airline place: 0.12, 0.30, 0.16, 0.06, 0.04. Shortest wait 546 days; price rises 8% per extra year of queue. On delivery, cash pays the balance and the aircraft is owned (depreciation 3.6% a year, not cash). Plan `slb`, or too little cash on the day: sale and leaseback at 85% of the base rent. Cancelling forfeits the deposit. An owned aircraft sells at 85% of book value |
| Wet lease | 13 days. Rate = 2.2 x the all-in hourly cost of rent, crew and maintenance (A320neo: about $5,560 a block hour), at least 6 hours billed a day. Standard cabin, no deposit, lessor pays crew and maintenance |
| Routes | One route per airline per city pair; aircraft based at either end can fly it. Fares between 0.25x and 4x the reference fare |
| Rotations | Round trips a week per aircraft per route. Must fit the cabin's range, both runways and the weekly flying window at minimum turnaround |
| Demand constants | `a` = -0.45 business, 1.82 leisure, 3.59 budget: 65% of potential flies when three airlines each offer four flights a day at the reference fare |
| Season and growth | Monthly multipliers per segment; game day 1 is 1 April. Growth 7% a year. Each market swings about 10% from day to day |
| Spill | 60% of travellers without a seat move to other airlines with free seats in the same cabin, in proportion to free seats, in one pass |
| Costs | Pilots: fixed per aircraft a day plus per block hour. Cabin crew: Rs 10,000 per position a day plus Rs 600 a block hour. Maintenance per flight hour and per flight, +3% per year of age. Airport: landing and navigation by type, Rs 150 handling a passenger, foreign landings 2x. Distribution: 3% of ticket revenue plus Rs 120 a passenger. Overheads: Rs 6 lakh a day, plus Rs 1.8 lakh per aircraft and Rs 1.5 lakh per base |
| Slots | No slot holdings. Every movement at a congested airport pays `3,000 / (1 - utilisation)^2`, where utilisation is the day's movements by all airlines over the cap, priced at 95% at most |
| Punctuality | 92% on a relaxed schedule; falls 20 points as an aircraft's use rises from 85% to 100% of its flying window |
| Brand | Moves 2% of the gap a day toward `50 + 100 x (on-time - 0.84) - 300 x cancellation rate + 15 x (comfort - 0.17) + marketing`, where marketing adds up to 20 points (Rs 100 per daily passenger buys 63% of that) |
| Groundings | 0.4% a day per aircraft, rising 10% per year of age, for 2 to 6 days. Flights are cancelled; there is no spare cover in the MVP |
| Events | Fuel shock: +15 to 45% for 40 to 120 days. Currency swing: rupee 4 to 10% weaker for 60 to 180 days. Engine event: 15 to 30% of one type grounded for 3 to 8 weeks. Airport openings are announced 91 days ahead |
| Insolvency | After 14 days with cash below zero and the credit line used up: fleet repossessed, orders cancelled, routes closed, debts wiped; restart with Rs 250 crore, half the credit line, 15 brand points lost and a public counter |
| Scheduler | Database job `game-tick` every 5 minutes, at most 30 days per world per run. A day that fails is rolled back, logged in `game.engine_log` and retried |
| Limits | 300 aircraft per airline, including those on their way |

**Check against the calibration targets** (local test, leased 180-seat A320neo, Delhi to Mumbai, three round trips a day, reference fare): cost per seat-km Rs 4.35 before head-office overhead, revenue per seat-km Rs 4.58 at an 85% load, operating margin 5.0%, on-time performance 84%.

**Speed.** One game day takes 15 ms in the live database for one airline, and 450 ms in the in-memory test database with 50 airlines, 960 aircraft and 2,900 rotations (target: under 2 seconds).

### 14.3 Stage 2c as built

Migration `0007_bots_and_tuning.sql`. Every number is (G) and lives in `game_params`, `aircraft_types`, `bot_airlines` or `bot_network`.

**Computer-run airlines.** Six fictional carriers, set up on a world's first game day. Fleets below are at `demand_scale` 1; a world's fleets are scaled by `demand_scale x bot_scale` (`bot_scale` is a world setting, default 1; 0 means none). A route worth at least half a daily service keeps a daily service when scaled down.

| Airline | Style | Bases | Fleet | Fare band (x reference) |
|---|---|---|---|---|
| Sarus Airways | Full service: two-class A320neo and A321neo trunks, A350 to London, A321XLR to Singapore | DEL, BOM | 73 | 1.00 to 1.60 |
| Koel Air | Low-cost: dense A321neo and A320neo on the busiest trunks | DEL, BOM, BLR, HYD | 85 | 0.90 to 1.30 |
| Bulbul Air | Low-cost | BLR, MAA, CCU | 30 | 0.90 to 1.30 |
| Myna Regional | ATR 72 short hops | HYD, BLR | 12 | 1.05 to 1.60 |
| Hornbill Airways | East and North-East | CCU, GAU, BBI | 12 | 0.95 to 1.40 |
| Flamingo Air | Kerala and Mumbai to the Gulf, leisure | COK, BOM, TRV, CCJ | 11 | 0.90 to 1.40 |

- **Sizing.** Built route by route from the demand model so that on the busiest routes they run about 87% full at reference fares; each of the eight busiest domestic routes has at least one of them from day 1. Together they are about a fifth of the market.
- **Standing.** Established incumbents: aircraft on operating leases outside the lessor pool, aged 0 to 8 years, no deposits. Their owners stand behind them: they never go into administration and they are not ranked. Their names and codes are reserved.
- **Daily fares**, from the last 7 days' load factor: above 88% fares rise 3%; below 78% they fall 3% and follow the cheapest rival. Always within the band and never below the fare at which the route breaks even at an 80% load. On routes from their own bases they defend down to a lower floor (0.05 to 0.10 below the band) when a player undercuts them.
- **Each quarter** they move up to 3 aircraft from routes below 75% full to routes above 90%; hand back up to 2 aircraft from routes below 70% (they go to the lessor pool, for players; every route keeps at least one); and add up to 2 aircraft, from their own orders, to routes above 85% full with fares in the top half of the band, up to twice the starting fleet.
- They act through the same public action functions as players, called from the engine with no user id.

**Rules settled in this stage.**

| Topic | Rule |
|---|---|
| Founding (item 8) | A new airline gets one wet-leased A320neo in the standard cabin (an ATR 72 at a turboprop-only base), flying from its first day, at the normal wet-lease rate. An airline founded before the world starts flies on day 1 |
| Lessor pool (item 9) | One airline can lease at most 6 aircraft from the pool in any 91 game days, so no early joiner can corner it |
| Demand (item 10) | Nested logit, λ = 0.5. The constants `a` rise by (1 − λ) x ln 3 (business 0.10, leisure 2.37, budget 4.14), so three airlines with four flights a day each at reference fares still carry 65% of potential. One airline with all twelve flights now carries 63% (was 50%); twelve airlines with one each, 69% (was 82%) |
| Business cabin | Business travellers add −2.2 to the business cabin's utility. On a domestic trunk about 9% of a full-service airline's business travellers then buy its business cabin at the reference business fare; on long haul about 32% (was 89% and 97%, which kept every business cabin full) |
| Spill (item 12) | Half of the business-cabin overflow takes economy on the same airline. Other spilled travellers try airlines with seats left in the same cabin in proportion to how attractive they are; the share who find a seat is 60% x P(fly with the airlines that have seats) / P(fly with all of them). A rival at twice the fare now picks up about 8% of them (was 60%) |
| Spare cover (item 12) | An aircraft with no rotations, of the same type, at the same base and in the same airline flies a grounded aircraft's rotations that day, with its own cabin |
| Aircraft loans (item 13) | Pay plan `loan`: 15% deposit on ordering; on delivery the balance is borrowed in dollars at 8% a year and repaid in equal daily principal over 12 years. Interest is a financing cost; principal is cash, not cost. Selling repays the loan; net worth subtracts it |
| Season score | Net worth + 5 x profit after interest of the last four quarters (was operating profit: that left out loan interest, so buying every aircraft with a loan would have scored about Rs 110 crore more per aircraft a year than leasing) |
| Slots (item 11) | `1,500 / (1 − utilisation)^2` per movement, utilisation priced at 90% at most: Rs 1.5 lakh at a full airport (was Rs 12 lakh, 400x the base). Caps scale with `demand_scale x slot_scale` |
| Reference fare | `Rs 2,100 + 3.3 x km` (was 1,800 + 3.4): a leased A320neo at an 85% load now earns about 7% before head office on any route length (was −2% on 300 km and +7% on 2,800 km) |
| Overheads | Rs 6 lakh a day, Rs 1,000 per seat in the fleet a day (was Rs 1.8 lakh per aircraft, the same for a 180-seat A320neo) and Rs 1.5 lakh per base |
| ATR maintenance | $300 a flight hour and $100 a cycle (was $450 and $150): about $350 a block hour, in line with published ATR 72 costs. An ATR at an 85% load earns about 15% on 250 km and 9% on 400 km at reference fares |
| Currency | No steady fall of the rupee (was 3% a year). Fares are fixed in rupees, so the drift took about a point of margin a year from every airline. Daily moves and currency swings remain |

**Check against reality** (local test, deterministic): a player at twice the reference fare on Delhi–Mumbai sells 7 of 1,080 seats on day 1 against the computer-run airlines (item 7; it used to fill the aircraft); the Stage 2b unit-cost check (leased A320neo, Delhi–Mumbai, 85% load, reference fare) now gives cost per seat-km Rs 4.34, revenue per seat-km Rs 4.72 and an 8.1% margin (was 4.35, 4.58 and 5.0%).

**Season check** (`tools/pgtest/season.mjs`: the six computer-run airlines plus 18 simulated players, two each of nine strategies, at `demand_scale` 0.36; random prices, events and groundings on; full season of 2,366 game days in about 15 minutes). Margin is operating margin; load is passenger load factor.

| Game year | Computer-run airlines | All players (revenue-weighted) | Best three players |
|---|---|---|---|
| 1 | −8% at 72% | −15% at 74% | +4%, +2%, 0% |
| 2 | +2% at 78% | −1% at 79% | +14%, +12%, +12% |
| 3 | +8% at 81% | +3% at 80% | +18%, +15%, +13% |
| 4 | +7% at 80% | 0% at 83% | +19%, +14%, +12% |
| 5 | +10% at 82% | +4% at 83% | +21%, +19%, +15% |
| 6 | +8% at 81% | +4% at 84% | +22%, +18%, +17% |
| 7 (half) | +8% at 81% | +5% at 85% | +21%, +18%, +17% |

- **Calibration bands.** From year 3 the computer-run airlines hold 7 to 10% at 80 to 82% load, and trunk fares settle at 1.1 to 1.4 times the reference. Year 1 is a shake-out: every new airline adds capacity at once while the incumbents shed only two aircraft a quarter.
- **Strategies.** Final scores, best instance first (Rs crore): long haul 12,083 and −25; full service 6,319 and 1,740; low-cost trunk 6,158 and 1,375; buying with loans 464 and 125; turboprop regional −159 and −243; secondary routes −283 and −539; Gulf −387 and −584; buying for cash −776 and −785; wet lease only −1,316 and −1,397. Three different strategies take the top three places, and no strategy wins with both its airlines: long haul has the highest upside and the highest risk (in an earlier run both long-haul airlines finished on top after five administrations between them). Wet leasing as a way of life loses heavily, as intended.
- **Slots.** At season end Bengaluru, Pune, Mumbai and Delhi run at 80 to 89% of their scaled caps, which prices a movement at Rs 37,000 to Rs 1.2 lakh. Turboprops feel it most, which is the intended push towards bigger aircraft or other airports.
- Earlier runs during tuning (recorded here because each changed a rule above): with the old reference fare everyone lost money; with the computer-run airlines following rivals to 0.65x and never adding aircraft, the market swung from losses in year 1 to 20 to 29% margins by year 6.

**Speed.** In the in-memory test database a game day takes about 100 ms with the computer-run airlines at full scale (223 aircraft), and 690 ms in the 50-airline load test (Stage 2b: 450 ms). The demand step works in double precision: with exact decimals the load test took 1.9 seconds.

### 14.4 Stage 3 as built (the app)

**One app for phone and laptop.** React and TypeScript in `app/`, built with Vite and published to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that touches `app/`. Address: `https://<owner>.github.io/airline-game/`. Below 1,024 px wide it has five tabs at the bottom (Home, Network, Fleet, Money, Ranks); from 1,024 px a sidebar, with two-column pages and tables in place of cards. It installs to a phone's home screen and caches its own files; game data always comes live from the server. Fonts are bundled, so nothing loads from a third party.

**Sign-in (section 14).** The `join` edge function (`supabase/functions/join`, deployed with JWT checks off) takes email, password and invite code, checks the code and creates a confirmed account, so joining never depends on email delivery. The app then signs in with the password and founds the airline through `found_airline`, which checks the code again. An invite link is `.../#/join?code=<code>`. There is no password reset by email; an admin resets a forgotten password.

**Admins.** `profiles.is_admin` (set by the owner through the database) shows an Admin screen: the world's invite link (new function `admin_world_invite`, migration `0008_app_support.sql`, admins only) and start, pause and resume. Migration 0010 adds `admin_set_speed(world, minutes per game day)`, 5 minutes to 24 hours, on the same screen. The world keeps the day it has processed and the next day starts counting at the new pace, so nothing jumps; every rule stays in game days, so lead times, groundings and the 14 days before administration shrink in real time with the clock.

**Screens and actions.** Every player action in 14.2 has a control:

| Screen | Shows | Actions |
|---|---|---|
| Setup | Bases sorted by traffic, runway limits, what the airline starts with | `found_airline` |
| Home | Cash, yesterday's profit, load factor, on-time and brand; alerts with a fix or a link (full route with one-tap 5% fare rise, half-empty route, cheaper rival, idle or grounded aircraft and its cover, arriving aircraft, long wet leases, insolvency); a three-step start guide; 28-day profit; news | `set_fares` |
| Network | Vector map (countries from world-atlas, drawn on the device; drag, pinch, India and world views) with bases and routes coloured by load factor; routes with 7-day load, fare against reference and trips | `open_base`, `open_route` |
| Route | 7-day load, passengers, spill, revenue and flight profit; 28-day load chart against the 80 to 88% band; rivals' public fares, trips and seat share; aircraft on the route | `set_fares`, `set_rotation`, `close_route` |
| Fleet | Each aircraft's job, use of its flying day, holding and cost, status; filters | |
| Aircraft | Use of day, routes, cabin, terms | `set_rotation`, `rebase_aircraft`, `return_aircraft` |
| Configurator | To-scale seat map; seats, crew, range, turnaround and comfort from `layout_calc` | `refit_aircraft`, `order_aircraft` (cash, loan or leaseback) |
| Get aircraft | Lessor pool grouped by cabin and age with rent, the pool limit left, order prices and delivery, wet-lease rates | `lease_aircraft`, `wet_lease` |
| Money | Profit and loss for a day, 7 or 28 days by cost line, unit revenue and cost, quarterly results, one-off payments | `borrow`, `repay`, `set_marketing` |
| Ranks | Leaderboard by score with side boards (margin, load, on-time), world events, news | |

**Design choices.** No demand preview: the route screen shows the reference fare, rivals' fares and recent results, never a predicted passenger count, so players learn to judge fares instead of reading the model. Rotation limits shown in the app (round trips a week an aircraft can still fit) mirror the server's rule and are checked again there. Teal marks actions, amber anything needing attention, always with words.

**Local test.** `tools/localstack/run_e2e.sh` builds the whole back end in a local Postgres 16 (every migration), runs `shim.mjs` in place of Supabase's sign-in, REST and the join function (same row-level security, since each request runs as the caller's role), builds the app against it and drives it with Playwright at phone (390 x 844) and laptop (1440 x 900) sizes: join from an invite link, found an airline, start the world as admin, and use every action in the table above across 50 game days. It saves screenshots and fails on any page error or failed action.

### 14.5 Computer-run airlines contest player routes (migration 0009)

Asked for by the owner after Stage 3: rivals that "stay smart enough". Before this, the computer-run airlines' route networks were fixed, so a player could find a route none of them flew and keep it uncontested all season. The aim is rivals that punish an easy, uncontested profit, not rivals that play perfectly. Every number is (G) in `game_params`.

| Rule | Value |
|---|---|
| When | At each quarter end, after the existing moves, returns and additions |
| Which routes | A city pair players have flown for at least 28 days, at 85% load or more over the last 28 days, with their lowest economy fare at or above the reference fare, flown by fewer than 3 airlines, with one end at a base of the computer-run airline |
| How many | Each computer-run airline starts at most 1 such route a quarter; two never enter the same pair in the same quarter; the pair with the most player revenue goes first |
| Aircraft | Taken from its own emptiest route that has two or more aircraft, moved to the base if needed. No new aircraft are added for this |
| Entry fare | 95% of the players' lowest fare, inside the airline's band; then the daily pricing rules take over, including defending a base route |
| Giving up | After 56 days, a contested route below 60% load over 28 days is closed and its aircraft go back to the lessor pool. No computer-run airline contests that pair again for 364 days. Starting-network routes are never given up this way |
| News | Public news items: "Koel Air starts flying Delhi to Patna, against the airlines already there." and "... stops flying ..." |

**Season check** (three full-season runs with contesting, one without; same set-up as 14.3; single runs vary a lot, so read the direction, not the exact figures). With contesting, players' revenue-weighted margins in years 2 to 5 were 2 to 8 points lower than without; final-year results stayed within the run-to-run spread (players +3% to +13%, computer-run airlines +10% to +19%). In one run the computer-run airlines started 69 contested routes over the season (about 3 a quarter across the world), gave up 46 and kept 23. Long haul, full service and low-cost trunk stay the three best strategies; wet-lease-only, regional and niche routes still lose money.

### 14.6 Bulk orders, bulk leases and extras (migration 0011)

Asked for by the owner after the first playtest evening.

**Bulk orders and leases.** `order_aircraft_bulk` orders up to 10 new aircraft of one type and cabin at once; each takes the next delivery slot (three A320neos ordered together arrived on days 547, 553 and 559 in the test). `lease_aircraft_bulk` leases up to 10 aircraft from the pool at once; the app picks the youngest of the chosen group (same cabin, same age band). Both are all or nothing, and the pool limit of 6 in any 91 days still applies, with a message saying how many are left.

**Extras.** Four extras, each either sold at a price or included free, set once for the whole network (`set_extras`). Prices are multiples (0.25 to 3) of a reference price that follows each route's reference fare, so one setting works from short hops to long haul. Every number is (G) in `ancillary_products` and `game_params`.

| Extra | Reference price (share of the reference fare) | Bought at the reference price | Used when free | Cost when free (share of the reference fare) | Who counts its price: business / leisure / budget |
|---|---|---|---|---|---|
| Checked bag | 17% | 35% | 55% | 3.0% | 30% / 50% / 40% |
| Seat choice | 6% | 30% | – | 0 | 50% / 30% / 10% |
| Meal on board | 6% | 22% | 85% | 4.0% | 40% / 30% / 10% |
| Priority check-in and boarding | 7% | 7% | 15% | 0.5% | 30% / 5% / 2% |

- **Take-up** of a sold extra falls with its price: share x exp(−0.6 x (multiple − 1)).
- **Choice.** Travellers judge the trip price. For each segment, the economy fare in the utility (section 4) becomes `fare / reference + Σ w x reference share x (multiple − 1)` over sold extras, minus `w x reference share` for each extra included free. Selling everything at the reference price changes nothing, so the tuning in 14.3 holds for an airline that never touches its extras.
- **Revenue and cost.** Extras earn `Σ reference share x multiple x take-up` of the reference fare per economy passenger (9.6% when everything is sold at the reference price, the same as the old 8% of a fare 1.2 times the reference). Business-cabin passengers get everything included and add 8% of their fare. Extras included free cost money per passenger, booked with distribution and service.
- **What it teaches.** Including everything works like a fare cut of about 12% of the reference fare for leisure travellers, at a cost of about 15%: in the test, an airline including all four extras carried 176 passengers a day against 90 for an identical airline selling them, but earned nothing from extras. Meals cost more to include than travellers value them; seat choice and priority are cheap to give and business travellers notice; bags win leisure-heavy routes.
- The computer-run airlines sell every extra at the reference price.

### 14.7 Route studies (migration 0012)

Asked for by the owner on 19 Nov 2026, taken from Airlines Manager's route audits (18.3).

- `route_study(airline, a, b, 'quick' | 'full')` costs Rs 5 lakh (quick) or Rs 40 lakh (full) (G), booked as a one-off cost on the next game day. Results are private to the airline (`route_studies`, read-own).
- **What it shows**, all as ranges: travellers flying the city pair each way a day with every airline, travellers turned away, and how full all airlines' flights are, over the last 28 days. None of this is otherwise visible: players only see their own loads and rivals' fares and schedules. For a pair nobody flies: travellers who would fly with one airline flying twice a day at the reference fare (the section 4 utility with a standard A320neo cabin and a brand of 50).
- **Full study adds** the business, leisure and budget mix and next quarter's demand against today (season and growth).
- **Error.** Each figure gets its own random error (standard deviation half the range width), then the range: ±35% for a quick study, ±12% for a full one (G). A study is usually right, sometimes off, so a second opinion has value.
- **App.** A Route study card in the open-route sheet and on Route detail shows the latest study of that pair while it is under 91 game days old (G).
- **Tested.** Local checks (150 in all) and a rolled-back live run in Test World: on Delhi–Hyderabad a full study gave 3,504 to 4,460 travellers a day each way against an actual 4,079, 39 to 50 turned away against 49, and 78 to 88% full against 80%.

### 14.8 Pilots and places (migrations 0013 to 0015)

Asked for by the owner on 19 Nov 2026, to go in before World 1 starts. Pilots, not aircraft, held back Indian airline growth in 2025: IndiGo cancelled over 4,500 flights in early December 2025 when stricter duty-time rules met a thin crew buffer, while Akasa kept spare pilots and cancelled nothing (sources in 17). Each world has `pilots` on by default; off means the flat pilot cost per aircraft of 14.2. Every number is (G) in `game_params` and `pilot_families`.

**Need.** Pilots fly one fleet family: ATR, A320 family (A320neo, A321neo, A321XLR) or A350. A family needs captains and first officers, one each per flight, for the block hours it flies: `need = block hours a day / 2.4 x 1.15` per rank (2.4 hours a pilot a day under the duty-time rules; 15% for leave, training and sickness). Flights over 8 block hours carry 1.5 times the pilots. Aircraft arriving within 63 days count, and an aircraft with no flights yet is planned at 70% of its flying window. Wet-leased aircraft bring their own crew. A320neo flying 12.5 block hours a day: 6 captains and 6 first officers, 13 pilots with the default 10% spare (IndiGo ran about 14 per aircraft).

**Short of pilots.** A family's crews can fly `least(captains, first officers) x 2.4 / 1.15` block hours a day. Beyond that, flights are cancelled at random, which costs brand as before. Spare aircraft do not help.

**Getting pilots** (the engine hires every day up to `need x (1 + spare)`; nobody hires one by one):

| Source | Joins in | Cost | Limit |
|---|---|---|---|
| World pilot market | 28 days | Salary | 60 per rank and family per airline in any 91 days; best payers pick first |
| Command upgrade of own first officers (captains only) | 91 days | Rs 10 lakh each | 10% of the airline's first officers a quarter (at least one) |
| Foreign captains, the last resort | 56 days | 1.8 x market pay | None |

**Market.** Per world and family: a pool of captains and first officers. Target per place: ATR 4 and 6, A320 family 20 and 30, A350 3 and 4. It opens at 2.5 times the target, gains a quarter of the target a quarter (newly qualified) and loses a quarter of itself a quarter (abroad, other work). Market pay = `1 + 0.6 x (1 - captains / target)^2`, moving 3% of the gap a day. Pilots who leave an airline return to the market.

**Pay** (market pay index 1, a day; migration 0015): ATR captain Rs 13,800 and first officer Rs 6,300; A320 family Rs 17,800 and 8,100; A350 Rs 23,500 and 10,700. 0013 set them 10% higher, matching the old flat cost per aircraft at 12.5 block hours a day; the season runs (17, item 23) showed buffers, crews hired ahead of aircraft and cancellations adding 4 to 6 points of cost, so the owner had them brought back down. Flying pay per block hour stays. Each airline sets its pay level against the market (0.8 to 1.5).

**Resignations.** 5% a year at market pay, times `exp(-5 x (pay level - 1))`, times `exp(4 x (best rival pay level - own))` when a rival pays more, times 1.5 while short of pilots and 2 while cash is below zero. Captains serve 364 days of notice, first officers 182, and keep flying meanwhile; the airline gets a news item. Foreign captains do not resign.

**Surplus.** Pilots above `need x (1 + spare) x 1.25` are let go with 91 days of pay; foreign captains go first.

**Duty-time rules.** At most once a season the regulator cuts the hours a pilot may fly by 10%, announced 91 days ahead (about once in 2.5 game years). Hiring plans for the new rule once it is within 63 days; airlines with thin buffers and an empty market cancel flights.

**Computer-run airlines** get their crews outside the market on day 1 (like their aircraft), then hire, resign and are poached like anyone else, at market pay, 10% spare, foreign captains allowed. A world already running when pilots arrive gives every airline its need plus 10%.

**Pilots are one lever, not a screen to manage** (owner, 19 Nov 2026). Players set two things (`set_pilot_policy`): pay against the market and spare pilots (0 to 40%). They see two numbers, on a Pilots card at the top of Fleet: pilots against need (with a "Short by" badge) and salaries a day. Everything else runs on its own: hiring, promotions, and foreign captains as the last resort for every airline (0015). The engine also supports cadets and switching foreign captains off per airline; neither is a player setting, and cadets are off. Home warns when a family is short; resignations arrive as news.

**Places (principle 7).** `admin_set_places(world, places)` sets `max_airlines` and `demand_scale = places / 50` together; before the start any value from 2 to 200, once running only upwards. Extra places add their share of pilots to the market at once; the lessor pool and delivery slots follow through their quarterly refill. Migration 0013 also set both live worlds to 25 places: they had 50, so their lessor pools, delivery slots and (now) pilot markets were sized for twice the players their demand was set for. The admin screen has the control.

**Tested.** 24 new local checks (174 in all) and the app test. Season runs with and without pilots: 17, item 23.

### 14.9 Database changes on merge (workflow)

The owner works from a phone, and the Supabase tool's approval prompt for changes that look destructive does not appear in the phone app (19 Nov 2026: three tries timed out). So database changes now reach the live database through GitHub, like the app.

- `.github/workflows/db.yml` runs `tools/db/apply.sh` when a push to `main` touches `supabase/migrations` (or by hand from the Actions tab). It applies, in name order, every migration file the live database has not had, each in one transaction together with its row in `game.applied_files`, so a file is applied completely or not at all, and never twice. It ends by printing the md5 of every function in `game` and `public`, to compare with the local test database.
- Files applied by hand before the workflow existed (0001 to 0013) are listed in `supabase/applied_before_workflow.txt` and recorded without running.
- **Merging the pull request is the approval.** There is no second confirmation, so a migration must be reviewed before merging.
- It needs the repository secret `SUPABASE_DB_URL`: the Session pooler connection string from the Supabase dashboard (Connect), with the database password in it. It is never printed or committed.
- 0013 was split on 19 Nov 2026 at the point that went live through the tool: 0013 (tables, settings, pilot functions) is live; 0014 (the day engine, letting pilots go on administration, the daily pilot step, 25 places for both worlds, crews for running worlds) and 0015 (pay 10% lower, foreign captains automatic) are the first files the workflow applies. Tested locally against a copy of the live state: both applied, a running world got crews (no airline short), and a second run applied nothing. First live run on 19 Nov 2026 (13:47 IST): 0014 and 0015 applied, all live functions match the local test database, both worlds at 25 places, and Test World's nine crews at need plus 10%.

## 15. Screens

Home (cash, yesterday's results, alerts) · Map and network · Route detail (fares, rivals, load factor) · Fleet · Configurator · Aircraft market · Finance · Leaderboard · News · Airline setup · Admin.

## 16. Build stages

| Stage | Output | Done when |
|---|---|---|
| 1 | This spec | Reviewed |
| 2a | Database, rule functions, aircraft, airports, markets | Seat counts, distances and traffic totals match this spec in the live database |
| 2b | Player actions and the daily engine | One game day runs end to end for a test airline |
| 2c | Bot airlines and tuning | Bots play a full season; margins and load factors land in the calibration bands; no single strategy dominates |
| 3 | App screens | Every MVP action works from a phone (built: 14.4) |
| 4 | Hosting, sign-in, admin | A colleague can join from a link and play (built with Stage 3: 14.4; open until the first colleague joins) |
| 5 | Playtest with 6 to 8 people, then tune | Two game years played without a rules fix |

## 17. Open items and sources

**Open items**

1. A320neo certified maximum of 194 seats is from memory; confirm in Stage 2.
2. The Indian cabin crew rule comes from an older quoted text of the Aircraft Rules; confirm the current wording.
3. Use real aircraft type names or generic ones.
4. The repo is public. Decide whether the game's code should stay public.
5. Trunk routes between two metros come out 20 to 70% above real traffic, and metro to small-city routes below it. Tune in Stage 2c.
6. Passenger numbers for the 44 smaller Indian airports and all international shares are estimates. Replace with published figures where available.
7. Settled in Stage 2c (14.3): six computer-run airlines contest the trunk routes from day 1.
8. Settled in Stage 2c (14.3): founding comes with one wet-leased A320neo that flies on day 1, at the normal wet-lease rate.
9. Settled in Stage 2c (14.3): at most 6 pool aircraft per airline in any 91 days. Early joiners still get the lower rent until their leases renew (728 days, about 8 real weeks).
10. Settled in Stage 2c (14.3): nested logit; splitting the same flights among more airlines barely adds travel.
11. Settled in Stage 2c (14.3): 100x the base at a full airport; caps scale with `demand_scale`. Re-check once a full world (50 players) is running.
12. Settled in Stage 2c (14.3): business travellers move down to economy; an idle aircraft at the same base covers a grounded one.
13. Settled in Stage 2c (14.3): aircraft loans; the season score counts profit after interest.
14. Owner to confirm: the season score now uses profit after interest instead of operating profit (section 11). Without it, buying every aircraft with a loan would dominate the score.
15. Long haul has the highest upside in small worlds: beyond London and Singapore no computer-run airline flies long haul. Consider more Sarus long-haul routes or a second long-haul carrier after the playtest.
16. Small airlines (1 to 3 aircraft) carry the full Rs 6 lakh a day of head office, and turboprops pay the same slot price per movement as an A350: the simulated turboprop and secondary-route players never grew past a few aircraft, and Myna Regional ends the season far below break-even once Bengaluru and Hyderabad fill up (computer-run airlines keep one aircraft on every route of their network, so it cannot leave). Watch this in the playtest before changing it; a slot price per seat rather than per movement is one option.
17. The simulated players in `season.mjs` are simple rules, not people. Results for year 1 (everyone losing money) depend on how fast players add capacity; re-check with the playtest (Stage 5).
18. Set a world's `demand_scale` to about (expected players / 50) before starting it: demand, computer-run fleets and slot caps all scale with it. World 1 is set to 0.5 for at least 25 players.

19. Myna Regional and Flamingo Air lose money in every season run (about −12% to −136% margin at `demand_scale` 0.36), with or without contesting. Computer-run airlines never fail, so they keep flying; tune their starting networks, or let them shrink further, before World 1 starts.
20. An AI strategist for the computer-run airlines (a model choosing once a quarter which routes to enter and how hard to price, through the same functions) was suggested by the owner. Deferred until the playtest shows whether the rules in 14.5 feel predictable. It would need an Anthropic API key held as a server secret and makes season runs non-repeatable.

21. Clock for World 1. The owner found an hour per game day slow in Test World, which now runs at 15 minutes a day (96x). At that pace a season lasts about 25 real days instead of 26 weeks, a quarter passes in under a day, and an airline can go from first cash trouble to administration in about 3.5 hours, so a colleague who checks once a day can miss it. World 1 is set to 60 minutes a game day for now (season about 14 weeks, a quarter about 4 days, administration after about 14 hours of trouble); the owner will revisit it before the start.

22. Second currency (owner asked whether to copy Airlines Manager's). Recommendation: no. Airlines Manager's premium currency exists to sell subscriptions and packs that speed things up; here it would either buy nothing or buy speed, which breaks principle 6 and the teaching aim. Rupees stay the only currency; the second scarce resource is pilots (18.4). Owner to confirm.

23. Pilots and the season (two pairs of full-season runs, with and without pilots, 18 players and 18 places; single runs vary a lot). Players' revenue-weighted operating margin, years 3 to 6: with pilots −3.4/−4.1, −2.5/−3.4, +6.7/−2.2, +0.9/−1.0%; without −3.3/+3.3, −5.0/+7.4, +2.2/+9.2, +4.5/+8.6%. Computer-run airlines in year 6: +7.2/+10.6% with, +13.8/+15.5% without. So pilots cost about 4 to 6 points of margin late in the season, for players and computer-run airlines alike: crew cost per seat-km about 10% higher (buffers, crews hired ahead of aircraft, more pilots at high utilisation), cancellations of 1 to 3% in thin years against under 0.5%, and the A350 market running dry once long-haul players grow (market pay 1.4 to 1.6 for that family). Three strategies still lead (low-cost trunk, full service, long haul or a second low-cost trunk). The owner chose to trim pilot pay 10% (migration 0015). The runs also took about twice as long a game day (pilot step), well inside the 2-second target on the live database.

**Sources for (V) figures**

- Indian airport passengers, FY 2025-26 (Airports Authority of India data): https://en.wikipedia.org/wiki/List_of_busiest_airports_in_India
- Airport coordinates: OurAirports open data, https://github.com/davidmegginson/ourairports-data
- Airbus A321XLR: https://aircraft.airbus.com/en/aircraft/a320-family/a321XLR
- A320 family ranges: https://knaviation.net/a320-vs-a321/
- ATR 72-600: https://www.atr-aircraft.com/our-aircraft/atr-72-600/ and ATR fact sheet https://cdn.pista73.com/media/2012/07/ATR_72-600.pdf
- Airbus A350 facts and figures (Oct 2024): https://www.airbus.com/sites/g/files/jlcbta136/files/2024-10/Airbus-A350-Family-Facts-and-Figures-October-2024.pdf
- Cabin crew, one per 50 seats: https://flightsmilesandpoints.com/aviation/how-many-cabin-crew-per-flight/ and https://www.easa.europa.eu/en/the-agency/faqs/minimum-required-cabin-crew
- Indian rule text as quoted: https://www.pprune.org/6262435-post641.html
- Lease rate bands, 2026: https://safefly.aero/blog-a320ceo-vs-a320neo/
- Pilot notice periods (commanders one year, first officers six months): https://www.hrkatha.com/?p=38624 and https://www.thecore.in/business/why-indias-pilots-say-dgcas-anti-poaching-aviation-airline-the-point-842254
- IndiGo's December 2025 crew shortage under the new duty-time rules: https://www.businesstoday.in/latest/corporate/story/big-expansion-small-team-indigo-expanded-by-200-flights-a-day-but-hired-only-418-pilots-505541-2025-12-08 and https://superkalam.com/current-affairs/11-02-2026/a-reckoning-for-india-s-aviation-sector-pg8-2aecfcc3-2131-40aa-90ac-c6c018437fc9
- Akasa's spare pilots and India's pilot pipeline: https://www.100knots.com/indigos-massive-pilot-hiring-spree-inside-indias-aviation-crisis-and-recovery-plan/

## 18. Roadmap

Set 19 Nov 2026 with the owner. Each later feature unlocks per airline, inside a season, once the airline is ready for it; it must be live before the first airline in World 1 could reach it. At World 1's clock of 60 minutes a game day, game day 365 comes about 15 real days after the start and day 729 about 30 days after.

| When (real time) | What |
|---|---|
| 19 Nov | Bulk orders and leases, extras (14.6) |
| 19 Nov | Route studies (14.7) |
| 19 Nov | Pilots and places (14.8), before World 1 starts |
| Test World playtest, next few days | Fix what the owner finds; watch pilots |
| Before World 1 starts | Tune Myna Regional and Flamingo Air (item 19); confirm the clock (item 21) |
| World 1 start + 10 days | Cargo live (unlocks from game day 365) |
| World 1 start + 25 days | Loyalty live (unlocks from game day 729) |
| Season 2 | Alliances and codeshares, freighters, loyalty tiers |

### 18.1 Cargo (belly cargo first)

- **Unlocks** for an airline at least 1 game year old with at least Rs 250 crore of revenue in its last quarter (G). Starting cargo sales costs Rs 10 crore once (G) for the sales team and handling contracts.
- **Demand.** Each market gets cargo demand in tonnes a day from the same gravity model as passengers, weighted by the airports' business index and a new cargo index (Delhi, Mumbai, Bengaluru, Chennai and the Gulf high) (G). Grows 5% a year (G).
- **Capacity.** Belly space left after passengers' bags: about 0.5 tonnes on an ATR 72, 2 on an A320neo, 3 on an A321neo, 16 on an A350 (G, to check against published figures). Fewer bags when bags are sold rather than included.
- **Price.** One rate per kg for the whole network as a multiple of a reference rate that rises with distance; airlines share demand by price and frequency like passengers.
- **Cost.** Handling per kg, a small fuel penalty for the weight, distribution share.
- **Teaches.** Belly cargo as extra revenue on flights already flying, why widebodies earn more from it, and how bag policy and cargo compete for the same space.
- **Later.** Freighters (a converted A321 and a widebody freighter) in season 2.

### 18.2 Loyalty programme

- **Unlocks** for an airline at least 2 game years old, with a brand of 55 or more and 2 million passengers carried (G). Launching costs Rs 25 crore (G).
- **Members.** A growing share of an airline's passengers join, faster with more flights from their city. Members prefer their own airline: a utility bonus, largest for business travellers (G).
- **Points.** Members earn points on every fare. Points are a liability: part of each fare is deferred until the points are used or expire (breakage).
- **Redemptions.** Award seats come from seats that would otherwise be empty, so they cost little on half-empty flights and displace paying passengers on full ones. The player sets how many award seats a flight may carry.
- **Co-brand card.** A partner bank buys points to give its card holders: monthly income in proportion to members, often the programme's biggest earner (G).
- **Decisions.** Earn rate, award-seat availability, and whether to sign a co-brand card. Tiers (silver, gold) come in season 2.
- **Teaches.** Loyalty economics: the liability on the balance sheet, displacement cost, partner income and the value of retention.

### 18.3 Ideas from Airlines Manager

Airlines Manager (Playrion) offers real-time and fast modes, an R&D centre with over 500 research items, more than 200 services, buying hubs at airports, aircraft maintenance, a second-hand market where players trade aircraft by bidding, and alliances. Route audits show a demand estimate with a marker of how reliable it is. Filtered through this game's principles (every feature teaches a real trade-off; five minutes a day is enough):

| Idea | Verdict | When |
|---|---|---|
| Route study: pay to see a demand range for a city pair, wider when cheap | Take. Fits the rule that the game never shows an exact demand figure | Done (14.7) |
| Route ramp-up: a new route starts below its full demand and builds with time and frequency | Take. Real airlines lose money on new routes for months | After cargo |
| Second-hand market between players | Leave out, for good: it makes aircraft plentiful (principle 6) | – |
| Premium second currency | Leave out: it exists to sell speed-ups (item 22) | – |
| Alliances and codeshares between players | Take | Season 2 |
| Real-time and fast modes | Already covered by the per-world clock (`admin_set_speed`) | Done |
| Services catalogue | Started with extras; business lounges at bases later | Later |
| R&D tree, managers and staff, buying airports | Leave out: they add time per day without teaching an airline trade-off | – |

### 18.4 Pilots

Built: section 14.8.
