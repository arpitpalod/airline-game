# End-to-end check of the app against the local stack: joins from an invite link, founds an airline, starts the
# world as admin, opens a route, flies days, and uses every player action from the screens. Saves screenshots at
# phone (390x844) and laptop (1440x900) sizes and fails on any page error or failed action.
# Usage: python3 e2e.py <app url, e.g. http://localhost:4173/airline-game/> <screenshot dir>
import json, os, subprocess, sys, time
from playwright.sync_api import sync_playwright, expect

BASE, OUT = sys.argv[1], sys.argv[2]
subprocess.run(['mkdir', '-p', OUT])
def sql(q):
    return subprocess.run(['psql', '-h', '/tmp', '-p', os.environ.get('PGPORT', '54322'), '-U', 'postgres', '-Atc', q], capture_output=True, text=True, check=True).stdout.strip()

CODE = sql("select s.invite_code from world_secrets s join worlds w on w.id = s.world_id where w.name = 'World 1'")
WORLD = sql("select id from worlds where name = 'World 1'")
EMAIL, PW = 'arpit@test.in', 'flying-high-1'
errors = []

def watch(page):
    page.on('pageerror', lambda e: errors.append(f'pageerror: {e}'))
    page.on('console', lambda m: m.type == 'error' and errors.append(f'console: {m.text}'))

def toast_ok(page, expect_text, timeout=10000):
    """Waits for the action's own toast; fails at once if an error toast appears instead."""
    hit = page.locator('.toast.error:not([data-seen]), .toast:not(.error):not([data-seen]):has-text("%s")' % expect_text).first
    hit.wait_for(timeout=timeout)
    txt = hit.inner_text()
    if 'error' in (hit.get_attribute('class') or ''):
        page.screenshot(path=f'{OUT}/FAILED.png', full_page=True)
        raise AssertionError(f'action failed: {txt}')
    print('  toast:', txt)
    page.evaluate("document.querySelectorAll('.toast').forEach(t => t.setAttribute('data-seen', '1'))")
    return txt

def shot(page, name):
    page.wait_for_timeout(500)
    page.screenshot(path=f'{OUT}/{name}.png', full_page=True)
    print('  shot', name)

def go(page, hash_):
    page.goto(BASE + '#' + hash_)
    page.wait_for_load_state('networkidle')

import atexit
atexit.register(lambda: errors and print('\npage errors so far:\n  ' + '\n  '.join(errors)))

