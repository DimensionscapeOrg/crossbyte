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
// Two kinds of file are checked. Source files in STANDALONE, whose doc
// comments hold ```hx examples, and guides in GUIDES, markdown whose ```haxe
// blocks are examples. Only listed files are checked, because not every good
// example is a whole program. An example is often a fragment with an implied
// receiver --
//
//     connection.requestParams("SELECT payload FROM events WHERE id = $1", ...)
//
// -- and writing the setup out would bury the line being illustrated. Those
// files are simply not listed. Add a file here once its examples check; the
// lists are a floor that ratchets, not a claim about the rest.
//
// All of one file's examples make one module, in the order they appear, so a
// later example can use what an earlier one declared, as its reader does:
//
// - A block that declares types -- its first line after the imports opens a
//   class, interface, typedef, enum or abstract, or is metadata on one -- goes
//   into the module as written.
// - Any other block is statements, and becomes a function of its own. If its
//   first line is a comment of the form
//
//       // Given commands:ChatCommands, session:RPCSession<ChatCommands>.
//
//   those become the function's parameters: the receiver the example assumes
//   is typed as if it had been set up, without the setup.
//
// Imports anywhere in a block are hoisted to the top of the module.
//
// Usage: node ci/doc-examples.js [path substring]
// Needs haxe on PATH. Typechecks only -- `-D no-compilation` generates no C++
// and runs nothing, so the examples never touch a filesystem or a network.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');

const STANDALONE = ['src/crossbyte/io/File.hx', 'src/crossbyte/rpc/RPCCommands.hx'];
const GUIDES = ['docs/rpc.md'];

// Every fenced block of one of `languages`, with the 1-based line its body
// opens on.
function blocksIn(file, rel, languages) {
  const lines = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').split('\n');
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const fence = lines[i].trim();
    if (!languages.includes(fence)) continue;
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

const DECLARATION = /^(@:|((private|final|abstract|extern)\s+)*(class|interface|typedef|enum|abstract)\b)/;
const IMPORT = /^(import|using)\s/;
const GIVEN = /^\/\/\s*Given\s+(.+?)\.?\s*$/;

// `a:T, b:Map<K, V>` split on the commas that separate parameters.
function splitParams(text) {
  const params = [];
  let depth = 0;
  let current = '';
  for (const ch of text) {
    if (ch === '<' || ch === '(') depth++;
    if (ch === '>' || ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      params.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) params.push(current.trim());
  return params;
}

const filter = process.argv[2];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'crossbyte-docex-'));
const modules = [];
let exampleCount = 0;

const sources = [
  ...STANDALONE.map((rel) => ({ rel, languages: ['```hx', '```haxe'], pkg: path.dirname(rel).replace(/^src\//, '').replace(/\//g, '.') })),
  ...GUIDES.map((rel) => ({ rel, languages: ['```haxe', '```hx'], pkg: null })),
];

for (const source of sources) {
  const { rel, languages, pkg } = source;
  if (filter && !rel.includes(filter)) continue;
  const file = path.join(ROOT, rel);
  if (!fs.existsSync(file)) {
    console.error(`${rel}: listed but missing`);
    process.exit(2);
  }

  const name = 'DocEx' + modules.length;
  // Each generated line keeps the line it came from: imports are hoisted, so
  // a generated line number is not the original plus a constant, and a report
  // off by two sends the reader to the wrong line of their own file.
  const imports = [];
  const declarations = [];
  const functions = [];

  for (const block of blocksIn(file, rel, languages)) {
    const body = dedent(block.body).map((text, i) => ({ text, line: block.startLine + i }));
    for (const entry of body.filter((e) => IMPORT.test(e.text))) {
      if (!imports.some((i) => i.text === entry.text)) imports.push(entry);
    }
    const code = body.filter((e) => !IMPORT.test(e.text));
    while (code.length && !code[0].text.trim()) code.shift();
    while (code.length && !code[code.length - 1].text.trim()) code.pop();
    if (!code.length) continue;
    exampleCount++;

    if (DECLARATION.test(code[0].text)) {
      declarations.push(...code, { text: '', line: null });
      continue;
    }

    let params = [];
    const given = code[0].text.match(GIVEN);
    if (given) {
      params = splitParams(given[1]);
    }

    // A bare expression is a legitimate way to write a one-line example.
    const last = code[code.length - 1].text.trimEnd();
    if (!last.endsWith(';') && !last.endsWith('}')) {
      code[code.length - 1] = { text: last + ';', line: code[code.length - 1].line };
    }
    functions.push({ params, code });
  }

  const out = [];
  const map = [];
  const emit = (text, line) => {
    out.push(text);
    map.push(line);
  };
  // The reader of a doc comment is already inside that package, so an
  // example naming its neighbours unqualified is right to. Give the harness
  // the same view rather than reporting a missing import that is not one.
  if (pkg) emit('import ' + pkg + '.*;', null);
  for (const entry of imports) emit(entry.text, entry.line);
  emit('', null);
  for (const entry of declarations) emit(entry.text, entry.line);
  emit('class ' + name + ' {', null);
  functions.forEach((fn, index) => {
    emit('\tpublic static function example' + index + '(' + fn.params.join(', ') + '):Void {', fn.code[0].line);
    for (const entry of fn.code) emit(entry.text.trim() ? '\t\t' + entry.text : '', entry.line);
    emit('\t}', null);
  });
  emit('}', null);
  emit('', null);

  fs.writeFileSync(path.join(tmp, name + '.hx'), out.join('\n'), 'utf8');
  modules.push({ name, file: rel, map });
}

if (!modules.length || exampleCount === 0) {
  console.error('No documentation examples found. Check STANDALONE and GUIDES, or the filter argument.');
  process.exit(2);
}

// Never runs. Naming each module's class is enough for it to be typed, and
// -D no-compilation means it is not even built.
const main = [
  'class DocExamplesMain {',
  '\tpublic static function main():Void {',
  ...modules.map((m) => '\t\tvar _ = ' + m.name + ';'),
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
  console.log('doc examples: ' + exampleCount + ' typechecked in ' + modules.length + ' file(s), 0 failures');
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
  const original = mod.map[Number(match[2]) - 1];
  console.error(mod.file + ':' + (original != null ? original : '?') + ':' + match[3]);
}

console.error('');
console.error('doc examples: ' + exampleCount + ' typechecked, at least one failed.');
console.error('Generated sources kept for inspection: ' + tmp);
process.exit(1);
