// CrossByte's RPC beside gRPC: unary calls, a small one (an int each way) and
// one of 4 KB each way, with one connection and one call in flight, and with
// 8 connections and 32 in flight on each. Every cell runs once a rep, the
// order turned by one system each rep. docs/performance.md says how to build
// what it runs.
//
//   node tests/perf/rpc/run.js --grpc-node <dir holding node_modules> [--reps 3]
//        [--systems crossbyte,grpc-go,grpc-go-1,grpc-js] [--warmup 2] [--seconds 5]
//        [--out export/rpc-bench/results.jsonl]
//   node tests/perf/rpc/run.js --summary export/rpc-bench/results.jsonl
//
// A cell: the server; the client straight to it, while the processor time of
// both processes is read from outside (grpcbench cpu) at the start and the
// end of the client's measured window; then the client again through a
// proxy that counts the bytes each way, for the bytes on the wire a call.
// Systems: crossbyte (native, TCP), crossbyte-ws (native, WebSocket),
// crossbyte-node (Node, TCP), grpc-go, grpc-go-1 (grpc-go with GOMAXPROCS=1
// on both ends), grpc-js. Run from the repository root.
"use strict";
const childProcess = require("child_process");
const fs = require("fs");
const net = require("net");
const path = require("path");
const readline = require("readline");

const args = process.argv.slice(2);
const opt = (name, fallback) => {
	const i = args.indexOf("--" + name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};

const root = process.cwd();
const exe = process.platform === "win32" ? ".exe" : "";
const out = path.resolve(opt("out", "export/rpc-bench/results.jsonl"));
const grpcNode = opt("grpc-node", null);
const reps = Number(opt("reps", "3"));
const warmup = Number(opt("warmup", "2"));
const seconds = Number(opt("seconds", "5"));
const systems = opt("systems", "crossbyte,grpc-go,grpc-go-1,grpc-js").split(",");
const grpcbench = path.join(root, "export/rpc-bench/grpcbench" + exe);
const crossbyteNative = path.join(root, "export/rpc-bench/native/RpcCallBench" + exe);
const crossbyteNode = path.join(root, "export/rpc-bench/node/bench.js");
const grpcJs = path.join(root, "tests/perf/rpc/grpc-js/grpc_bench.js");

const SHAPES = [[1, 1], [8, 32]];
const KINDS = ["small", "4KB"];

// What each system runs, as [command, args, env] for a server and a client.
function commands(system, kind, port, connections, inflight, warm, secs) {
	const node = process.execPath;
	const crossbyteKind = kind === "small" ? "int" : "blob";
	const grpcKind = kind === "small" ? "num" : "blob";
	const window = ["--warmup", String(warm), "--seconds", String(secs)];
	const shape = ["--connections", String(connections), "--inflight", String(inflight)];
	switch (system) {
		case "crossbyte":
		case "crossbyte-ws": {
			const transport = system === "crossbyte" ? "tcp" : "ws";
			return {
				server: [crossbyteNative, ["server", "--transport", transport, "--port", String(port)], {}],
				client: [crossbyteNative, ["client", "--transport", transport, "--kind", crossbyteKind, "--port", String(port), ...shape, ...window], {}]
			};
		}
		case "crossbyte-node":
			return {
				server: [node, [crossbyteNode, "server", "--transport", "tcp", "--port", String(port)], {}],
				client: [node, [crossbyteNode, "client", "--transport", "tcp", "--kind", crossbyteKind, "--port", String(port), ...shape, ...window], {}]
			};
		case "grpc-go":
		case "grpc-go-1": {
			const env = system === "grpc-go-1" ? {GOMAXPROCS: "1"} : {};
			return {
				server: [grpcbench, ["server", "--port", String(port)], env],
				client: [grpcbench, ["client", "--kind", grpcKind, "--port", String(port), ...shape, ...window], env]
			};
		}
		case "grpc-js":
			if (grpcNode == null) {
				throw new Error("grpc-js needs --grpc-node <dir holding node_modules>");
			}
			return {
				server: [node, [grpcJs, grpcNode, "server", "--port", String(port)], {}],
				client: [node, [grpcJs, grpcNode, "client", "--kind", grpcKind, "--port", String(port), ...shape, ...window], {}]
			};
	}
	throw new Error("unknown system " + system);
}

function start(command) {
	const [file, argv, env] = command;
	const child = childProcess.spawn(file, argv, {env: Object.assign({}, process.env, env), stdio: ["ignore", "pipe", "pipe"]});
	child.lines = readline.createInterface({input: child.stdout});
	child.stderr.on("data", () => {});
	return child;
}

// Resolves with the first line matching `pattern`, or rejects after `ms`.
function waitFor(child, pattern, ms) {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("no " + pattern + " in " + ms + " ms")), ms);
		const onLine = (line) => {
			if (pattern.test(line)) {
				clearTimeout(timer);
				child.lines.off("line", onLine);
				resolve(line);
			}
		};
		child.lines.on("line", onLine);
		child.once("exit", (code) => {
			clearTimeout(timer);
			reject(new Error("exited " + code + " before " + pattern));
		});
	});
}

