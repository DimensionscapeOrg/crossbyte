// gRPC unary calls with @grpc/grpc-js, in the shape of RpcCallBench:
//
//   node grpc_bench.js <dir holding node_modules> server --port 5200
//   node grpc_bench.js <dir holding node_modules> client --port 5200 --kind num|blob|intmap|strmap --entries 8
//                      --connections 1 --inflight 1 --warmup 2 --seconds 5
//
// The modules are @grpc/grpc-js and @grpc/proto-loader, installed wherever
// the first argument says. The client keeps `inflight` calls waiting on each
// connection (each a channel of its own, not shared), makes the next as each
// is answered, and times each round trip. It prints WINDOW_START and
// WINDOW_END around the measured window, then one RESULT line of JSON.
"use strict";
const path = require("path");
const modules = path.resolve(process.argv[2], "node_modules");
const grpc = require(path.join(modules, "@grpc/grpc-js"));
const protoLoader = require(path.join(modules, "@grpc/proto-loader"));

const args = process.argv.slice(3);
const role = args[0];
const opt = (name, fallback) => {
	const i = args.indexOf("--" + name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};

const definition = protoLoader.loadSync(path.join(__dirname, "..", "bench.proto"), {keepCase: true});
const bench = grpc.loadPackageDefinition(definition).bench;
const port = Number(opt("port", "5200"));

// Buckets two percent wide on a log scale of microseconds, as LoadStats' Histogram.
class Histogram {
	constructor() {
		this.counts = new Array(1024).fill(0);
		this.count = 0;
		this.max = 0;
	}
	add(ms) {
		const us = ms * 1000;
		let bucket = us <= 1 ? 0 : Math.floor(Math.log(us) / Math.log(1.02));
		if (bucket >= 1024) bucket = 1023;
		this.counts[bucket]++;
		this.count++;
		if (ms > this.max) this.max = ms;
	}
	percentile(p) {
		if (this.count === 0) return 0;
		const wanted = this.count * p;
		let seen = 0;
		for (let b = 0; b < 1024; b++) {
			seen += this.counts[b];
			if (seen >= wanted && seen > 0) {
				const ms = Math.pow(1.02, b + 0.5) / 1000;
				return ms > this.max ? this.max : ms;
			}
		}
		return this.max;
	}
}

if (role === "server") {
	const server = new grpc.Server();
	server.addService(bench.Bench.service, {
		Num: (call, callback) => callback(null, {v: call.request.v}),
		Blob: (call, callback) => callback(null, {data: call.request.data}),
		// The map that arrived, decoded and encoded again, as the other benches answer.
		IntMap: (call, callback) => callback(null, {m: call.request.m}),
		StrMap: (call, callback) => callback(null, {m: call.request.m})
	});
	server.bindAsync("127.0.0.1:" + port, grpc.ServerCredentials.createInsecure(), (error) => {
		if (error) {
			console.log("FAILED " + error.message);
			process.exit(3);
		}
		console.log("READY");
	});
} else {
	const kind = opt("kind", "num");
	const entries = Number(opt("entries", "8"));
	const connections = Number(opt("connections", "1"));
	const inflight = Number(opt("inflight", "1"));
	const warmup = Number(opt("warmup", "2"));
	const seconds = Number(opt("seconds", "5"));
	const target = opt("target", "127.0.0.1:" + port);
	const blob = Buffer.alloc(4096);
	for (let i = 0; i < 4096; i++) blob[i] = (i * 31 + 7) & 0xff;
	// The maps the map calls send, made once: keys "key0" up, values their
	// number, or "value" and their number.
	const intMap = {};
	const strMap = {};
	for (let i = 0; i < entries; i++) {
		intMap["key" + i] = i;
		strMap["key" + i] = "value" + i;
	}

	let measuring = false;
	let answers = 0;
	let total = 0;
	let failures = 0;
	let rtt = new Histogram();

	const clients = [];
	for (let i = 0; i < connections; i++) {
		// A subchannel pool of its own, so each is a connection of its own.
		clients.push(new bench.Bench(target, grpc.credentials.createInsecure(), {"grpc.use_local_subchannel_pool": 1}));
	}

	const call = (client) => {
		const sent = process.hrtime.bigint();
		const done = (error) => {
			if (error) {
				failures++;
				return;
			}
			total++;
			if (measuring) {
				answers++;
				rtt.add(Number(process.hrtime.bigint() - sent) / 1e6);
			}
			call(client);
		};
		if (kind === "blob") {
			client.Blob({data: blob}, done);
		} else if (kind === "intmap") {
			client.IntMap({m: intMap}, done);
		} else if (kind === "strmap") {
			client.StrMap({m: strMap}, done);
		} else {
			client.Num({v: total & 0xffff}, done);
		}
	};

	let ready = 0;
	for (const client of clients) {
		client.waitForReady(Date.now() + 20000, (error) => {
			if (error) {
				console.log("FAILED " + error.message);
				process.exit(3);
			}
			if (++ready === clients.length) {
				for (const c of clients) {
					for (let i = 0; i < inflight; i++) call(c);
				}
				setTimeout(() => {
					console.log("WINDOW_START");
					measuring = true;
					answers = 0;
					rtt = new Histogram();
					const started = process.hrtime.bigint();
					setTimeout(() => {
						measuring = false;
						const elapsed = Number(process.hrtime.bigint() - started) / 1e9;
						console.log("WINDOW_END");
						console.log("RESULT " + JSON.stringify({
							system: "grpc-js", kind, entries, connections, inflight,
							callsPerSec: Math.round(answers / elapsed),
							rttP50us: Math.round(rtt.percentile(0.5) * 1000),
							rttP99us: Math.round(rtt.percentile(0.99) * 1000),
							failures, totalAnswers: total
						}));
						process.exit(0);
					}, seconds * 1000);
				}, warmup * 1000);
			}
		});
	}
}
