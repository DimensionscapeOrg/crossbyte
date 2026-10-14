// Stellar's hot messages through CrossByte's typed patches (A: today's field
// types, B: quantized), one bit stream (S), Yggdrasil's codec today (Y) and
// protobuf (grpc-go's and grpc-js's runtimes), natively, on the jvm and on
// Node. Every cell runs in a process of its own, once a rep, the order turned
// by one each rep; medians of the reps. docs/performance.md says how to
// build what it runs.
//
//   node tests/perf/replication/run.js --grpc-node <dir holding node_modules> [--reps 3]
//   node tests/perf/replication/run.js --summary export/replication/results.jsonl
//
// Run from the repository root.
"use strict";
const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const opt = (name, fallback) => {
	const i = args.indexOf("--" + name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const root = process.cwd();
const exe = process.platform === "win32" ? ".exe" : "";
const out = path.resolve(opt("out", "export/replication/results.jsonl"));
const trace = path.resolve("export/replication/trace.bin");

function cells() {
	const list = [];
	for (const system of ["A", "B", "S", "Y"]) {
		list.push({name: "native " + system, cmd: path.join(root, "export/replication/native/ReplicationBench" + exe), args: ["--systems", system]});
		list.push({name: "jvm " + system, cmd: "java", args: ["-jar", path.join(root, "export/replication/jvm/ReplicationBench.jar"), "--systems", system]});
		list.push({name: "node " + system, cmd: "node", args: [path.join(root, "export/replication/node/bench.js"), "--systems", system]});
	}
	list.push({name: "protobuf go", cmd: path.join(root, "export/replication/protogo" + exe), args: ["--trace", trace]});
	list.push({name: "protobuf node", cmd: "node", args: [path.join(root, "tests/perf/replication/proto-js/proto_bench.js"), "--grpc-node", opt("grpc-node", ""), "--trace", trace]});
	return list;
}

function run() {
	const reps = Number(opt("reps", "3"));
	if (!fs.existsSync(trace)) {
		childProcess.execFileSync(path.join(root, "export/replication/native/ReplicationBench" + exe), ["--systems", "A", "--trace", trace], {stdio: "inherit"});
	}
	fs.mkdirSync(path.dirname(out), {recursive: true});
	const list = cells();
	for (let rep = 0; rep < reps; rep++) {
		for (let k = 0; k < list.length; k++) {
			const cell = list[(k + rep) % list.length];
			const text = childProcess.execFileSync(cell.cmd, cell.args, {encoding: "utf8", maxBuffer: 1 << 26});
			for (const line of text.split(/\r?\n/)) {
				if (line.startsWith("{")) {
					const row = JSON.parse(line);
					row.rep = rep;
					fs.appendFileSync(out, JSON.stringify(row) + "\n");
					console.log(cell.name + ": " + line);
				}
			}
		}
	}
	summary(out);
}

function median(values) {
	const sorted = values.slice().sort((a, b) => a - b);
	return sorted.length === 0 ? NaN : sorted[(sorted.length - 1) >> 1];
}

function summary(file) {
	const rows = fs.readFileSync(file, "utf8").split(/\r?\n/).filter((l) => l.startsWith("{")).map((l) => JSON.parse(l));
	const groups = new Map();
	for (const row of rows) {
		const key = row.system + " " + row.target;
		if (!groups.has(key)) groups.set(key, []);
		groups.get(key).push(row);
	}
	const fields = ["argumentBytes", "frameBytes", "sendNs", "readNs", "allocatedPerMessage", "inputBytes", "inputNs", "lastFourBytes", "lastFourNs",
		"sectionBytes", "streamBytes", "sectionWriteNs", "streamWriteNs", "sectionReadNs", "streamReadNs"];
	for (const [key, list] of groups) {
		const line = [key + " (" + list.length + ")"];
		for (const field of fields) {
			const values = list.map((r) => r[field]).filter((v) => typeof v === "number");
			if (values.length > 0) {
				const lo = Math.min(...values), hi = Math.max(...values);
				line.push(field + " " + median(values).toFixed(1) + (hi - lo > 0.05 ? " [" + lo.toFixed(1) + "-" + hi.toFixed(1) + "]" : ""));
			}
		}
		console.log(line.join(", "));
	}
}

if (opt("summary", null) != null) {
	summary(path.resolve(opt("summary", out)));
} else {
	run();
}
