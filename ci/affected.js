// Which test classes a change can reach, from the compiler's own dependency graph.
//
//   node ci/affected.js                 changes since the merge base with origin/main
//   node ci/affected.js <ref>           changes since this branch left <ref>
//   node ci/affected.js --files a b     these files
//   node ci/affected.js --github        also write the result to $GITHUB_OUTPUT
//
// For each test graph it prints FULL (with the reason), NONE, or the classes to
// run as a CB_ONLY value for a suite built with -D gc_bisect. Two graphs are
// built: the native suite's (cpp, standing for every sys target: native, jvm,
// interp, neko, HashLink, PHP) and Node's (js, standing for Node and the
// browser). Each is dumped by the compiler from the tree as it is now, so a
// file a change adds is in it.
//
// A selection is a fast check, not a proof: anything the graph cannot see
// (timing, reflection, a test reading a file) is only caught by a full run, so
// main and releases always run everything.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
// Past this share of the suite a selection saves too little to be worth what
// it might miss.
const FULL_SHARE = 0.6;
// Run whenever library code changes: what these check does not show in a
// dependency (an allocation, a leak).
const ALWAYS = ["crossbyte.AllocationBudgetTest"];
const REGISTRIES = ["tests/crossbyte/test/TestSuites.hx", "tests/crossbyte/test/PortableSuite.hx", "tests/crossbyte/test/ServerSuite.hx"];

const GRAPHS = {
	cpp: { hxml: "ci/native-tests.hxml", extra: ["-D", "no-compilation"], dump: "dump/cpp/dependants.dump" },
	js: { hxml: "ci/js-tests.hxml", extra: [], dump: "dump/js/dependants.dump" },
};

function git(args) {
	return execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trim();
}

function changedFiles(argv) {
	const at = argv.indexOf("--files");
	if (at >= 0) {
		return argv.slice(at + 1).filter((a) => !a.startsWith("--"));
	}
	const ref = argv.find((a) => !a.startsWith("--"));
	// From where this branch left the other, so its own later changes are not counted.
	const base = git(["merge-base", "HEAD", ref || "origin/main"]);
	const committed = git(["diff", "--name-only", base, "HEAD"]);
	const working = git(["diff", "--name-only", "HEAD"]);
	return [...new Set((committed + "\n" + working).split("\n").filter(Boolean))];
}