// The processor-time sampler: one process for the whole run, asked a line at a time.
class Sampler {
	constructor() {
		this.process = childProcess.spawn(grpcbench, ["cpu"], {stdio: ["pipe", "pipe", "ignore"]});
		this.lines = readline.createInterface({input: this.process.stdout});
		this.waiting = [];
		this.lines.on("line", (line) => {
			if (line === "READY") {
				return;
			}
			const next = this.waiting.shift();
			if (next) {
				next(line.split(" ").map(Number));
			}
		});
	}
	sample(pids) {
		return new Promise((resolve) => {
			this.waiting.push(resolve);
			this.process.stdin.write(pids.join(" ") + "\n");
		});
	}
	close() {
		this.process.stdin.end();
	}
}

// A port nothing holds, as the system hands one out. A port counted up from a
// fixed number can land in a block Windows reserves (Hyper-V, WinNAT, the
// WSD service's 5357), where listening fails with EACCES.
function freePort() {
	return new Promise((resolve, reject) => {
		const probe = net.createServer();
		probe.once("error", reject);
		probe.listen(0, "127.0.0.1", () => {
			const port = probe.address().port;
			probe.close(() => resolve(port));
		});
	});
}

// A TCP proxy counting payload bytes each way, without IP or TCP headers, on a
// port the system hands out.
function countingProxy(targetPort) {
	const counts = {up: 0, down: 0, connections: 0};
	const server = net.createServer((client) => {
		counts.connections++;
		client.setNoDelay(true);
		const upstream = net.connect(targetPort, "127.0.0.1");
		upstream.setNoDelay(true);
		const pipe = (from, to, field) => {
			from.on("data", (chunk) => {
				counts[field] += chunk.length;
				if (!to.write(chunk)) {
					from.pause();
					to.once("drain", () => from.resume());
				}
			});
		};
		pipe(client, upstream, "up");
		pipe(upstream, client, "down");
		const end = () => {
			client.destroy();
			upstream.destroy();
		};
		for (const s of [client, upstream]) {
			s.on("error", end);
			s.on("close", end);
		}
	});
	return new Promise((resolve, reject) => {
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => resolve({server, counts, port: server.address().port}));
	});
}

function exited(child, ms) {
	return new Promise((resolve) => {
		if (child.exitCode !== null) {
			return resolve();
		}
		const timer = setTimeout(() => {
			child.kill();
			resolve();
		}, ms);
		child.once("exit", () => {
			clearTimeout(timer);
			resolve();
		});
	});
}

async function cell(sampler, system, kind, connections, inflight, rep) {
	const port = await freePort();
	const run = commands(system, kind, port, connections, inflight, warmup, seconds);
	const server = start(run.server);
	await waitFor(server, /^READY/, 15000);
	const record = {system, kind, connections, inflight, rep};
	try {
		// Straight to the server: rate, latency and processor time.
		const client = start(run.client);
		const result = waitFor(client, /^(RESULT|FAILED)/, (warmup + seconds) * 1000 + 40000);
		result.catch(() => {}); // read below; a client failing earlier is reported by the wait that sees it
		await waitFor(client, /^WINDOW_START/, warmup * 1000 + 30000);
		const before = await sampler.sample([server.pid, client.pid]);
		const startedAt = process.hrtime.bigint();
		await waitFor(client, /^WINDOW_END/, seconds * 1000 + 10000);
		const after = await sampler.sample([server.pid, client.pid]);
		const elapsed = Number(process.hrtime.bigint() - startedAt) / 1e9;
		const line = await result;
		await exited(client, 10000);
		if (!line.startsWith("RESULT ")) {
			record.failed = line;
			return record;
		}
		Object.assign(record, JSON.parse(line.slice(7)));
		record.system = system;
		record.kind = kind;
		const answers = record.callsPerSec * elapsed;
		record.serverCpuUsPerCall = round((after[0] - before[0]) / answers * 1e6, 2);
		record.clientCpuUsPerCall = round((after[1] - before[1]) / answers * 1e6, 2);
		record.serverCpuCores = round((after[0] - before[0]) / elapsed, 3);
		record.clientCpuCores = round((after[1] - before[1]) / elapsed, 3);

		// Through the counting proxy: bytes on the wire a call, over a shorter run.
		const proxy = await countingProxy(port);
		const counted = commands(system, kind, proxy.port, connections, inflight, 1, 2);
		const viaProxy = start(counted.client);
		const proxied = await waitFor(viaProxy, /^(RESULT|FAILED)/, 60000);
		await exited(viaProxy, 10000);
		await new Promise((resolve) => setTimeout(resolve, 300));
		proxy.server.close();
		if (proxied.startsWith("RESULT ")) {
			const total = JSON.parse(proxied.slice(7)).totalAnswers;
			record.wireUpPerCall = round(proxy.counts.up / total, 1);
			record.wireDownPerCall = round(proxy.counts.down / total, 1);
			record.wirePerCall = round((proxy.counts.up + proxy.counts.down) / total, 1);
		}
	} catch (error) {
		record.failed = String(error.message || error);
	} finally {
		server.kill();
		await exited(server, 5000);
	}
	return record;
}

