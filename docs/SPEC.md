# Airline Game: Game Spec v0.1

Status: v0.3, 17 Nov 2026 (Stage 2b built: player actions and the daily engine, section 14.2). Source of truth: `docs/SPEC.md` in the `airline-game` repo.

Number labels used below: **(V)** verified against a public source listed in section 17. **(G)** game value: a starting number chosen for play balance, to be tuned in Stage 2. Nothing here uses internal airline data.

## 1. Purpose and principles

A persistent multiplayer airline business game for office colleagues, built to teach commercial sense.

1. **Shared market.** Players compete for the same passengers, aircraft and slots. Nobody profits in isolation.
2. **Realism lives in the trade-offs**, not in detail for its own sake. Every feature must teach a real airline trade-off.
3. **Scarcity sets the price and never says no.** There is always a way to get capacity; the question is what it costs.
4. **Server decides everything.** Phones only display and submit decisions, so nobody can cheat and nothing depends on a phone being open.
5. **Five minutes a day** is enough to play well.

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

`share_k = exp(U_k) / (1 + sum of exp(U_j))`. The "1" is the option of not flying, so cheaper fares grow the whole market and a monopolist who overprices loses travellers to the road.

| Segment | Price b | Frequency c | Comfort d | Brand e | Cabins considered |
|---|---|---|---|---|---|
| Business | 1.6 | 0.9 | 0.50 | 0.6 | Business, economy |
| Leisure | 3.0 | 0.4 | 0.25 | 0.4 | Economy |
| Budget and family visits | 4.5 | 0.25 | 0.10 | 0.2 | Economy |

All coefficients (G). Reference economy fare (G): `Rs 1,800 + 3.4 x km`. Business reference: 3.5x economy.

**Capacity.** If demand exceeds seats, the overflow is spilled: 60% try the next best airline with free seats, the rest do not travel (G).

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
| New order from the manufacturer | 6 to 8 weeks | 1.5 to 2 years | Cheapest per month. 15% deposit, balance on delivery (cash or sale-and-leaseback) |

- **Lessor pool.** Finite per type and world, sized to the number of airlines, with a mix of ages. `rent = base x (1 + 1.5 x (1 - available / target)^2)`. Refills each game quarter.
- **Manufacturer queue.** Fixed delivery slots per game quarter per type. Every order joins the queue, so a rush of orders lengthens everyone's wait and raises the price.
- **Age.** Older aircraft rent for less, burn more fuel (+0.5% a year), cost more to maintain (+3% a year) and ground more often (G).
- **Groundings.** Random technical groundings per aircraft, plus occasional fleet-wide engine events that ground a share of one type for weeks.
- **Player market (after MVP).** Sell or sublease aircraft, delivery slots and airport slots to each other.

## 7. Network, scheduling and slots

- **Bases.** Aircraft live at a base. Every route starts at one of the airline's bases. Opening a base costs money.
- **Rotations.** `block_hours = km / cruise + 0.7` (0.4 for the ATR). `rotation = 2 x block + 2 x turnaround`. An aircraft's rotations must fit its window, counted over a week: 17 hours a day for narrowbodies and turboprops, 20 for the A321XLR, 22 for widebodies (G). Frequencies are set as round trips a week.
- **Check:** Delhi to Mumbai at 1,150 km gives a 2.09 hour block and a 5.2 hour rotation on a 186-seat A320neo, so three round trips a day and 12.5 block hours.
- **Slots.** Congested airports have a daily movement cap. `price per slot = base / (1 - utilisation)^2`. A full airport forces bigger aircraft, off-peak flying or a secondary airport.

## 8. Revenue

- One fare per cabin per route in the MVP, changeable any time, effective next game day.
- The route screen shows the reference fare, rivals' public fares and frequencies, and yesterday's load factor and spill.
- Ancillary revenue: flat 8% of ticket revenue in the MVP (G); later a set of choices (bags, seats, meals).

## 9. Costs

| Cost | Driver | Currency |
|---|---|---|
| Fuel | Sector fuel x fuel price (starts Rs 100 / kg, moves with a random walk and shocks) | Dollar-linked |
| Aircraft rent or ownership | Per month per aircraft | Dollars |
| Maintenance | Per flight hour and per flight, rising with age | Dollar-linked |
| Crew | Pilots per aircraft; cabin crew by the seat rule; per block hour plus fixed | Rupees |
| Airport and navigation | Landing by aircraft size, per passenger handling, per km | Rupees |
| Slots and bases | Section 7 | Rupees |
| Distribution and service | Share of revenue plus per passenger | Rupees |
| Marketing | Set by the player; feeds brand | Rupees |
| Overheads and interest | Fixed plus per aircraft; interest on debt | Rupees |

