// Typechecks the fenced code examples in the public documentation.
//
// The examples ship: `ci/docs-api.hxml` copies these comments into
// `export/docs-api/crossbyte.xml`, so a reader who copies one out expects it
// to compile. For a long time none in `io/File.hx` did. CrossByte's docs
// descend from Adobe's ActionScript text and the examples came with it --
// `var x:Array`, `for (var i:uint = 0; ...)`, `:void`. Underneath the syntax
// were real API defects that reading had not caught: a documented
// `listDirectory()` that does not exist, an instance method called
// statically, a `catch (e:Error)` with no import, a Windows path whose
// unescaped `\D` Haxe rejects outright, and two async examples that
// registered a listener after starting the operation, with the handler
// declared below its own use. A reviewer can miss all of that. A compiler
// cannot, so this asks one.
//
// Only the files in STANDALONE are checked, because not every good example is
// a whole program. An example is often a fragment with an implied receiver --
//
//     connection.requestParams("SELECT payload FROM events WHERE id = $1", ...)
//
// -- and writing the setup out would bury the line being illustrated. Those
// files are simply not listed. Add a file here once its examples stand alone;
// the list is a floor that ratchets, not a claim about the rest.
//
// Usage: node ci/doc-examples.js [path substring]
// Needs haxe on PATH. Typechecks only -- `-D no-compilation` generates no C++
// and runs nothing, so the examples never touch a filesystem.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'src');

const STANDALONE = ['src/crossbyte/io/File.hx'];

function hxFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) hxFiles(full, out);
    else if (entry.name.endsWith('.hx')) out.push(full);
  }
  return out;
}

// Every ```hx / ```haxe block, with the 1-based line its body opens on.
function blocksIn(file, rel) {
  const lines = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').split('\n');
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const fence = lines[i].trim();
    if (fence !== '```hx' && fence !== '```haxe') continue;
    let j = i + 1;
    while (j < lines.length && lines[j].trim() !== '```') j++;
    if (j >= lines.length) {
      console.error(`${rel}:${i + 1}: unterminated code fence`);
      process.exit(2);
    }
    found.push({ startLine: i + 2, body: lines.slice(i + 1, j) });
    i = j;
  }
  return found;
}

// Doc comments indent to sit inside the comment, not the example.
function dedent(body) {
  const widths = body
    .filter((l) => l.trim().length > 0)
    .map((l) => l.length - l.replace(/^[\t ]+/, '').length);
  const strip = widths.length ? Math.min(...widths) : 0;
  return body.map((l) => (l.trim().length ? l.slice(strip) : ''));
}

const filter = process.argv[2];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crossbyte-docex-'));
const modules = [];

for (const file of hxFiles(SRC)) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  if (!STANDALONE.includes(rel)) continue;
  if (filter && !rel.includes(filter)) continue;

  for (const block of blocksIn(file, rel)) {
    // Each line keeps the line it came from: imports are hoisted out of the
    // middle of the body, so a generated line number is not the original one
    // plus a constant, and a report off by two sends the reader to the wrong
    // line of their own file.
    const body = dedent(block.body).map((text, i) => ({ text, line: block.startLine + i }));
    const imports = body.filter((e) => /^(import|using)\s/.test(e.text));
    const code = body.filter((e) => !/^(import|using)\s/.test(e.text));
    while (code.length && !code[0].text.trim()) code.shift();
    while (code.length && !code[code.length - 1].text.trim()) code.pop();
    if (!code.length) continue;

    // A bare expression is a legitimate way to write a one-line example.
    const last = code[code.length - 1].text.trimEnd();
    if (!last.endsWith(';') && !last.endsWith('}')) {
      code[code.length - 1].text = last + ';';
    }

    // The reader of a doc comment is already inside that package, so an
    // example naming its neighbours unqualified is right to. Give the harness
    // the same view rather than reporting a missing import that is not one.
    const pkg = path.dirname(rel).replace(/^src\//, '').replace(/\//g, '.');
    const name = 'DocEx' + modules.length;
    const preamble = [
      'import ' + pkg + '.*;',
      ...imports.map((e) => e.text),
      '',
      'class ' + name + ' {',
      '\tpublic static function run():Void {',
    ];
    const source = [
      ...preamble,
      ...code.map((e) => (e.text.trim() ? '\t\t' + e.text : '')),
      '\t}',
      '}',
      '',
    ];
    fs.writeFileSync(path.join(tmp, name + '.hx'), source.join('\n'), 'utf8');

    modules.push({
      name,
      file: rel,
      preamble: preamble.length,
      lines: code.map((e) => e.line),
    });
  }
}

if (!modules.length) {
  console.error('No documentation examples found. Check STANDALONE, or the filter argument.');
  process.exit(2);
}

// Never runs. Guarded so the generated program is a typecheck target only,
// and -D no-compilation means it is not even built.
const main = [
  'class DocExamplesMain {',
  '\tpublic static function main():Void {',
  '\t\tif (Sys.args().length > 0xFFFF) {',
  ...modules.map((m) => '\t\t\t' + m.name + '.run();'),
  '\t\t}',
  '\t}',
  '}',
  '',
].join('\n');
fs.writeFileSync(path.join(tmp, 'DocExamplesMain.hx'), main, 'utf8');

const haxe = spawnSync(
  'haxe',
  ['-cp', 'src', '-cp', tmp, '-main', 'DocExamplesMain', '--cpp', path.join(tmp, 'out'), '-D', 'no-compilation'],
  { cwd: ROOT, encoding: 'utf8', shell: process.platform === 'win32' }
);

if (haxe.error) {
  console.error('Could not run haxe: ' + haxe.error.message);
  process.exit(2);
}

const output = ((haxe.stdout || '') + (haxe.stderr || '')).trim();

if (haxe.status === 0) {
  console.log('doc examples: ' + modules.length + ' typechecked, 0 failures');
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exit(0);
}

// Report against the documentation, not the scratch file the reader will
// never see.
const byName = new Map(modules.map((m) => [m.name, m]));
for (const line of output.split('\n')) {
  const match = line.match(/(DocEx\d+)\.hx:(\d+):(.*)$/);
  if (!match) {
    console.error(line);
    continue;
  }
  const mod = byName.get(match[1]);
  const index = Number(match[2]) - mod.preamble - 1;
  const original = mod.lines[index] != null ? mod.lines[index] : mod.lines[0];
  console.error(mod.file + ':' + original + ':' + match[3]);
}

console.error('');
console.error('doc examples: ' + modules.length + ' typechecked, at least one failed.');
console.error('Generated sources kept for inspection: ' + tmp);
process.exit(1);