with sync_playwright() as p:
    b = p.chromium.launch()
    # ---------- Phone ----------
    ctx = b.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
    page = ctx.new_page(); watch(page)
    print('join from invite link')
    go(page, f'/join?code={CODE}')
    expect(page.get_by_role('tab', name='I have an invite')).to_have_attribute('aria-selected', 'true')
    shot(page, 'p01-join')
    page.get_by_label('Email').fill(EMAIL)
    page.get_by_label('Password').fill(PW)
    page.get_by_role('button', name='Create account').click()
    page.get_by_text('Found your airline').wait_for()
    page.get_by_label('Airline name').fill('Tarang Air')
    page.get_by_placeholder('Search city or code').fill('Delhi')
    page.locator('.item', has_text='DEL').first.click()
    shot(page, 'p02-setup')
    page.get_by_role('button', name='Found Tarang Air').click()
    page.get_by_text('Get flying').wait_for()
    shot(page, 'p03-home-new')

    print('admin starts the world')
    sql("update profiles set is_admin = true")
    page.reload(); page.wait_for_load_state('networkidle')
    go(page, '/admin')
    page.get_by_text('Invite colleagues').wait_for()
    expect(page.locator('.card.tight.num')).to_contain_text(CODE)
    shot(page, 'p04-admin')
    page.get_by_role('button', name='Start the world').click()
    page.locator('.sheet').get_by_role('button', name='Start', exact=True).click()
    toast_ok(page, 'has started')
    page.get_by_label('One game week takes').select_option('1')
    page.get_by_role('button', name='Change the clock').click()
    toast_ok(page, 'now takes 1 hour')

    print('open a route and assign the aircraft')
    go(page, '/network')
    page.get_by_role('button', name='Open route').first.click()
    page.locator('.sheet .item', has_text='BOM').first.click()
    page.locator('.sheet').get_by_role('button', name='Quick study').click()
    toast_ok(page, 'Study done')
    expect(page.locator('.sheet')).to_contain_text('Nobody flies it now')
    shot(page, 'p05a-study')
    page.locator('.sheet').get_by_role('button', name='Open route').click()
    toast_ok(page, 'Route opened')
    page.get_by_text('Put an aircraft on this route').wait_for()
    shot(page, 'p05-assign')
    page.get_by_role('button', name='Assign').click()
    toast_ok(page, 'round trips a week')

    print('pilots: set pay and spare pilots')
    go(page, '/fleet')
    page.get_by_role('button', name='Adjust pilots').click()
    page.get_by_role('button', name='More pilot pay').click()
    page.get_by_role('button', name='More spare pilots').click()
    shot(page, 'p05b-pilots')
    page.get_by_role('button', name='Save pilot settings').click()
    toast_ok(page, 'Pilot settings saved')

    print('the pre-launch: 13 weeks with nothing flying')
    go(page, '/')
    page.get_by_text('Pre-launch: 13 weeks to your first flights').wait_for()
    expect(page.locator('.page-head .sub')).to_contain_text('Week 1 · 1 to 7 Jan 3000')
    shot(page, 'p05c-prelaunch')
    for _ in range(84):
        sql(f"select game.run_day('{WORLD}')")
    page.reload(); page.wait_for_load_state('networkidle'); page.wait_for_timeout(800)
    page.get_by_text('Pre-launch: 1 week to your first flights').wait_for()
    expect(page.locator('.page-head .sub')).to_contain_text('Week 13 · 26 Mar to 1 Apr 3000')
    assert sql(f"select count(*) from airline_daily d join airlines a on a.id = d.airline_id where a.world_id = '{WORLD}'") == '0', 'something flew in the pre-launch'

    print('fly week 14, the first week of flights')
    for _ in range(14):
        sql(f"select game.run_day('{WORLD}')")
    page.reload(); page.wait_for_load_state('networkidle'); page.wait_for_timeout(800)
    go(page, '/')
    page.get_by_text("Last week's profit").wait_for()
    shot(page, 'p06-home')

    go(page, '/network'); page.wait_for_timeout(600)
    shot(page, 'p07-network')
    page.locator('.list .item.link').first.click()
    page.get_by_text('How full, last 4 weeks').wait_for()
    page.get_by_role('button', name='More economy fare').click()
    page.get_by_role('button', name='Save fares').click()
    toast_ok(page, 'Fares saved')
    page.get_by_role('button', name='Full study').click()
    toast_ok(page, 'Study done')
    expect(page.locator('.card', has_text='Route study')).to_contain_text('Business · leisure · budget')
    expect(page.get_by_text('Break-even load')).to_be_visible()
    expect(page.get_by_text('CASK', exact=True)).to_be_visible()
    shot(page, 'p08-route')

    print('lease from the pool')
    go(page, '/market')
    page.locator('.list .item.link').first.click()
    page.get_by_role('button', name='More aircraft to lease').click()
    page.get_by_role('button', name='Lease 2 aircraft').click()
    toast_ok(page, 'leased')
    page.get_by_role('heading', name='Fleet').wait_for()
    shot(page, 'p09-fleet')

    print('wet lease')
    go(page, '/market?tab=wet')
    page.get_by_role('button', name='Wet-lease one').nth(1).click()
    page.get_by_role('button', name='Wet-lease it').click()
    toast_ok(page, 'arrives in week')

    print('order with a business cabin, on a loan')
    go(page, '/market?tab=order')
    page.get_by_role('button', name='Choose cabin and order').nth(1).click()
    page.get_by_role('button', name='More business rows').click()
    page.get_by_role('button', name='More business rows').click()
    page.wait_for_timeout(500)
    shot(page, 'p10-configurator')
    page.get_by_role('button', name='More aircraft to order').click()
    page.get_by_role('button', name='Order 2 for').click()
    toast_ok(page, 'aircraft ordered')

    print('extras: include meals, raise the bag price')
    go(page, '/extras')
    page.get_by_text('How extras work').wait_for()
    page.locator('.card', has_text='Meal on board').get_by_role('tab', name='Include free').click()
    page.get_by_role('button', name='More Checked bag price').click()
    shot(page, 'p16-extras')
    page.get_by_role('button', name='Save extras').click()
    toast_ok(page, 'Extras saved')

    print('borrow, repay, marketing')
    go(page, '/money')
    page.get_by_role('button', name='Borrow').click(); toast_ok(page, 'Borrowed')
    page.get_by_label('Amount (₹ crore)').fill('5')
    page.get_by_role('button', name='Repay').click(); toast_ok(page, 'Repaid')
    for _ in range(3): page.get_by_role('button', name='More marketing a week').click()
    page.get_by_role('button', name='Save marketing').click(); toast_ok(page, 'Marketing spend saved')
    shot(page, 'p11-money')

    print('open a second base at BOM from the map')
    go(page, '/network'); page.wait_for_timeout(500)
    page.locator('svg text', has_text='BOM').first.click()
    page.get_by_role('button', name='Open a base here').click()
    toast_ok(page, 'is now a base')

    print('fly 7 more weeks so the leased aircraft arrive')
    for _ in range(49):
        sql(f"select game.run_day('{WORLD}')")
    page.reload(); page.wait_for_load_state('networkidle')

    print('move the leased aircraft to BOM, then refit it')
    go(page, '/fleet')
    expect(page.locator('.card.link', has_text='Wet lease').first).to_contain_text('Result last week')
    page.locator('.card.link', has_text='Wet lease').first.click()
    expect(page.locator('.card', has_text='Money')).to_contain_text('Wet-lease charge')
    shot(page, 'p12a-aircraft-money')
    page.go_back()
    page.locator('.card.link', has_text='Leased').first.click()
    page.get_by_role('button', name='Move to another base').click()
    page.get_by_label('New base').select_option('BOM')
    page.locator('.sheet').get_by_role('button', name='Move', exact=True).click()
    toast_ok(page, 'Moved to')
    page.get_by_role('button', name='Change cabin').click()
    page.get_by_role('button', name='Less economy pitch').click()
    page.get_by_role('button', name='Refit for').click()
    toast_ok(page, 'Refit booked')
    shot(page, 'p12-aircraft')

    if not os.environ.get('SKIP_TEARDOWN'):   # keeps a flying airline for screenshots
        print('take VT-AAA off its route, end its wet lease, close the route')
        go(page, '/network'); page.locator('.list .item.link').first.click()
        page.get_by_text('How full, last 4 weeks').wait_for()
        for _ in range(30):
            b_less = page.get_by_role('button', name='Less round trips a week').first
            if b_less.is_disabled(): break
            b_less.click()
        page.locator('.list .item', has_text='VT-AAA').get_by_role('button', name='Save').click()
        toast_ok(page, 'taken off this route')
        go(page, '/fleet')
        page.locator('.card.link', has_text='VT-AAA').click()
        page.get_by_role('button', name='End the wet lease').click()
        page.locator('.sheet').get_by_role('button', name='End the wet lease').click()
        toast_ok(page, 'wet lease has ended')
        go(page, '/network'); page.locator('.list .item.link').first.click()
        page.get_by_role('button', name='Close this route').click()
        page.locator('.sheet').get_by_role('button', name='Close route').click()
        toast_ok(page, 'Route closed')

    go(page, '/ranks'); page.wait_for_timeout(500)
    shot(page, 'p13-ranks')

    # Home menu sheet
    go(page, '/')
    page.get_by_role('button', name='Menu').click()
    shot(page, 'p14-menu')
    ctx.close()

    # ---------- Laptop ----------
    ctx = b.new_context(viewport={'width': 1440, 'height': 900})
    page = ctx.new_page(); watch(page)
    go(page, '/')
    page.get_by_role('tab', name='Sign in').click()
    page.get_by_label('Email').fill(EMAIL)
    page.get_by_label('Password').fill(PW)
    page.get_by_role('button', name='Sign in', exact=True).click()
    page.get_by_text("Last week's profit").wait_for()
    shot(page, 'd01-home')
    for h, n in [('/extras', 'd09-extras'), ('/network', 'd02-network'), ('/fleet', 'd04-fleet'), ('/money', 'd05-money'), ('/market', 'd06-market'), ('/ranks', 'd08-ranks'), ('/configure/A21N', 'd07-configurator')]:
        go(page, h); page.wait_for_timeout(700); shot(page, n)
    go(page, '/network')
    if page.locator('.list .item.link').count():
        page.locator('.list .item.link').first.click(); page.get_by_text('How full, last 4 weeks').wait_for()
        shot(page, 'd03-route')
    ctx.close()

    print('an existing player joins a second world from its invite link')
    sql("insert into worlds (name, demand_scale) values ('Test World', 0.5)")
    sql("insert into world_secrets (world_id, invite_code) select id, 'second01' from worlds where name = 'Test World'")
    ctx = b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    page = ctx.new_page(); watch(page)
    mark = len(errors)   # the join function answers 400 "already exists" here by design
    go(page, '/join?code=second01')
    page.get_by_label('Email').fill(EMAIL)
    page.get_by_label('Password').fill(PW)
    page.get_by_role('button', name='Create account').click()
    page.get_by_text('Found your airline').wait_for()
    expect(page.get_by_label('Invite code')).to_have_value('second01')
    page.get_by_label('Airline name').fill('Second Air')
    page.locator('.item', has_text='BOM').first.click()
    page.get_by_role('button', name='Found Second Air').click()
    page.get_by_role('heading', name='Second Air').wait_for()
    shot(page, 'p15-second-world')
    errors[mark:] = [e for e in errors[mark:] if 'status of 400' not in e]
    ctx.close()
    b.close()

print('\nerrors:' if errors else '\nno page errors')
for e in errors: print(' ', e)
sys.exit(1 if errors else 0)