Exchange rate starts at Rs 90 per dollar (G) and moves over time.

## 10. Brand and punctuality

- **Brand score** (0 to 100) drifts toward a target built from on-time performance, cancellations, cabin comfort and marketing spend.
- **On-time performance** falls as the schedule gets tighter: aircraft used above 85% of their daily window and minimum turnarounds both cost punctuality. Padding the schedule buys punctuality at the price of flights.
- **Cancellations** happen when a grounded aircraft has no cover.

## 11. Finance and scoring

- Start: Rs 500 crore equity and a Rs 200 crore credit line (G).
- Daily flash report; quarterly profit and loss, cash flow and route profitability. Headline quarterly results are public, like a listed company. Fares, frequencies and seat counts are public. Costs are private.
- **Insolvency.** Cash below zero with the credit line used up for 14 game days puts the airline in administration: lessors repossess, and the player restarts with reduced capital and a public mark.
- **Season score:** `net worth + 5 x operating profit of the last four quarters`. Side boards for load factor, punctuality and unit margin.

## 12. Events and computer-run airlines

- **MVP events:** fuel shock, currency swing, engine grounding, new airport opening.
- **Later:** rival collapse, pilot shortage, fare caps, demand shocks.
- **Computer-run airlines:** six fictional carriers with fixed networks and rule-based pricing (they follow the lowest fare within a band and defend their bases). They keep markets contested while a world fills up.

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

1. Player-to-player market for aircraft and slots
2. Departure-time bands, booking curve and overbooking
3. Ancillary choices, loyalty programme, corporate deals
4. Sub-fleet penalties, spare aircraft strategy
5. Crew: pilot training lead time and poaching
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

## 15. Screens

Home (cash, yesterday's results, alerts) · Map and network · Route detail (fares, rivals, load factor) · Fleet · Configurator · Aircraft market · Finance · Leaderboard · News · Airline setup · Admin.

## 16. Build stages

| Stage | Output | Done when |
|---|---|---|
| 1 | This spec | Reviewed |
| 2a | Database, rule functions, aircraft, airports, markets | Seat counts, distances and traffic totals match this spec in the live database |
| 2b | Player actions and the daily engine | One game day runs end to end for a test airline |
| 2c | Bot airlines and tuning | Bots play a full season; margins and load factors land in the calibration bands; no single strategy dominates |
| 3 | App screens | Every MVP action works from a phone |
| 4 | Hosting, sign-in, admin | A colleague can join from a link and play |
| 5 | Playtest with 6 to 8 people, then tune | Two game years played without a rules fix |

## 17. Open items and sources

**Open items**

1. A320neo certified maximum of 194 seats is from memory; confirm in Stage 2.
2. The Indian cabin crew rule comes from an older quoted text of the Aircraft Rules; confirm the current wording.
3. Use real aircraft type names or generic ones.
4. The repo is public. Decide whether the game's code should stay public.
5. Trunk routes between two metros come out 20 to 70% above real traffic, and metro to small-city routes below it. Tune in Stage 2c.
6. Passenger numbers for the 44 smaller Indian airports and all international shares are estimates. Replace with published figures where available.
7. With no rivals, one airline on a trunk route still fills its aircraft at twice the reference fare. The computer-run airlines (Stage 2c) must contest the trunk routes from day 1.
8. A new airline cannot fly for 13 game days (one real day) even with a wet lease, and for three real days with an operating lease. Decide whether founding should come with a starter aircraft.
9. The lessor pool is sized on airline places and leased first come, first served: early joiners pay the base rent, late joiners the shortage premium.
10. Market shares add up, so more airlines means more total travel: 33% of potential flies with one daily flight, 88% on a crowded trunk route. Consider grouping the airlines against the option of not flying.
11. The slot price reaches 400x its base at a full airport. Tune the base and `slot_scale` once the computer-run airlines fill the airports.
12. Business travellers who find the business cabin full do not move down to economy, and a grounded aircraft has no spare cover.
13. Buying an A320neo for cash costs Rs 495 crore, about the whole starting equity, so orders end as sale and leaseback in practice.

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