// A change here can reach every test, or reaches code the graph does not cover.
function fullReason(file) {
	if (file.startsWith("std/")) return "standard library override " + file;
	if (file === "extraParams.hxml" || file === "haxelib.json") return file;
	if (file.startsWith("ci/") || file.startsWith(".github/")) return "CI file " + file;
	if (/\/macro\//.test(file) || /Macro\.hx$/.test(file)) return "macro " + file;
	if (/\.(c|cc|cpp|h|hpp|xml)$/.test(file) && file.startsWith("src/")) return "native code " + file;
	if (file.startsWith("tests/") && !file.startsWith("tests/crossbyte/")) return "suite main " + file;
	// The suite lists only say which cases run: a case added to one is in the
	// change itself.
	if (REGISTRIES.includes(file)) return null;
	if (file.startsWith("tests/crossbyte/test/")) return "test harness " + file;
	return null;
}

function loadGraph(name) {
	const graph = GRAPHS[name];
	execFileSync("haxe", [graph.hxml, "-D", "dump-dependencies", ...graph.extra], { cwd: ROOT, stdio: ["ignore", "ignore", "inherit"] });
	const dependants = new Map();
	let current = null;
	for (const line of fs.readFileSync(path.join(ROOT, graph.dump), "utf8").split(/\r?\n/)) {
		if (!line) continue;
		if (line.startsWith("\t")) {
			dependants.get(current).push(key(line.trim()));
		} else {
			current = key(line.replace(/:$/, ""));
			if (!dependants.has(current)) dependants.set(current, []);
		}
	}
	return dependants;
}

function key(file) {
	return path.resolve(ROOT, file).toLowerCase();
}

const TESTS = key("tests") + path.sep;
const SRC = key("src") + path.sep;
const isTestCase = (k) => k.startsWith(TESTS) && /test\.hx$/.test(k);

function className(k) {
	const rel = path.relative(TESTS, k).replace(/\.hx$/, "");
	// The dump is lower-cased for matching; take the real spelling from disk.
	const real = findReal(rel.split(path.sep));
	return real.join(".");
}

function findReal(parts) {
	let dir = path.join(ROOT, "tests");
	const out = [];
	for (let i = 0; i < parts.length; i++) {
		const want = i === parts.length - 1 ? parts[i] + ".hx" : parts[i];
		const hit = fs.readdirSync(dir).find((n) => n.toLowerCase() === want);
		out.push(i === parts.length - 1 ? hit.replace(/\.hx$/, "") : hit);
		dir = path.join(dir, hit);
	}
	return out;
}

function select(name, files) {
	const hx = files.filter((f) => f.endsWith(".hx"));
	if (hx.length === 0) return { mode: "none" };
	const dependants = loadGraph(name);
	const all = [...dependants.keys()].filter(isTestCase);
	const chosen = new Set();
	let library = false;
	for (const f of hx) {
		const k = key(f);
		if (k.startsWith(SRC)) library = true;
		if (!fs.existsSync(k)) continue; // deleted: whatever used it changed too
		if (!dependants.has(k)) continue; // not built for this graph's target
		if (isTestCase(k)) chosen.add(k);
		const seen = new Set([k]);
		const queue = [k];
		while (queue.length) {
			for (const d of dependants.get(queue.pop()) || []) {
				if (seen.has(d)) continue;
				seen.add(d);
				if (isTestCase(d)) chosen.add(d);
				// Through library code and test helpers, not out of a test case
				// or through the harness, which every case depends on.
				else if (!d.startsWith(key("tests/crossbyte/test") + path.sep)) queue.push(d);
			}
		}
	}
	if (chosen.size === 0 && !library) return { mode: "none" };
	if (chosen.size > all.length * FULL_SHARE) return { mode: "full", reason: `reaches ${chosen.size} of ${all.length} test classes` };
	const names = [...chosen].map(className);
	if (library) for (const a of ALWAYS) if (!names.includes(a)) names.push(a);
	return { mode: "selected", classes: names.sort(), of: all.length };
}

function main() {
	const argv = process.argv.slice(2);
	const files = changedFiles(argv);
	const results = {};
	const reason = files.map(fullReason).find((r) => r != null);
	for (const name of Object.keys(GRAPHS)) {
		results[name] = reason != null ? { mode: "full", reason } : select(name, files);
	}
	const docs = files.some((f) => f.endsWith(".md") || f.startsWith("src/"));

	console.log(`changed: ${files.length} file(s)`);
	for (const [name, r] of Object.entries(results)) {
		if (r.mode === "full") console.log(`${name}: FULL (${r.reason})`);
		else if (r.mode === "none") console.log(`${name}: NONE`);
		else console.log(`${name}: ${r.classes.length} of ${r.of} test classes\n  CB_ONLY=${r.classes.join(",")}`);
	}
	console.log(`docs: ${docs ? "run" : "skip"}`);

	if (argv.includes("--github") && process.env.GITHUB_OUTPUT) {
		const out = [];
		for (const [name, r] of Object.entries(results)) {
			out.push(`${name}_mode=${r.mode}`);
			out.push(`${name}_only=${r.mode === "selected" ? r.classes.join(",") : ""}`);
			out.push(`${name}_flags=${r.mode === "selected" ? "-D gc_bisect" : ""}`);
		}
		out.push(`docs=${docs}`);
		fs.appendFileSync(process.env.GITHUB_OUTPUT, out.join("\n") + "\n");
	}
}

main();
