// Stand-in for the Claude Messages API, so the consultant edge function can be tested end to end without a key or the
// internet. Turn 1 asks for the overview, routes and fleet; turn 2 hands in a report that uses the first route and
// aircraft it was shown (the route by its airport codes, as a model may, to test that the function turns it into the id;
// and one action with a made-up aircraft, to test that it is dropped). Every request is appended to /tmp/claude_stub.log (one JSON per line) for e2e.py to check.
// Usage: node claude_stub.mjs   (port 54331, or PORT)
import http from 'http';
import fs from 'fs';

const PORT = Number(process.env.PORT || 54331);
const LOG = process.env.CLAUDE_STUB_LOG || '/tmp/claude_stub.log';
const ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    const body = JSON.parse(raw || '{}');
    fs.appendFileSync(LOG, JSON.stringify({ headers: { key: Boolean(req.headers['x-api-key']), version: req.headers['anthropic-version'] }, body }) + '\n');
    const turn = (body.messages ?? []).filter((m) => m.role === 'assistant').length;
    const usage = { input_tokens: 400, cache_creation_input_tokens: turn ? 900 : 2600, cache_read_input_tokens: turn ? 2600 : 0, output_tokens: 300 };
    let content;
    if (turn === 0 && body.tool_choice?.type !== 'tool') {
      content = [{ type: 'text', text: 'Looking at the books.' },
        ...['overview', 'routes', 'fleet'].map((name, i) => ({ type: 'tool_use', id: `toolu_${i}`, name, input: {} }))];
    } else {
      const results = body.messages.flatMap((m) => (Array.isArray(m.content) ? m.content : [])).filter((b) => b.type === 'tool_result');
      const routes = JSON.parse(results.find((r) => r.tool_use_id === 'toolu_1')?.content ?? '[]');
      const fleet = JSON.parse(results.find((r) => r.tool_use_id === 'toolu_2')?.content ?? '[]');
      const route = routes[0]?.route_id, aircraft = fleet.find((a) => a.status === 'active')?.aircraft_id;
      content = [{ type: 'tool_use', id: 'toolu_9', name: 'submit_report', input: {
        summary: 'Stub report: the airline flies one thin route and pays for more seats than it fills.',
        problems: [
          { title: 'Seats flying empty', evidence: `Route ${routes[0]?.from}-${routes[0]?.to}: load ${routes[0]?.load_factor_28d}.`, tag: 'Certain' },
          { title: 'Fuel unhedged', evidence: 'No fuel hedge while fuel is above normal.', tag: 'Likely' },
          { title: 'Thin network', evidence: 'One route carries the whole fleet.', tag: 'Guessing' },
        ],
        actions: [
          { title: 'Sell this route to fill', fn: 'set_strategy', route_id: `${routes[0]?.from}\u2013${routes[0]?.to}`, strategy: 'fill', why: 'Empty seats earn nothing.', effect: 'Rs 1 to 3 lakh a week', risk: 'Fewer passengers early.', tag: 'Likely' },
          { title: 'Hedge a quarter of fuel', fn: 'set_hedge', share: 0.25, why: 'Shocks cost more than the 2%.', effect: 'Rs 0 to 1 lakh a week', risk: 'Fuel may fall.', tag: 'Guessing' },
          { title: 'A made-up aircraft', fn: 'return_aircraft', aircraft_id: '00000000-0000-0000-0000-000000000000', why: 'x', effect: 'x', risk: 'x', tag: 'Certain' },
        ],
        missing: ID.test(String(aircraft)) ? null : 'No active aircraft was shown',
      } }];
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ id: 'msg_stub', type: 'message', role: 'assistant', model: body.model, content,
      stop_reason: 'tool_use', usage }));
  });
}).listen(PORT, () => console.log(`claude stub on http://localhost:${PORT}`));
