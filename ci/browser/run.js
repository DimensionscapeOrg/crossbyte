// Runs the portable suite in a headless browser and fails if anything in it
// fails -- or if the page throws at all.
//
// That second condition is the reason this exists. The bug that prompted it
// threw while the bundle was loading, so no test ran, no assertion failed, and
// a runner that only read the test result would have called an empty run a
// pass. A page error is a failure here whether or not any assertion noticed.
//
// Usage: node ci/browser/run.js
// Needs puppeteer (`npm install --no-save puppeteer`) and the bundle built by
// `haxe ci/browser-tests.hxml`.

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 50573;
const ROOT = __dirname;
const BUNDLE = path.join(__dirname, '..', '..', 'export', 'browser-tests', 'tests.js');
const TIMEOUT_MS = 120000;

let puppeteer;
try {
  puppeteer = require('puppeteer');
} catch (_) {
  console.error('puppeteer is not installed. Run: npm install --no-save puppeteer');
  console.error('(the CI job does this; locally it is a one-off)');
  process.exit(2);
}

if (!fs.existsSync(BUNDLE)) {
  console.error('No bundle at ' + BUNDLE + '. Build it first: haxe ci/browser-tests.hxml');
  process.exit(2);
}

const types = { '.html': 'text/html', '.js': 'text/javascript' };

const server = http.createServer((request, response) => {
  const requested = request.url.split('?')[0];

  // A browser asks for this unprompted and logs a console error when it is
  // missing. Answering it is simpler than teaching the error check to ignore
  // one particular failure, and leaves that check strict: any console error
  // fails the run.
  if (requested === '/favicon.ico') {
    response.writeHead(204);
    response.end();
    return;
  }

  const file = requested === '/tests.js' ? BUNDLE : path.join(ROOT, requested === '/' ? 'index.html' : requested);

  fs.readFile(file, (error, body) => {
    if (error) {
      response.writeHead(404);
      response.end('not found');
      return;
    }
    response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'text/plain' });
    response.end(body);
  });
});

(async () => {
  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));

  const browser = await puppeteer.launch({
    // Both flags are for CI rather than for us: a Linux container often runs
    // as root, where Chrome's sandbox refuses to start, and /dev/shm is
    // frequently too small there. Harmless anywhere else.
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  const page = await browser.newPage();
  const pageErrors = [];

  // Resolved by the first page error, so a bundle that throws while loading
  // fails in a second rather than after the full timeout. Waiting the whole
  // two minutes to learn nothing ever started is the slowest possible way to
  // deliver that news.
  let sawPageError;
  const firstPageError = new Promise(resolve => { sawPageError = resolve; });

  page.on('pageerror', error => {
    pageErrors.push(String(error));
    sawPageError();
  });
  const consoleLines = [];

  page.on('console', message => {
    const text = message.text();
    consoleLines.push(text);

    if (message.type() === 'error') {
      pageErrors.push('console.error: ' + text);
    }
  });

  let result = null;

  try {
    await page.goto('http://127.0.0.1:' + PORT + '/index.html', { waitUntil: 'domcontentloaded' });
    await Promise.race([
      page.waitForFunction('window.__crossbyte && window.__crossbyte.done', { timeout: TIMEOUT_MS }),
      firstPageError
    ]);

    result = await page.evaluate('window.__crossbyte || null');
  } catch (error) {
    // A timeout here usually means the bundle threw before the runner
    // finished, so the page errors below are the interesting part.
    console.error('The suite did not complete: ' + error.message);
  }

  // utest's report goes through trace, which in a page is console.log, so
  // what was captured above is the readable account of a failure.
  const report = consoleLines.join('\n');

  await browser.close();
  server.close();

  if (pageErrors.length > 0) {
    console.error('The page reported ' + pageErrors.length + ' error(s):');
    for (const error of pageErrors) {
      console.error('  ' + error);
    }
  }

  if (result) {
    console.log('browser: ' + result.successes + ' successes, ' + result.failures + ' failures');
  }

  if (result && result.detail && result.detail.length > 0) {
    for (const line of result.detail) {
      console.error('  ' + line);
    }
  }

  if (!result) {
    console.error(report);
  }

  const ok = result && result.failures === 0 && pageErrors.length === 0;
  process.exit(ok ? 0 : 1);
})();
