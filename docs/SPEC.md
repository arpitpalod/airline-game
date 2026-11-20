# Airline Game: Game Spec v0.1

Status: v0.21, 21 Nov 2026 (airport closures, fare caps, airspace closures, late deliveries and seats between countries, 14.23; worlds founded by players with their own rules, part 1: founding earned in play, pace, turns When all are ready, places, money, banks that cut credit lines, demand growth, shocks and computer-run airlines per world, 14.22; sign-up confirms the email with a 6-digit code, password reset by email, 14.21; currency basics: dollar costs in the cost card, dollar hedging, where international routes sell, rupee loans, 14.20; disruptions set per world by the admin, fights at a random but profitable fare, 14.19; year-one fixes: real disruption rates, computer-run airlines that share aircraft and plan by profit, fights that match the market, fares that follow fuel, 14.18; Ops: fuel hedging, maintenance strategies, operating styles and cost per seat-km against the industry, pilot pay automatic, 14.17; every input links to cost or revenue, principle 8; first playtest fixes: international growth, festivals and events, planning in setup, the first week at the start, 14.16; computer-run airlines that sell like rivals, 14.15; insights, 14.14; selling 26 weeks ahead with strategies, cash at booking and rival moves, 14.13; the week as the unit of time and a 13-week pre-launch, 14.12; money by aircraft and route unit economics, 14.11; computer-run airlines that pay their way and slot prices by aircraft size, 14.10; pilots, 14.8; database changes applied on merge, 14.9; everything scarce scales with places, principle 7; no aircraft trading, principle 6).

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
8. **Every input links to cost or revenue** (owner's rule, 20 Nov 2026). Every choice a player makes must show what it changes in rupees, in cost or revenue, before it is made and within weeks after. A setting with no visible trade-off is never used, so it is made automatic or removed. Choices are made for the whole airline as strategies (three or more options), never aircraft by aircraft.

## 2. Decisions locked

| Topic | Decision |
|---|---|
| Players | One person, one airline. About 50 airlines per world. More players means more parallel worlds |
| Duration | Seasons of 26 real weeks, then reset with a hall of fame |
| Clock | A game week every 4 hours after a 13-week pre-launch in one hour, set per world (section 3) |
| Map | 162 real airports: 93 in India, 69 abroad. Demand is modelled from published airport traffic |
| Rivals | Fictional computer-run airlines fill the world; no real airline brands |
| Livery | Cosmetic only. Brand score moves demand, paint does not |
| Platform | Installable web app (opens from a link, sits on the home screen). Supabase back end |
| Aircraft configuration | First-class feature in the MVP (section 5) |
| Currency | Rupees, with dollar-linked costs (leases, maintenance, dollar loans) so currency risk is real; fuel in rupees (14.20) |

## 3. World and clock

**Time moves a week at a time** (owner's rule, 20 Nov 2026). The week is the smallest unit a player sees or acts in: results, figures and changes are all by the week, and nothing moves for a day. Inside a week the engine still works through its seven days in one run, so every rule keeps its daily form and flights still fly on their real days.

**Pre-launch.** A world opens with 13 weeks (G) of pre-launch that pass in one hour (G) of real time. Nothing flies and nothing is charged; players open routes, put aircraft on them, hire pilots and lease or order aircraft. First flights are on day 92, the start of week 14. No quarter is reported before first flights, so the first quarter is weeks 14 to 26. An airline founded after first flights flies from the start of the week four weeks (G) later; the computer-run airlines always fly from the world's first flight day.

**Clock after the pre-launch: a game week every 4 hours** (G per world; the Admin screen sets hours per week, from 15 minutes to 7 days).

| Real time | Game time at 4 hours a week |
|---|---|
| 1 hour | the whole pre-launch (13 weeks) |
| 4 hours | 1 week |
| 1 day | 6 weeks |
| 52 hours | 1 quarter (13 weeks) |
| about 8.7 days | 1 year (52 weeks) |
| about 56 days | one season (338 weeks, 6.5 years) |

`clock_day` runs at `prelaunch_weeks x 7 / prelaunch_minutes` during the pre-launch and at `speed` game days per real day after it (`speed = 168 / hours per week`); `due_day = 7 x floor(clock_day / 7)`, so only whole weeks fall due. A scheduled job runs every 5 minutes and processes every week that has fallen due (at most 4 weeks a run, G), so a missed run only delays results and never loses them.

**Calendar.** Day 1 is Wednesday 1 January 3000 (`worlds.start_date`). Week 1 is days 1 to 7. The game year is 364 days (52 weeks) and a quarter 91 days (13 weeks); the calendar date is shown for orientation and drifts a day a year against the game year. The season's demand pattern starts in January.

**Changes count for the week being played.** An action taken during a week applies from that week's first day. Aircraft arrive, come back from refits and groundings, and return to the lessors' pool at the start of a week (rounded up). A wet lease arrives four weeks (G) after it is ordered.

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

- Selling worlds (all new worlds, 14.13): every flight is on sale 26 weeks ahead and the engine sets its fares each week from the route's strategy (Fill every seat, Balanced, Top fares, Follow the market); players choose the strategy, not fares. Worlds without selling keep one fare per cabin per route, changeable any time, effective next game day.
- The route screen shows the reference fare, rivals' public fares and frequencies, and yesterday's load factor and spill.
- Extras (ancillaries): four extras each sold at a price or included free, set once for the whole network (section 14.6). Replaced the flat 8% of ticket revenue.

## 9. Costs

| Cost | Driver | Currency |
|---|---|---|
| Fuel | Sector fuel x fuel price (starts Rs 100 / kg, moves with a random walk and shocks); part of it bought 13 weeks ahead if the player hedges (14.17). Fares follow a third of a change in fuel cost (14.18) | Dollar-linked |
| Aircraft rent or ownership | Per month per aircraft | Dollars |
| Maintenance | Per flight hour and per flight, rising with age; scaled by the maintenance strategy (14.17) | Dollar-linked |
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

- **MVP events:** fuel shock, currency swing, engine grounding, new airport opening. From 14.19 the admin sets how often each comes, and how big and long, per world.
- **Later:** rival collapse, fare caps, demand shocks. (Stricter pilot duty-time rules: 14.8.)
- **Computer-run airlines:** six fictional carriers with fixed starting networks and rule-based pricing (they follow the lowest fare within a band and defend their bases). They keep markets contested while a world fills up, and from migration 0009 they also start flying routes where players earn well (14.5). As built: section 14.3; from 14.18 they plan each route's flights, share aircraft between routes and review routes on profit every quarter.

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
7. Fuel hedging (built: 14.17)

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
| Season and growth | Monthly multipliers per segment; game day 1 is 1 April. Growth 7% a year (from 14.16: domestic 7%, international 12%, plus festivals and events). Each market swings about 10% from day to day |
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

**Sign-in (section 14).** The `join` edge function (`supabase/functions/join`, deployed with JWT checks off) takes email, password and invite code, checks the code and creates a confirmed account, so joining never depends on email delivery. The app then signs in with the password and founds the airline through `found_airline`, which checks the code again. An invite link is `.../#/join?code=<code>`. There is no password reset by email; an admin resets a forgotten password. (Replaced by 14.21: the join function only checks the invite code, sign-up confirms the email with a 6-digit code, and a forgotten password is reset by email.)

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

### 14.10 Computer-run airlines that pay their way; slot prices by aircraft size (migration 0016)

Owner's request, 19 Nov 2026: fix Myna Regional and Flamingo Air before World 1 (item 19). Measured first: in a world of only computer-run airlines at World 1's size, Myna made +7% and Flamingo −15%; in season runs with players, Myna made −120% to −190% and Flamingo −14% to −64%. Three causes, three fixes. Every number is (G).

| Cause | Fix |
|---|---|
| Flamingo's starting network was sized above its demand: four Gulf routes ran 40 to 59% full even with no players, and a scaled-down world rounds a thin route up to a daily flight on its own aircraft | Kochi to Abu Dhabi and Kochi to Doha leave its starting network; Mumbai to Dubai 2 x 15 round trips a week (was 2 x 14), Mumbai to Abu Dhabi 10 (14), Mumbai to Goa 16 (30), Mumbai to Kochi 18 (21). 11 aircraft at full scale become 9 |
| A computer-run airline had to keep at least one aircraft on every starting route, however empty | From its second year (`bot_drop_min_days` 364), at each quarter end it drops a starting route that over the last 28 days was under 55% full and did not cover its flying costs and aircraft rent (and flew on at least 21 of those days). Never one of the eight busiest domestic markets, never below 2 routes, worst first. The load-factor test means fuel, currency and fare swings never drop a route, only a lack of travellers. Its aircraft leave the world rather than joining the lessor pool (principle 6). News says so |
| Slots were Myna's largest cost (Rs 1.5 to 3.6 a seat-km at Bengaluru and Hyderabad, against Rs 0.2 to 0.4 for jet airlines): a movement cost the same for a 72-seat ATR as for a 186-seat A320neo (item 16) | A movement at a congested airport costs the congestion price x reference seats / 180: ATR 0.4, A320neo 1, A321neo 1.2, A350 1.8. Congestion is still counted in movements |

**Season check** (two full seasons with players and pilots, as in 14.3; single runs vary a lot). Late years (4 to 6): Flamingo −6% to +1% at 75 to 81% full (was −14% to −64%); Myna −15% to −39% on 2 to 5 aircraft (was −120% to −190% on 6); all computer-run airlines +8% to +17% (was +4% to +16%); players within their usual spread. Myna's slot cost per seat-km fell from Rs 3.64 to Rs 0.4 to 1.1. It still loses because turboprops cost about twice as much per seat-km as jets on its 400 to 600 km trunk routes, and a small airline carries the full head office (Rs 6 lakh a day, Rs 1 to 1.9 a seat-km for Myna): item 16. Computer-run airlines are not ranked and never fail, so this costs players nothing.

**Tested.** 7 new local checks (181 in all): Flamingo's new network, the ATR's slot bill at 0.4 of an A320neo's, dropping thin losing routes down to two, aircraft leaving the world, a full losing route kept, the eight busiest never dropped.

### 14.11 Money by aircraft; RASK, CASK and break-even load by route (migration 0017)

Owner's request, 19 Nov 2026: show each aircraft's revenue and the costs known to belong to it, and unit economics on the route screen.

- **Engine.** `day_ops` writes `aircraft_daily` (kept 28 days, private): each aircraft's share of its routes' revenue (by the seats it flew in each cabin), its own flying costs (fuel, flying pay, maintenance, airport, slots) plus its share of the routes' sales and service costs, and what holding it costs (lease rent, wet-lease hours, or depreciation and loan interest for an owned one; cabin crew base pay). Idle and grounded aircraft get a row too. `route_daily.aircraft_cost_inr` is the holding cost of the aircraft that flew the route, shared by the hours each flew there. Pilot salaries, head office and marketing are not split. Aircraft figures add up exactly to the route and airline figures.
- **Aircraft screen.** A Money card: revenue, flying costs, rent (or wet-lease charge, or ownership), result, a day over the last 7 days.
- **Fleet screen.** Result a day for each aircraft.
- **Route screen.** RASK (revenue per seat-km, fares and extras), CASK (flying costs and aircraft cost per seat-km) and break-even load: the load factor at which today's fares would just cover those costs (`load x cost / revenue`), against the route's actual load. Chosen as the third metric because it answers the question a route manager asks first: how full must this route be to pay?
- **Tested.** 5 new local checks (186 in all) and the app test.

### 14.12 Weeks and the pre-launch (migration 0018)

Owner's decisions, 20 Nov 2026: the week is the unit of time; a game week takes 4 hours; a 13-week pre-launch in one hour; first tickets will sell 26 weeks ahead (step 2, section 19). The rules are in section 3.

- **Database.** `worlds` gains `prelaunch_weeks` (13), `prelaunch_minutes` (60) and `start_date` (3000-01-01); `speed` now defaults to 42 (a week in 4 hours). `airlines.first_flight_day` is set on founding by a trigger. `game.clock_day` and `game.clock_seconds` turn real time into game days and back; `game.due_day` and `game.tick` work in whole weeks. `admin_set_week_hours(world, hours)` sets the clock; `admin_set_speed` (minutes a day) now calls it. A trigger rounds `aircraft.available_day` up to the start of a week.
- **Engine.** `run_day` skips the computer-run airlines' pricing and the quarter close before the world's first flights. `day_ops` flies and charges only airlines past their first flight day: no flights, holding costs, overheads or cash movement before it. `day_pilots` names weeks in its news, and a change of pilot duty rules starts at the start of a week. Pilots are hired in the pre-launch but paid from first flights.
- **Game values.** `wet_lead_days` 28 (was 13), `late_join_days` 28 (new), `tick_max_days` 28 (was 30), `season_start_month` 1 (was 4).
- **Worlds.** The old Test World (paused at day 100) is deleted with everything in it. A fresh Test World opens in setup: a week in 1 hour, 25 places, pilots on, invite code made in the database. World 1 (setup) moves to a week in 4 hours with the pre-launch.
- **App.** Every screen shows "Week N · dates" and, before first flights, a pre-launch chip; Home shows a countdown card. Results are by the week: last week's profit, profit by week, passengers, revenue and flight profit a week, a route's load by week, aircraft results last week. Marketing, pilot salaries and wet-lease minimums are shown a week. Arrivals, refits and groundings are shown as weeks. The Admin clock is set in hours per game week.
- **Tested.** 17 new local checks (203 in all; the checks written before 0018 run in worlds without a pre-launch and with the game values they were written for) and the app test, which now plays the pre-launch.

### 14.13 Selling ahead (migration 0019)

Step 2 of section 19. Owner's decisions (20 Nov 2026): tickets sell 26 weeks ahead; truly dynamic fares, no fare levels; players choose only a strategy, rule-based selling does the rest and the admin tunes it; automatic overbooking with hidden no-show patterns; cash at booking, revenue at flight; market shape and rival moves; new routes fly two weeks after opening.

- **Selling runs once a week** (`game.sell_week`), on the first day of the week before the week's flights. Worlds have `selling` (true for new worlds; worlds running before 0019 keep daily fares).
- **Seats on sale.** Each open route is on sale for flight weeks W to W+25 (`route_weeks`, figures each way for the week), with seats from today's rotations; an aircraft counts from the week it arrives, so aircraft on order can be planned and sold ahead. A route flies its first flight two weeks (G `route_lead_days`) after it opens, and not before its airline's first flights.
- **Who books when (G).** Of each week's travellers, the share deciding n weeks before the flight week follows (n + 0.5)^shape x exp(-(n + 0.5)/scale): business shape 0, scale 1.5 (most in the last two weeks); leisure 2, 2.5 (most about 5 weeks ahead); visiting friends and relatives 2, 3.5 (about 7 weeks ahead). When a flight week first goes on sale on its market (the world's first week, or a market nobody served), everyone who would have booked by then books then. Each arriving traveller chooses by the nested logit of section 4 at the fares on sale that week, among airlines with seats left.
- **Strategies (G, table `rm_strategies`, Admin screen).** Fill every seat, Balanced, Top fares, Follow the market. A flight week's economy fare is the reference fare x (early_mult + (late_mult - early_mult) x ramp) x adj, where ramp = ((25 - n)/25)^3 rises late in the sale; business the same from biz_early_mult and biz_late_mult x the business reference. Each week adj moves when seats sold are more than band away from the target curve (target_lf x the share of travellers who would have booked by then): one step for each band's width off, up to three, within min_mult and max_mult. A flight week new on sale starts from the adj of the week now closing, so each route carries what it has learnt. Follow the market charges the rivals' average for the same week (x (1 + follow_gap)), and runs as Balanced with no rival.

| Strategy | Target load | Fare 26 weeks out | Fare in the week | Lowest | Highest | Step | Band | Overbooking |
|---|---|---|---|---|---|---|---|---|
| Fill every seat | 88% | 0.75 | 1.05 | 0.60 | 1.40 | 4% | 6% | 1.0 |
| Balanced | 80% | 0.85 | 1.35 | 0.75 | 1.90 | 3% | 8% | 0.8 |
| Top fares | 72% | 1.00 | 1.80 | 0.90 | 2.50 | 3% | 8% | 0.6 |
| Follow the market | 80% | as Balanced | | | | | | 0.8 |

- **Overbooking and no-shows.** Seats are sold beyond the cabin by the strategy's overbooking x the no-shows the engine expects on the market. No-shows by traveller type (G: business 12%, leisure 5%, visiting friends and relatives 3%) x a hidden factor per market (spread 0.35) x a weekly swing (0.25). When a flight week closes, passengers who turn up beyond the seats cannot board: a full refund plus Rs 10,000 each (G), as a cost; where the seats were cut by the airline's own schedule change after selling, a refund only. No-shows' fares are kept.
- **Money.** Cash comes in when a ticket sells; revenue counts when the flight flies (the week's bookings who could board, a seventh a day, each at the fare paid, no-shows' fares included). Flights cancelled on the day refund their passengers. Closing a route refunds its later tickets at the next week of selling. An airline in administration loses its tickets sold with everything else. `airline_weeks` holds each week's sales, refunds, compensation and advance sales (tickets sold for later weeks). Net worth for the ranking subtracts advance sales.
- **What rivals see.** `market_watch` (public): each airline's economy fare four weeks ahead and next week's flights; `market_moves` (public): entries, exits, fare changes of 7% or more and flight changes of 10% or more, week by week (13 weeks kept). Strategies are private (`route_plans`).
- **Actions.** `set_strategy(airline, route, strategy)`; `admin_set_strategy(key, values)`; `set_fares` is refused in selling worlds (open_route still takes a fare, used only for display until the first week of selling).
- **App.** Route: How it sells (the four strategies, fares on sale now, a line on no-shows), Seats on sale (share sold for each of the next 26 weeks, seats left, advance sales), Competition (monopoly, duopoly, oligopoly or crowded, and recent moves). Opening a route asks how it sells. Money: Profit, Cash flow (by week) and Balance sheet tabs. Home shows advance sales with cash. Admin: the strategies table.
- **Tested.** 22 local checks (`checks_9`); the older checks run with selling off. A bots-only comparison at constant reference fares gives loads at or above the daily model, so demand is unchanged; with the strategies, the computer-run airlines' third-quarter revenue is within 2% of the daily model and their loads within a few points.
- **Tuning, first pass (to revisit after playtesting).** In the three-year season simulation (no pre-launch; simulated players open routes as aircraft arrive, so new routes start with two weeks of sales) players do worse than with daily fares: year-3 operating margins of about -0.3 to +0.09 against up to +0.19 before. Early strategy settings with 85-92% targets and floors at 0.50-0.55 of the reference fare started price wars; the values above are the second set. Runs differ a lot from seed to seed.

### 14.14 Insights (migration 0020)

Step 3 of section 19.

- **Too full, too empty.** The route page's Last flights card shows each of the last six flown weeks as a bar: passengers flown, seats flown empty and travellers who wanted a seat after the last one sold. A week is Too full when those turned away reach 5% of the seats, Too empty when 20% of the seats fly empty, otherwise About right, with one line of advice for the latest week. From `route_weeks`, in the app.
- **What works where (public `sector_insights`).** Each week of selling sums every route's last 13 flown weeks by kind of sector (short under 800 km, medium under 1,800 km, long domestic, international), how many airlines fly the market that week (alone, two, three or four, five or more) and the strategy each flight week sold with (`route_weeks.strategy`): routes, load, fare per passenger and revenue per seat, both over the reference fare. A cell shows only with three routes or more (G `insight_min_routes`), so no single airline's route can be read off it. The Insights screen shows the table by kind of sector and an audit of each of your routes (the best way of selling for routes like it); the route page's How it compares card puts the route beside the cells for its kind, in rupees a seat.
- **The computer-run airlines sell their own ways (G, `bot_airlines.strategy`):** Sarus Airways Top fares, Koel Air Fill every seat, Bulbul Air Follow the market, the rest Balanced, so What works where has more than one strategy to compare. Their third-quarter revenue stays within 1% of the daily model. Superseded by 14.15: each route now draws from its airline's mix and keeps learning.
- **Rival moves in the news.** A rival starting or stopping a market, changing its fare four weeks out by 15% or more (G `news_fare_move`) or its flights by 25% or more (G `news_flights_move`) makes private news for every player flying that market.
- **Practice flight** (Insights screen, in the app, nothing saved). One of your routes, a quiet, normal or busy week: one flight week on sale for 26 weeks under each strategy, against rivals holding their current fares, with the same booking curves, fare rise and pace rule as the engine (economy only, no no-shows). Ranked by revenue, with the selected strategy's seats sold and fare week by week.
- **Tested.** 6 local checks (`checks_10`), the app test.

### 14.15 Computer-run airlines sell like rivals (migration 0021)

Owner's ask (20 Nov 2026): make the computer-run airlines' selling more random, aggressive, competitive and smart.

- **Random start.** Each new route of a computer-run airline draws its way of selling from its airline's mix (G, `bot_strategy_mix`): Sarus Top 50%, Balanced 30%, Follow 20%; Koel Fill 60%, Follow 20%, Balanced 20%; Bulbul Follow 50%, Fill 30%, Balanced 20%; Myna Balanced 60%, Top 40%; Hornbill Balanced 50%, Follow 30%, Top 20%; Flamingo Balanced 40%, Top 30%, Fill 30%.
- **Smart.** Every 4 weeks (G `bot_review_weeks`, staggered by route) each route looks at What works where for routes like it and moves to the way that earned 8% more per seat (G `bot_switch_gain`) than its own way there; otherwise, with a 15% chance (G `bot_explore_prob`), it tries another way at random. So the computer-run airlines keep testing and learning, and What works where keeps changing.
- **Aggressive and competitive.** When a player starts flying one of its markets, each computer-run airline there may fight: that route switches to Fill every seat for 8 weeks (G `bot_fight_weeks`), then goes back. When a player cuts fares there by 10% or more (G `bot_follow_cut`), it may switch to Follow the market. How likely it fights is its aggression (G): Koel 0.9, Bulbul 0.7, Hornbill and Flamingo 0.5, Sarus 0.4, Myna 0.3. Their fare cuts reach the player as rival news.
- **Admin.** `admin_set_bot(code, aggression, mix)` and `admin_set_param(key, value)` (any game value by name); the Admin screen has a Computer-run airlines card for aggression, mixes and these values. Mixes are readable by admins only.
- **Effect.** In bots-only fourth-quarter runs the computer-run airlines' total operating profit ranged from about Rs 440 to 1,260 crore with learning on, against Rs 780 crore with fixed ways: within the run-to-run spread.
- **Tested.** 9 local checks (`checks_11`); the older checks give each computer-run airline one fixed way and switch fights and exploring off.

### 14.16 Fixes from the first playtest (migration 0022)

The owner's first playtest of the Test World (20 Nov 2026). Every number is (G).

| Change | Rule |
|---|---|
| International growth | International markets grow 12% a game year (`growth_year_intl`), domestic 7% (`growth_year`), in selling ahead and route studies. Real FY2026 forecasts: domestic 4 to 6% after 7.6% in FY2025, international 13 to 15% (ICRA). Worlds with daily fares (selling off) keep one rate |
| Festivals and events | Table `demand_events`, readable by players: a start day of the game year, a length, which markets it touches (domestic or international only, airports, regions) and multipliers for business, leisure and budget travellers. Each day of a flight week inside an event adds a seventh of the event's extra demand; travellers book for it on their usual curves, so festival weeks sell early. Eleven to start: Sankranti and Pongal (South), Holi (domestic), Mumbai fintech summit, Eid (Gulf), Onam (Kerala), Durga Puja (Kolkata), Diwali (domestic, business down 20%), Delhi trade fair, Bengaluru tech summit, Christmas and New Year (Goa), year-end holidays abroad (South-East Asia, Europe). Route studies and the practice flight leave them out |
| Planning in setup | `open_route`, `close_route` and `set_rotation` work while a world is in setup; leasing, ordering and wet leases still wait for the start (the lessor pool is filled then) |
| First week at the start | `admin_start_world` sets the clock to the end of week 1 and plays it at once (`start_first_week` 1), as the server, so the computer-run airlines, seats on sale and prices appear straight away. If the week fails it is logged and the scheduler plays it |

**App.** Home has a Get ready checklist in the pre-launch (routes on sale, how they sell, aircraft ready and on routes, grounded or late aircraft, pilots) and a Coming up card (festivals and events in the next 13 weeks, with how many of the player's routes each touches). A route's How it sells card shows what each way of selling would do on that route now (a practice run against today's rivals and demand: seats sold, average fare, takings), a button to use the chosen way on all routes, and says when a change applies: when the next week's selling starts, for every flight still on sale; tickets already sold keep their price. Last flights opens with a typical flight of the latest week as a seat map, with seats filled, empty and turned away and its story. Putting an aircraft on a route shows each aircraft's room for round trips there; a full one (or one out of range) is marked Full (Too far) in red, greyed and cannot be picked. Insights moved into the route page (How it compares links to What works where and to a practice run of that route); the Network header lost its Insights button. An open app checks every five minutes, and when it comes back to the front, whether a newer version is published (`version.json`) and offers to update.

**Tested.** 11 local checks (`checks_12`), including a world started by a signed-in admin; the older checks run with one growth rate, no events and a start that leaves the first week to the scheduler (`run.mjs`). The app test covers the checklist, Coming up, the room per aircraft, Expect on this route and the seat map.

### 14.17 Ops: running costs and three strategies for the fleet (migration 0023)

Owner's rule (principle 8): every input links to a cost or revenue the player sees. The Fleet tab becomes Ops, built as a cost controller would look at it: what flying costs per seat-km against the industry, a few decisions a week, and three strategies for the whole fleet instead of settings per aircraft. Every number is (G).

| Part | Rule |
|---|---|
| Fuel hedging | `airline_ops.hedge_share`: none, 25, 50 or 75% (`hedge_step`, `hedge_max`). At each week start (`game.ops_week`) that share of the fuel for the week 13 weeks ahead (`hedge_lead_weeks`) is bought at this week's price plus 2% (`hedge_premium`), kept in `fuel_hedges`. A week's fuel costs the hedged share at its price plus the rest at the spot price. `airline_daily.hedge_inr` = fuel at spot minus fuel paid (positive: the hedge saved money). A change applies from next week's purchase, so it shows in full after 13 weeks |
| Maintenance strategy | `maint_plans`, one for the fleet (`airline_ops.maint_plan`), on aircraft that are not wet-leased. Pay as you go: rate 1.00, bills +3% a year of age. Flight-hour contract: 1.12, flat with age, groundings 30% fewer, engine events hit half as many aircraft, on-time +1 point, runs 52 weeks. Own hangar: 0.75, +3% a year, Rs 6 cr a week fixed, groundings 20% fewer and 30% shorter, Rs 100 cr to set up (paid at once), opens 13 weeks later; it pays off from about 40 A320-size aircraft. Lean: 0.85, +4% a year, groundings 1.8 times, on-time −2. A switch takes effect at the next week start (the hangar when it opens); choosing the current plan cancels a pending switch |
| Operating style | `op_styles`, one for the fleet. Fuel saver: fuel −4%, flying pay and hourly maintenance +5%, on-time −4. Standard. High utilisation: turns 10 minutes shorter (never under 15, `turn_floor_min`), Rs 2,500 crew allowance per departure, on-time −4, brand −2. Punctual: fuel +4%, turns 8 minutes longer, on-time +6, brand +3. Turn changes apply to schedule checks (`schedule_issue`) and the engine; `set_op_style` returns how many aircraft no longer fit their schedules (they fly late) |
| Fuel shocks | `event_fuel_mult_min` 1.25: a shock is +25 to 45% (was +15 to 45%), so hedging has something to protect against |
| Pilots | Pay and spare pilots are automatic: market pay and 10% spare for every player (`airline_finance.pilot_pay` 1, `pilot_buffer` 0.10); `set_pilot_policy` is refused to players. They had no trade-off a player could see (principle 8) |
| Cost benchmarks | `cost_benchmarks` (public), per world and line: fuel, aircraft (rent and depreciation), maintenance, crew, airports (airport charges and slots), sales (distribution and marketing), office (overheads). The median cost per seat-km over the active airlines that flew in the last 28 days (`benchmark_days`), once 3 airlines fly (`benchmark_min_airlines`); refreshed at each week's end (`game.ops_benchmarks`), so a week flown shows at once |
| Groundings | A random grounding sets `aircraft.grounded_day`; `airline_daily.groundings` counts them, with `fuel_kg` and `hedge_inr` |

**Functions.** New: `set_hedge`, `set_maint_plan`, `set_op_style`, `ops_preview` (for this airline at today's flying, ages and fuel price: each maintenance strategy's cost a week, fixed cost, groundings and days on the ground a quarter; each style's fuel a week, other costs, round trips flown and that fit, aircraft that would not fit, on-time), `game.ops_week`, `game.ops_benchmarks`, `game.ops_rows`. Redefined: `schedule_issue`, `day_fleet` (from 0007), `day_ops` (from 0019), `run_day` (from 0021), `set_pilot_policy`.

**App.** The Ops tab (the fleet list is inside it): Decisions this week (a fuel price 10% or more above normal with room to hedge more, showing 13 weeks of fuel at the current and the next share if prices stay or rise 20%; a cheaper maintenance strategy; groundings 1.5 times what the strategy should give; aircraft whose schedules no longer fit), cost per seat-km by line against the industry median with a link to each line's lever, Your strategies, the Crew card (read-only) and an aircraft summary. The Fuel hedging, Maintenance strategy and Operating style pages show the options and what each would do for this fleet before saving; the maintenance page draws cost a week against fleet size with the hangar's break-even. Home shows Ops decisions as an alert. Wet-leased aircraft carry their crew and maintenance in the rent; the cost card and the maintenance page say so.

**Tested.** 23 local checks (`checks_13`): hedge purchases and price, the hedged fuel bill, maintenance cost by strategy, the 52-week lock, hangar setup and opening, groundings by strategy, each style's fuel, turns and on-time, schedules that no longer fit, the preview and the benchmarks. The app test sets a 50% hedge, a flight-hour contract and High utilisation, and checks the industry median after the first week of flights.

### 14.18 Year-one fixes (migration 0024)

Owner's target (20 Nov 2026): losses in the first years are normal and drive players and computer-run airlines to optimise, but they must come from decisions, not dice. Measured first (season simulation, year 1): the computer-run airlines lost money even in a world with no players (about −6% over three runs), from causes nobody could control. Every fix is a real-world mechanism; every number is (G).

| Target | Year 1 | Year 2 | Year 3 on |
|---|---|---|---|
| Computer-run airlines | −5% to 0% | 0 to +5% | +5% to +10% |
| Typical player | −15% to −30% | −5% to 0% | small profit |
| Best players | about −5% | 0 to +5% | +10% or more |

No sensibly run player should go into administration in years 1 and 2; reckless growth can.

| Fix | Rule |
|---|---|
| A. Groundings at real rates | `ground_prob_day` 0.0015 (was 0.004). Computer-run airlines cancelled 3 to 5% of flights; the DGCA reports 1.0 to 1.3% for all domestic airlines in normal 2025 months. Seasons now run at about 1.2 to 1.4% |
| B. Fuel shocks and engine events about once in three years | `event_fuel_prob_day` 0.001 (was 0.004: about 1.5 shocks a year), `event_engine_prob_day` 0.001 (was 0.002) |
| C. Routes reviewed from the first quarter | `bot_drop_min_days` 91 (was 364) |
| D. Networks sized to the world, aircraft shared | Table `game.bot_plan`: each computer-run route's round trips a week and the type and cabin that fly it. Starting networks: each route's flights scaled to the world (`demand_scale x bot_scale`), at least 3 a week (`bot_min_weekly`); thinner routes are left out. Each base gets whole aircraft per type and cabin for its flights (at least one; where that is fewer than the flights need, every route there flies proportionally fewer), and `game.bot_pack` puts the flights onto as few aircraft as they need, routes sharing aircraft. Before, every scaled-down route got its own part-used aircraft paying full rent: at World 1's size 105 aircraft flew what 83 now fly |
| E. Capacity follows profit | Each quarter end (`game.bot_quarter`), after routes given up and routes contested: a route whose result over 28 days, after flying costs and its share of aircraft costs, is below −5% of revenue (`bot_cut_margin`) loses a quarter of its flights (`bot_cut_share`), down to 3 a week; one above +5% (`bot_grow_margin`) and 80% full (`bot_grow_lf`) gains a quarter (`bot_grow_share`): profits attract capacity. Routes new to the plan wait 8 weeks. Then `game.bot_balance` fits the plan to the aircraft: idle aircraft of the same type and cabin move to bases that need them, up to 3 new aircraft a quarter for routes that grew (`bot_grow_adds`, within twice the starting fleet), what still does not fit is trimmed (worst-earning route first, new routes last), one idle aircraft stays as a spare at a base with 8 or more of its kind (`bot_spare_min`; it covers groundings), and the rest go back to the lessors, at most 10% of the fleet a quarter (`bot_return_share`). Aircraft handed back leave the world (principle 6). A cheap-selling route can be full and still lose money, which a load-factor rule missed |
| F. Fights match the market, never below cost | When a player enters, a fighting computer-run airline switches that route to Follow the market (`bot_fight_follow`; was Fill every seat). And computer-run airlines never sell economy below the fare that covers the route's flying and aircraft costs at 80% full over the last 28 days (`bot_sell_floor_lf`, extras counted at `bot_floor_anc`), within the strategy's highest fare. Under daily fares they had such a floor (14.3); selling ahead (0019) lost it |
| G. Fares follow fuel, partly | `worlds.fuel_avg` moves a quarter of the way to the current fuel price each week (`fuel_fare_smooth`, a lag of about four weeks); `worlds.fare_index = 1 + 0.33 x 0.38 x (fuel_avg / 100 − 1)` (`fuel_pass`, `fuel_fare_share`): fares follow a third of the change in fuel cost per passenger, which is what IndiGo's 2026 fuel charges passed on. Selling prices every fare from the reference fare times the index; travellers still judge fares against the reference, so a fuel charge costs some travellers. Fuel 30% dearer for weeks: fares about 3.8% higher. Hedging protects the rest |

**Results** (season simulation; single runs vary, so read the direction).

| | World 1's realistic case: 4 simulated players (2 low-cost trunk, 2 niche), 25 places, two runs | A full world: 18 simulated players, 18 places, two runs (before the growth values were raised; computer-run airlines there rarely reach 80% full) |
|---|---|---|
| Computer-run airlines | year 1 about +4%; year 2 +1.5% and +8.5% | year 1 −3% to −5%; year 2 about −2% |
| Players | year 1 −10% to −15% (low-cost trunk near break-even by the fourth quarter, niche −10% to −20%); year 2 −2% and +7% | year 1 −25% to −30%; year 2 typical −17%, best +1% to +2%; year 3 best +8% to +9% |

In a full world the smaller computer-run airlines recede as players take their markets: Koel Air from about 30 aircraft to 10, Bulbul Air, Hornbill Airways and Flamingo Air to 1 to 5, while Sarus Airways grows to 46 to 49 and earns 7 to 11%. That matches section 12 (they keep markets contested while a world fills up); open item 24.

**App.** The practice flight and How it sells price from the same index; the fuel page shows the fuel charge on fares; Home's profit tile says whether last week was up or down on the four weeks before, so a loss that is shrinking reads as progress.

**Tested.** 10 local checks (`checks_14`); the older checks run with the old disruption rates and the old computer-run airlines (`bot_plan` 0, no cost floor, fights that fill every seat, fares that ignore fuel: `run.mjs`). The old functions stay as `bot_seed_v1`, `bot_quarter_v1`, `bot_enter_v1` and `bot_exit_v1` for them. Running worlds: each open computer-run route keeps its flights as its plan; the new rules apply from the next quarter end.

### 14.19 Disruptions per world, fights at a random but profitable fare (migration 0025)

Owner's decisions (20 Nov 2026).

**Disruptions per world.** Table `world_params` (admins only: players are not told) holds a world's own values; `game.wparam(world, key)` gives the world's value or the game's default, and the engine reads disruptions through it (`day_world`, `day_fleet`, `ops_preview`). `admin_set_disruptions(world, values)` sets them: a number sets one, null goes back to the default.

| Event | Real (the default) | The admin can set |
|---|---|---|
| Aircraft groundings | each aircraft about once in two years (0.15% a day), 2 to 6 days | never to once a month per aircraft; 1 to 60 days |
| Fuel shocks | about once in three years, +25 to 45% for 6 to 17 weeks | never to once a month; +0 to 100%; 1 to 52 weeks |
| Currency swings | about once in three years (`event_fx_prob_day` 0.001; was 0.003, about once a year), rupee 4 to 10% weaker for 9 to 26 weeks | never to once a month; 0 to 50%; 1 to 52 weeks |
| Engine events | about once in three years, 15 to 30% of one type for 3 to 8 weeks | never to once a month; 5 to 60%; 1 to 52 weeks |

One shock of each kind runs at a time (engine events could overlap before), so at high settings shocks come back to back but never stack. A change applies from the next game day; events already running finish as they started. Pilot duty-time cuts stay a game-wide value. The Admin screen has a Disruptions card: presets Calm (half as often), Real and Rough (twice as often), and how often, how big and how long for each event, in plain units.

**Fights.** When a computer-run airline fights a player (14.15: the chance is its aggression), it draws for the fight where it prices: `route_plans.fight_pos = random() ^ (aggression x bot_fight_skew)` (3), so aggressive airlines draw nearer 0. For each flight week, `sell_week` prices its economy fare at `lowest + fight_pos x (player's fare − lowest)`, where lowest is its profitable lowest fare: the cost floor of 14.18 (flying and aircraft costs at 80% full) plus `bot_fight_margin` (5%), or the strategy's lowest fare before it has 7 days of results. Where the player sells below that lowest, it holds there and lets the player lose money alone. The draw holds for the fight (8 weeks) and is cleared when it ends; the next fight draws again. `bot_fight_random` 0 goes back to 0024 (matching the market).

**Tested.** 10 local checks (`checks_15`); the older checks run with the old currency rate and 0024 fights (`run.mjs`). The app test sets a world to Rough and back to Real.

### 14.20 Currency, the basics (migration 0026)

Owner's decisions (20 Nov 2026): only the basics, one lever each, built into screens that exist. No fuel price per airport (fuel stays in rupees). Lease length (6 or 12 years) is for later (open item 25).

**Dollar costs and the currency effect.** Aircraft rent and wet leases, maintenance, dollar-loan interest and repayments, and the depreciation of owned aircraft are in dollars; everything else is in rupees. `day_ops` writes for each airline and day `airline_daily.usd_cost_usd` and `usd_cost_inr` (those costs, repayments left out), `fx_effect_inr` (what they cost against the reference rate `fx_ref_inr_usd`, Rs 90 (G)) and `usd_hedge_inr`. The Ops cost card has a Currency strip, about a quarter of the card: the rupee, the share of costs in dollars and what the rupee's move added or saved over 4 weeks, linked to dollar hedging. The Aircraft and Maintenance lines carry a $ mark.

**Dollar hedging**, like fuel hedging (14.17). `set_usd_hedge(airline, share)`: none, 25, 50 or 75% (`usd_hedge_step`, `usd_hedge_max`). At each week start `ops_week` buys that share of the dollars for the week 13 weeks ahead (`hedge_lead_weeks`) at that week's rate plus 1% (`usd_hedge_premium`), in `usd_hedges` (read own). In that week rent, maintenance, dollar-loan interest and repayments are paid at share x locked rate + (1 − share) x the week's rate; depreciation stays at the day's rate (it is not cash). `usd_hedge_inr` is those cash items at the day's rate less what was paid. Page `/ops/dollars`: the rupee against Rs 90, dollar costs a week, what is already bought, last week's and the quarter's result, and 13 weeks of dollar costs if the rupee then gains 5%, stays, loses 5% or loses 10%. Ops shows a decision when the rupee is 5% or more weaker than Rs 90 and the hedge is below the most.

**Where you sell**, on each international route: the commercial lever (sales sit with the chief commercial officer, so it moves revenue, and costs a sales team abroad). `route_plans.sell_where`, set with `set_sell_where(airline, route, key)` (refused on domestic routes), from table `pos_options` (G):

| | Tickets priced in dollars | Sales team abroad (share of the route's ticket revenue) | Reach (added to every traveller's view of the route) |
|---|---|---|---|
| Mostly in India (the default; before 0026 no ticket followed the rupee) | 20% | 0 | 0 |
| In India and abroad | 45% | 2.5% | 0.03 |
| Mostly abroad | 70% | 5.5% | 0.06 |

`sell_week` adds the reach to the four traveller types' utilities and books ticket revenue and cash at 1 + dollar share x (rate / 90 − 1), so tickets priced in dollars bring more rupees while the rupee is weak and fewer while it is strong; refunds follow what was booked. `day_ops` charges the sales team on the route's ticket revenue, in the route's costs and in Sales and service (selling worlds). On a test route a reach of 0.06 brought about 8% more travellers at the same fares and 0.03 about 4%: selling abroad pays on a route with empty seats and loses on a full one, give or take the currency. Computer-run airlines sell mostly in India. On the route page, How it sells shows for international routes one choice (India, Both, Abroad) and a practice-run table for the route's way of selling: seats sold, the sales team's cost and takings after it, and what a 10% weaker rupee brings.

**Rupee loans.** An order can be paid with `loan_inr`: on delivery the balance is borrowed in rupees at `loan_rate_inr_year` 10.5% (the dollar loan is 8%), repaid daily over 12 years (`aircraft_terms.loan_ccy`, `loan_inr`, `loan_pay_inr_day`). Interest and repayments are in rupees, with no currency risk and no hedge. Net worth (`day_quarter`) and selling the aircraft (`return_aircraft`) count it. The order screen's pay choice is $ loan, ₹ loan, Cash or Leaseback, with the first year's interest on each loan and what a 10% weaker rupee adds to a dollar loan.

Redefined: `ops_week` (from 0024), `day_ops` (0023), `sell_week` (0025), `day_fleet` (0025), `order_aircraft` (0007), `day_quarter` (0019), `return_aircraft` (0007), `ops_preview` (0025; adds `usd`). New: `set_usd_hedge`, `set_sell_where`.

**Tested.** 15 local checks (`checks_16`): hedging steps and limits; the purchase 13 weeks ahead at the week's rate plus 1%; dollar costs and the effect against Rs 90 with the rupee at 100; rent at the blended rate when half is hedged; where you sell refused on domestic routes; more travellers when selling abroad; revenue at x 1.0222 / 1.05 / 1.0778 with the rupee at 100; the sales team at 5.5% of ticket revenue; a rupee loan on delivery, its daily interest and repayment, and its repayment on sale. The older checks pass unchanged. The app test hedges 25% of dollars, sees the Currency strip, sells an international route mostly abroad and orders two aircraft on a rupee loan.

### 14.21 Email codes: confirming sign-up and resetting a password

Owner's decisions (21 Nov 2026): password reset by email; sign-up checks the email address. Mockups: the design canvas "Airline game – World settings and accounts", boards 5 and 6.

- **Sender.** A Gmail account made for the game (`airlinesleaderapp@gmail.com`), through Gmail's SMTP server with an app password. Supabase's own sender only reaches the project's team and 2 emails an hour, so it could not do this. [Likely] Gmail sends about 500 emails a day; a sender on the game's own domain comes before a store launch.
- **Settings as files.** `supabase/auth/config.json` (sender, `mailer_autoconfirm` off, 6-digit codes valid for an hour, 60 emails an hour, passwords of 8 or more, site URL) and the two email texts `confirm.html` and `recovery.html`, which carry the code (`{{ .Token }}`), not a link. `.github/workflows/auth.yml` runs `tools/auth/apply.sh` when they reach `main`: it first sends a test email from the sender to itself (a wrong password stops there, with Supabase unchanged), then applies the settings through the Supabase Management API and prints them. Repository secrets: `SUPABASE_ACCESS_TOKEN` and `SMTP_PASSWORD`, never printed or committed.
- **Joining.** The `join` function now only checks the invite code. The app then signs up with Supabase Auth, which emails a 6-digit code; the player types it in the app (Check your email), which confirms the address and signs in. A code is typed rather than a link followed, because a link opens the phone's browser, not the installed app. Codes can be sent again after 60 seconds. An existing player joining another world signs in with the password instead, as before. A player who signed up but never confirmed is sent a fresh code when signing in.
- **Forgot password.** Sign in › Forgot password: email, then a 6-digit code and a new password on one screen. The screen stays until the new password is saved, although the code signs the player in first. The reply never says whether an account exists.
- **Tested.** The app test (shim: sign-up, resend, recover and verify with codes it keeps for the test) confirms an email with a wrong code and then the right one, resets a password and signs in with the new one.
- Accounts made before 14.21 (the owner's) are confirmed already and keep working.

### 14.22 Worlds founded by players, with their own rules (migration 0027, part 1)

Owner's decisions (21 Nov 2026): players found their own worlds; the friction is proven play and a minimum of players, not an exam. A world's rules are fixed for its season, except pace and places (places only upwards once started). Home region is a must; only India is built. Mockups: the design canvas "Airline game – World settings and accounts", boards 1 to 4 and 7 and 8. Built in three parts: 1 (this) founding, rules, screens; 2 four new shocks (late aircraft and engine deliveries, airport closures, airspace closures, fare caps in a crisis); 3 seat limits between countries (foreign airlines on the same routes, scaled with places). Until parts 2 and 3 land, the founding screen shows them as coming.

**Founding.** `create_world(name, rules)` returns the world's id and invite code. A player may found a world once one of their airlines has 4 quarterly reports (`founder_quarters`, G) with an operating profit in the last 2 (`founder_profit_quarters`, G), and only one live world at a time; admins at any time. `founder_status()` says how close a player is. The world waits in setup: the scheduler starts it once `world_min_players` (6, G) players have joined, playing the first week at once as `admin_start_world` does, or closes it (`status` ended, `closed_at`) after `world_join_days` (7, G). Admins may set another minimum. A founded world waiting for players is open: anyone signed in may take its code (`world_join_code`) from the Worlds screen; worlds without a founder (Test World, World 1), and founded worlds once started, take players by invite link.

**The founder is the world's admin** (`game.require_world_admin`): invite code, pause and resume, pace (`admin_set_week_hours`), turns (`set_turn_mode`) and places (`admin_set_places`). Starting early, disruptions and the game-wide cards stay with the game's admins. The founder plays by the same rules as everyone.

**The rules** (table `world_options`, G; `worlds.rules` keeps the choices). Each choice writes its game values into `world_params` (public rows: players see them), which the engine reads per world (`game.wparam`, and `game.params_for` for the day and selling engines):

| Setting | Options (default in bold) | What it sets |
|---|---|---|
| Home region | **India**; Middle East, USA, Canada, Europe, Africa, South America, China coming | (only India's airports exist) |
| Pace | 15 min, 1 hour, **4 hours**, 1 day a game week | `speed`; changeable later |
| Turns | **On the clock**; When all are ready | `turn_mode`; changeable later |
| Places | 12, **25**, 50 | `max_airlines`, `demand_scale` = places / 50; only up once started |
| Starting money | ₹250 cr, **₹500 cr**, ₹1,000 cr | `start_cash_inr` |
| Banks | Easy (₹300 cr line, 8%, rupee loans 8.5%, 10% deposit, no debt limit); **Normal** (₹200 cr, 11%, 10.5%, 15%, limit 6); Tight (₹100 cr, 15%, 13%, 25%, limit 4) | `credit_limit_inr`, `interest_year`, `loan_rate_inr_year`, `order_deposit_share`, `credit_debt_limit` |
| Demand growth | Slump 2% / 6% intl; **Normal** 7% / 12%; Boom 12% / 18% | `growth_year`, `growth_year_intl` |
| Shocks | Calm (half as often); **Real**; Rough (twice) | the four disruption chances of 14.19 (hidden, as on the Admin screen; at most 12 a year) |
| Computer-run airlines | None; Calm (aggression x 0.5); **Normal**; Fierce (x 1.6) | `bot_scale` 0, or `bot_aggression_mult` (fights and fare following, capped at 1) |

**Banks.** `game.bank_week` at each week start (`ops_week`): from an airline's fifth quarter, debt above the world's `credit_debt_limit` times the last 4 quarters' operating profit, or any debt while those quarters lost money, cuts the credit line to `credit_cut_share` (half, G) once, with private news; the full line returns once debt is back within the limit (`airline_finance.credit_cut_from`). A limit of 0 means none. The Money screen says when the line was cut, and the rule while it was not.

**When all are ready.** In such a world the Home screen shows "Week N · X of Y ready" and a Ready button (`set_ready`, `airlines.ready_day`). The scheduler plays the week as soon as every active player is ready, after the pre-launch, and at the latest when the clock runs out; after an early week the clock counts the next one from that moment. The scheduler now runs every minute (was 5).

**Worlds made before 0027** keep their values: their rules are recorded as India, on the clock, ₹500 cr, Normal banks, growth and shocks, and they get Normal's public values, which match the game's, plus Normal's debt limit of 6 (it bites from an airline's fifth quarter).

**App.** Worlds (`/worlds`, from the sidebar and the Home menu): your worlds (tap to switch), worlds waiting for players with their rules and a Join button, Found a world, and an invite code box. Found a world (`/worlds/new`): what it takes (quarters, the last 2 quarters' operating profit, one world at a time), then two steps, the world and the market, drawn from `world_options`, then the invite link and Found my airline. Joining from the list or after founding shows the world's money on the airline screen. The Admin screen opens to a world's founder as Your world. A world's public values lie over the game's everywhere in the app (interest, deposits, credit line, starting money).

**Tested.** 27 local checks (`checks_17`): the options as data; a new world's pace, places, turns and values; the engine reading them per world; unbuilt regions refused; starting money and credit line from the world; waiting, starting at the minimum with the first week played, closing after the deadline; nobody ready, one of two, all ready (the week played at once and the clock re-anchored); the licence refused, not yet with a losing last quarter, then allowed; one live world per founder; the founder's pace, turns and invite on their world and not another; places only up; the open code for founded worlds only; calm rivals; the bank cut, once, restored, and not before 4 quarters. The older disruption check now counts only hidden values. The app test earns the licence, founds a world (15 minutes, When all are ready, ₹250 cr, Tight banks, no computer-run airlines), founds an airline in it, sees it start, taps Ready and sees the week played, and switches the founder's world back to the clock.

### 14.23 Shocks and seats between countries (migration 0028, worlds parts 2 and 3)

Owner's decisions (21 Nov 2026, with 14.22): four new shocks and seat limits between countries, each set by the founder's Shocks and Seats choices. Every number is (G) unless marked.

| Shock | Real (the default) | What it does |
|---|---|---|
| Airport closures | about twice a year (`event_airport_prob_day`), 1 to 4 days | An Indian airport closes; bigger airports are picked more often (in proportion to passengers). Every flight to and from it is cancelled and its travellers refunded; aircraft costs run on |
| Fare caps in a crisis | after a closure of an airport of 15 million passengers a year or more (`fare_cap_min_pax`) | Economy fares on domestic routes to and from it are capped at 1.5 times the reference fare (`fare_cap_mult`) for 4 weeks (`fare_cap_weeks`), for every flight week on sale; every way of selling sells at most at the cap |
| Airspace closures | about once in 4 years (`event_airspace_prob_day`), 4 to 26 weeks | The airspace west of India closes. Routes between Indian airports at or north of 23°N (`airspace_lat_min`) and the Gulf, Europe, Africa, Central Asia and North America fly round it (table `airspace_detours`: 350, 900, 300, 800 and 1,500 km more): more block hours, fuel, crew, maintenance and navigation charges, and lower punctuality where schedules are tight. An aircraft that can no longer reach the far end is cancelled |
| Late deliveries | a quarter of new aircraft (`late_delivery_prob`), up to 13 weeks (`late_delivery_max_weeks`) | 13 weeks before a new aircraft from the manufacturer is due (`late_notice_days`), the maker says whether it will be late; each aircraft is told once (`aircraft_terms.delay_weeks`). Seats planned on it before it arrives are not sold, and those already sold are refunded |

Calm: an airport closure about every 2 years, no airspace closures, late deliveries or fare caps (and the older shocks half as often). Rough: an airport closure every quarter, the airspace every 2 years, half of new aircraft up to a year late (and the older shocks twice as often). These values are in `world_options` and written to `world_params` (hidden) when a world is founded; the Admin screen's Disruptions card sets each one per world, with Calm, Real and Rough taken from the same rows.

**Seats between countries.** Table `seat_limits`: the weekly seats each way India's airlines may fly to a country with a seat agreement, at full scale. From public figures (V): the UAE 135,000 (Dubai 66,000, Abu Dhabi 50,000, Sharjah and Ras Al Khaimah), Oman 27,400, Singapore 26,300, Qatar 24,800, Kuwait 18,000 (12,000 from 2006, raised by half in 2025); estimates (G): Saudi Arabia 50,000, Thailand 30,000, Malaysia 20,000, Bahrain 10,000, Hong Kong 10,000, Turkey 8,000, Indonesia 6,000. Other countries have no limit: India has open skies with SAARC countries and countries beyond 5,000 km, and the rest carry too few travellers in the game to fill one. A world's airlines share `seats_week x demand_scale x seat_limit_mult`, so the limit grows with places (principle 7). The founder chooses No limits (0), Real limits (1, the default) or Tight (0.7). `set_rotation` refuses a player more round trips to such a country once its seats are taken, saying how many are free; seats go to whoever flies them first, and seats an airline stops flying are free at once. The computer-run airlines (incumbents) are counted but never refused. Foreign airlines fly the other side's seats and carry the travellers this world's airlines cannot seat; demand is not otherwise changed, so the tuning holds. Against the game's demand at reference fares, Real limits bind only when a world's airlines together would carry most of the travellers to that country (the UAE at about 92%, Singapore at about 80%, Thailand at about 70%).

**A fix.** A route with every flight cancelled on a day (an airport closure, or a grounding without cover) now refunds that day's travellers; before, only routes with some flights left did.

**App.** The founding screen's step 2 adds Seats between countries; Shocks describe all eight shocks; the "coming" rows are gone. An international route to a country with a limit has a Seats card (this world's seats, yours, other airlines', free). A route touched by a closed airport, a fare cap or the airspace closure says so. Home warns of a closed airport, a fare cap or the airspace closure on your network, and of a late aircraft. Ranks lists the new events. The Admin screen's Disruptions card adds airport and airspace closures, late deliveries and fare caps.

**Tested.** 19 local checks (`checks_18`): the UAE's seats at a world's scale; no limit for open skies; refused round trips beyond the free seats, for any player; the computer-run airlines counted, not refused; No limits; a closed airport cancelling every flight and refunding a route with every flight cancelled; a fare cap holding domestic economy at the cap and leaving routes abroad alone; more fuel the long way round and cancellation beyond range; a late delivery, told once; the four shocks starting by themselves with news; a founder's Seats and Shocks choices; the admin's new values and their limits. The older checks run without the new shocks and seat limits (`run.mjs`); all pass with the refund fix. The app test sees the Seats card on a Gulf route, chooses Tight seats and Rough shocks when founding a world, and sees a Delhi closure on Home.

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
3. Settled 21 Nov 2026 (owner): real aircraft type names (ATR 72-600, A320neo, A321neo, A321XLR, A350-900), as built.
4. Owner, 21 Nov 2026: the repo can go private if needed (before a store launch). Note: GitHub Pages from a private repo needs a paid GitHub plan, and Actions minutes are limited there.
5. Trunk routes between two metros come out 20 to 70% above real traffic, and metro to small-city routes below it. Tune in Stage 2c.
6. Passenger numbers for the 44 smaller Indian airports and all international shares are estimates. Replace with published figures where available.
7. Settled in Stage 2c (14.3): six computer-run airlines contest the trunk routes from day 1.
8. Settled in Stage 2c (14.3): founding comes with one wet-leased A320neo that flies on day 1, at the normal wet-lease rate.
9. Settled in Stage 2c (14.3): at most 6 pool aircraft per airline in any 91 days. Early joiners still get the lower rent until their leases renew (728 days, about 8 real weeks).
10. Settled in Stage 2c (14.3): nested logit; splitting the same flights among more airlines barely adds travel.
11. Settled in Stage 2c (14.3): 100x the base at a full airport; caps scale with `demand_scale`. Re-check once a full world (50 players) is running.
12. Settled in Stage 2c (14.3): business travellers move down to economy; an idle aircraft at the same base covers a grounded one.
13. Settled in Stage 2c (14.3): aircraft loans; the season score counts profit after interest.
14. Settled 21 Nov 2026 (owner): the season score uses profit after interest (section 11).
15. Long haul has the highest upside in small worlds: beyond London and Singapore no computer-run airline flies long haul. Consider more Sarus long-haul routes or a second long-haul carrier after the playtest.
16. Small airlines (1 to 3 aircraft) carry the full Rs 6 lakh a day of head office, and turboprops pay the same slot price per movement as an A350: the simulated turboprop and secondary-route players never grew past a few aircraft, and Myna Regional ends the season far below break-even once Bengaluru and Hyderabad fill up (computer-run airlines keep one aircraft on every route of their network, so it cannot leave). Watch this in the playtest before changing it; a slot price per seat rather than per movement is one option. Update 19 Nov 2026: slot prices now scale with aircraft size (14.10). The head office part stands: a small airline still carries the full Rs 6 lakh a day (Rs 1 to 1.9 a seat-km for Myna Regional and the simulated regional players).
17. The simulated players in `season.mjs` are simple rules, not people. Results for year 1 (everyone losing money) depend on how fast players add capacity; re-check with the playtest (Stage 5).
18. Set a world's `demand_scale` to about (expected players / 50) before starting it: demand, computer-run fleets and slot caps all scale with it. World 1 is set to 0.5 for at least 25 players.

19. Settled 19 Nov 2026 (14.10): Flamingo's network re-sized, computer-run airlines drop thin losing routes from their second year, slot prices scale with aircraft size. Myna still loses about 15 to 35% late in a season (turboprop costs and its head office; item 16).
20. An AI strategist for the computer-run airlines (a model choosing once a quarter which routes to enter and how hard to price, through the same functions) was suggested by the owner. Deferred until the playtest shows whether the rules in 14.5 feel predictable. It would need an Anthropic API key held as a server secret and makes season runs non-repeatable.

21. Settled 21 Nov 2026 (owner): World 1 runs a game week in 4 hours after its one-hour pre-launch (section 3).

22. Settled 21 Nov 2026 (owner): no second, premium currency; open to a good idea later. Rupees stay the only currency; the second scarce resource is pilots (18.4).

23. Pilots and the season (two pairs of full-season runs, with and without pilots, 18 players and 18 places; single runs vary a lot). Players' revenue-weighted operating margin, years 3 to 6: with pilots −3.4/−4.1, −2.5/−3.4, +6.7/−2.2, +0.9/−1.0%; without −3.3/+3.3, −5.0/+7.4, +2.2/+9.2, +4.5/+8.6%. Computer-run airlines in year 6: +7.2/+10.6% with, +13.8/+15.5% without. So pilots cost about 4 to 6 points of margin late in the season, for players and computer-run airlines alike: crew cost per seat-km about 10% higher (buffers, crews hired ahead of aircraft, more pilots at high utilisation), cancellations of 1 to 3% in thin years against under 0.5%, and the A350 market running dry once long-haul players grow (market pay 1.4 to 1.6 for that family). Three strategies still lead (low-cost trunk, full service, long haul or a second low-cost trunk). The owner chose to trim pilot pay 10% (migration 0015). The runs also took about twice as long a game day (pilot step), well inside the 2-second target on the live database.

24. Computer-run airlines in a full world (14.18): with 18 simulated players they shrink to a few aircraft each, except Sarus Airways, and keep losing money at that size (head office: item 16). Owner, 21 Nov 2026: they should hold more ground in a full world. To design and tune with the season simulation. Re-checked after 0028 (two-year runs, 18 players, one with the 0028 shocks, seat limits and bank limit and one without): the same picture both ways, so 0028 did not cause it. Together the computer-run airlines are about −2% in year 1 and −3% in year 2 (Sarus +8 to +14%), but the smaller ones lose 15 to 45% in year 1 and 18 to 98% in year 2; typical players about −15% in year 2, the best around 0.

25. Lease length (14.20). Owner, 21 Nov 2026: anything from 6 to 12 years, which can be random. To design: the lease term today is 2 years (728 days) and renews at the market rent.

26. Home regions other than India (14.22): each needs its airports, markets, traffic and computer-run airlines as data, and its own currency and fuel price. One region at a time, after the playtest.

27. Settled 21 Nov 2026 (14.23): worlds parts 2 and 3, the four new shocks and seats between countries. Engine deliveries (spare engines late, so engine events last longer) were left out: late aircraft carry the lesson.

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
| 19 Nov | Myna Regional and Flamingo Air fixed; slot prices by aircraft size (14.10) |
| Test World playtest, next few days | Fix what the owner finds; watch pilots |
| Before World 1 starts | Confirm the clock (item 21) |
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

Built: section 14.8. Pay and spare pilots became automatic in 14.17.

## 19. Revenue management: selling and money (agreed 20 Nov 2026; built as 14.12 to 14.15)

The game's main lesson (owner): sell too many cheap seats and business travellers find the plane full; hold back too many and seats fly empty. Players choose a strategy; rule-based pricing does the rest. Mockups: the design canvas "Airline game: selling and money". Built in three steps: weeks (14.12, done), then selling and money, then insights.

**Step 2: selling and money** (built: section 14.13)
- **Tickets sell 26 weeks (G) before departure.** Every flight is on sale for 26 weeks; a new route goes on sale at once and flies its first flight two weeks (G) later.
- **Truly dynamic pricing, no fare levels.** There are no booking classes for players to set. Each route runs one of four strategies: Fill every seat, Balanced, Top fares, Follow the market. A rule-based engine prices every flight from the strategy, how it is selling against its ideal booking curve, weeks to departure, season and rivals. The engine's values are game values (G) the admin tunes. Fares stop being a player input (`set_fares` goes).
- **Travellers.** Business, leisure, visiting friends and relatives, each booking at its own time before departure and with its own price sensitivity.
- **Competition.** Each route shows its market: monopoly (1 airline), duopoly (2), oligopoly (3 or 4) or crowded (5 or more), and a log of rivals' moves (fares, schedules, entries and exits), week by week.
- **Seats.** Each route shows the share sold and seats left for each of its next 26 weeks.
- **Overbooking** is automatic, with no-show patterns by route and season that are hidden: players learn them from a small note on the route's sector information.
- **Money.** Cash comes in when a ticket is sold; revenue counts when the flight flies. Tickets sold for future flights are shown as "Advance sales". The Money screen has three tabs: Profit, Cash flow and Balance sheet. Wording stays neutral: no warnings about money "owed".
- World 1 restarts after step 2.

**Step 3: insights** (built: section 14.14; the mockups' Get ready checklist, Coming up events, Expect on this route and seat-map story were added after the first playtest: 14.16)
- **Too full, too empty.** Per flight: travellers turned away and seats flown empty, in plain words.
- **What works where.** Which strategies do best on which kinds of sector, updated each quarter from every airline's results, linked to a route audit.
- **Rival moves** in the news.
- **Practice flight.** A small simulation in the app (no database writes): pick a week and a strategy and see how one flight sells.
