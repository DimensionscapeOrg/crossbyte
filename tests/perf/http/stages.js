// Writes a suite.js case list comparing staged builds (export/perf-http/bin/
// <stage>.exe) on one workload, so suite.js runs them interleaved.
//
// node tests/perf/http/stages.js <out.json> <workload> <stage> [<stage>...]
//
// Workloads: h1 (one middleware, browser fields), h1bare (Host only), h2
// (8x8 streams, browser fields), h2big (64 KB respondBytes over HTTP/2),
// static (a 79 B file), staticgz (a 4 KB JSON file to a gzip client: the
// kept compressed body), route50 (50 REST routes).
'use strict';
const fs = require('fs');
const [out, workload, ...stages] = process.argv.slice(2);
const h1 = ['--conns', '32', '--procs', '4', '--headers', 'browser'];
const h2 = ['--sessions', '8', '--streams', '8', '--procs', '4', '--headers', 'browser'];
const w = {
  h1: { scenario: 'mw', load: 'http', env: '', args: h1 },
  h1bare: { scenario: 'mw', load: 'http', env: '', args: ['--conns', '32', '--procs', '4'] },
  h2: { scenario: 'mw', load: 'h2', env: 'PERF_HTTP2=1', args: h2 },
  h2big: { scenario: 'big', load: 'h2', env: 'PERF_HTTP2=1', args: ['--sessions', '8', '--streams', '8', '--procs', '4'] },
  h1big: { scenario: 'big', load: 'http', env: '', args: ['--conns', '32', '--procs', '4'] },
  static: { scenario: 'static', load: 'http', env: '', args: h1.concat(['--path', '/small.json']) },
  staticgz: { scenario: 'static', load: 'http', env: '', args: ['--conns', '32', '--procs', '4', '--headers', 'browser', '--path', '/medium.json'] },
  route50: { scenario: 'route', load: 'http', env: 'PERF_ROUTES=50,PERF_ROUTE_SHAPE=rest', args: h1.concat(['--path', '/api/v1/items/42']) },
}[workload];
if (!w) throw new Error('unknown workload ' + workload);
const cases = stages.map((s) => Object.assign({ label: workload + '-' + s, exe: 'export/perf-http/bin/' + s + '.exe', seconds: 10, warmup: 2 }, w));
fs.writeFileSync(out, JSON.stringify(cases, null, 1));