function round(value, places) {
	const f = Math.pow(10, places);
	return Math.round(value * f) / f;
}

async function main() {
	fs.mkdirSync(path.dirname(out), {recursive: true});
	const sampler = new Sampler();
	for (let rep = 1; rep <= reps; rep++) {
		const order = systems.slice((rep - 1) % systems.length).concat(systems.slice(0, (rep - 1) % systems.length));
		for (const system of order) {
			for (const kind of KINDS) {
				for (const [connections, inflight] of SHAPES) {
					const record = await cell(sampler, system, kind, connections, inflight, rep);
					fs.appendFileSync(out, JSON.stringify(record) + "\n");
					console.log(describe(record));
				}
			}
		}
	}
	sampler.close();
	summary(out);
}

function describe(r) {
	if (r.failed) {
		return `${r.system} ${r.kind} ${r.connections}x${r.inflight} rep ${r.rep}: FAILED ${r.failed}`;
	}
	return `${r.system} ${r.kind} ${r.connections}x${r.inflight} rep ${r.rep}: ${r.callsPerSec}/s p50 ${r.rttP50us} us p99 ${r.rttP99us} us, `
		+ `cpu server ${r.serverCpuUsPerCall} client ${r.clientCpuUsPerCall} us/call, wire ${r.wirePerCall} B (${r.wireUpPerCall} + ${r.wireDownPerCall})`;
}

const NAMES = {
	"crossbyte": "CrossByte, native, TCP",
	"crossbyte-ws": "CrossByte, native, WebSocket",
	"crossbyte-node": "CrossByte, Node, TCP",
	"grpc-go": "grpc-go",
	"grpc-go-1": "grpc-go, GOMAXPROCS=1",
	"grpc-js": "grpc-js, Node"
};

// Medians, with the range in brackets, per cell, as a markdown table.
function summary(file) {
	const cells = new Map();
	for (const line of fs.readFileSync(file, "utf8").split("\n")) {
		if (!line.trim()) continue;
		const r = JSON.parse(line);
		if (r.failed) continue;
		const kind = r.kind === "blob" || r.kind === "4KB" ? "4 KB" : "small";
		const key = [r.system, kind, r.connections, r.inflight].join("|");
		if (!cells.has(key)) cells.set(key, []);
		cells.get(key).push(r);
	}
	const span = (values, places) => {
		const v = values.filter((x) => typeof x === "number" && !isNaN(x)).sort((a, b) => a - b);
		if (v.length === 0) return "-";
		const f = (x) => x.toLocaleString("en-US", {maximumFractionDigits: places});
		const mid = f(v[Math.floor(v.length / 2)]);
		return v[0] === v[v.length - 1] ? mid : `${mid} (${f(v[0])}-${f(v[v.length - 1])})`;
	};
	const median = (values) => {
		const v = values.slice().sort((a, b) => a - b);
		return v[Math.floor(v.length / 2)];
	};
	console.log("| system | call | connections x in flight | calls/s | p50 us | p99 us | server CPU us/call | client CPU us/call | wire B/call (out + back) |");
	console.log("| --- | --- | --- | --- | --- | --- | --- | --- | --- |");
	for (const [key, rs] of cells) {
		const [system, kind, connections, inflight] = key.split("|");
		const wire = median(rs.map((r) => r.wirePerCall));
		const up = median(rs.map((r) => r.wireUpPerCall));
		const down = median(rs.map((r) => r.wireDownPerCall));
		console.log(`| ${NAMES[system] || system} | ${kind} | ${connections} x ${inflight} | ${span(rs.map((r) => r.callsPerSec), 0)} | `
			+ `${span(rs.map((r) => r.rttP50us), 0)} | ${span(rs.map((r) => r.rttP99us), 0)} | ${span(rs.map((r) => r.serverCpuUsPerCall), 2)} | `
			+ `${span(rs.map((r) => r.clientCpuUsPerCall), 2)} | ${Math.round(wire)} (${Math.round(up)} + ${Math.round(down)}) |`);
	}
}

if (opt("summary", null) != null) {
	summary(path.resolve(opt("summary", null)));
} else {
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});
}
