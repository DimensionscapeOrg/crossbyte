// Stellar's hot messages as protobuf through protobufjs (what grpc-js
// encodes with, by @grpc/proto-loader), over the ticks ReplicationBench
// records (`--trace`): the same patches and halves as proto-go/main.go.
// Prints one JSON line.
//
//   node tests/perf/replication/proto-js/proto_bench.js --grpc-node <dir holding node_modules> --trace export/replication/trace.bin
"use strict";
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const opt = (name, fallback) => {
	const i = args.indexOf("--" + name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const grpcNode = opt("grpc-node", null);
const protobuf = require(grpcNode ? path.join(grpcNode, "node_modules", "protobufjs") : "protobufjs");
const root = protobuf.loadSync(path.join(__dirname, "..", "replication.proto"));
const MatchState = root.lookupType("replication.MatchState");
const Input = root.lookupType("replication.Input");
const Inputs = root.lookupType("replication.Inputs");

const WINDOW = 32;
const LAG = 2;
const WARM = 60;

function readTrace(file) {
	const data = fs.readFileSync(file);
	const ticks = data.readUInt32LE(0);
	const ships = data.readUInt32LE(4);
	let at = 8;
	const out = [];
	for (let t = 0; t < ticks; t++) {
		const row = [];
		for (let i = 0; i < ships; i++) {
			const f = () => {
				const v = data.readDoubleLE(at);
				at += 8;
				return v;
			};
			const s = {x: f(), y: f(), vx: f(), vy: f(), engineHeat: f(), energy: f(), reactorHeat: f(), dragTimer: f(), fireCooldown: f()};
			s.aimSteps = data.readUInt16LE(at);
			s.controls = data[at + 2];
			s.engineLocked = data[at + 3] !== 0;
			at += 4;
			s.lastSeq = data.readUInt32LE(at);
			at += 4;
			s.inputSeq = data.readUInt32LE(at);
			s.inputControls = data[at + 4];
			s.inputAim = data.readUInt16LE(at + 5);
			at += 7;
			row.push(s);
		}
		out.push(row);
	}
	return out;
}

const ZERO = {x: 0, y: 0, vx: 0, vy: 0, engineHeat: 0, energy: 0, reactorHeat: 0, dragTimer: 0, fireCooldown: 0, aimSteps: 0, controls: 0, engineLocked: false, lastSeq: 0};
const sameF64 = (a, b) => a === b || (a !== a && b !== b);
const f32 = Math.fround;
const sameF32 = (a, b) => {
	const x = f32(a), y = f32(b);
	return x === y || (x !== x && y !== y);
};

function ownPatch(base, cur) {
	base = base || ZERO;
	const p = {};
	if (base.lastSeq !== cur.lastSeq) p.lastSeq = cur.lastSeq;
	for (const k of ["x", "y", "vx", "vy", "engineHeat", "energy", "reactorHeat", "dragTimer", "fireCooldown"]) {
		if (!sameF64(base[k], cur[k])) p[k] = cur[k];
	}
	if (base.aimSteps !== cur.aimSteps) p.aimSteps = cur.aimSteps;
	if (base.controls !== cur.controls) p.controls = cur.controls;
	if (base.engineLocked !== cur.engineLocked) p.engineLocked = cur.engineLocked;
	return p;
}

function shipPatch(base, cur) {
	base = base || ZERO;
	let p = null;
	for (const k of ["x", "y", "vx", "vy", "engineHeat"]) {
		if (!sameF32(base[k], cur[k])) (p = p || {})[k] = cur[k];
	}
	if (base.aimSteps !== cur.aimSteps) (p = p || {}).aimSteps = cur.aimSteps;
	if (base.controls !== cur.controls) (p = p || {}).controls = cur.controls;
	if (base.engineLocked !== cur.engineLocked) (p = p || {}).engineLocked = cur.engineLocked;
	return p;
}

const has = (m, k) => m[k] != null && (typeof m.hasOwnProperty !== "function" || Object.prototype.hasOwnProperty.call(m, k));

function main() {
	const ticks = readTrace(opt("trace", "export/replication/trace.bin"));
	const n = ticks[0].length;
	const clients = [];
	for (let o = 0; o < n; o++) {
		clients.push({own: Array.from({length: WINDOW}, () => ({})), frames: Array.from({length: WINDOW}, () => new Map())});
	}
	const buffers = new Array(n);
	let sendTime = 0, readTime = 0, bytes = 0, messages = 0;
	const now = () => Number(process.hrtime.bigint());
	for (let t = 0; t < ticks.length - 60; t++) {
		const measured = t >= WARM;
		const a = now();
		for (let o = 0; o < n; o++) {
			const base = t - LAG;
			const msg = {tick: t, base: base >= 0 ? base : 0, own: ownPatch(base >= 0 ? ticks[base][o] : null, ticks[t][o]), ships: {}};
			for (let i = 0; i < n; i++) {
				if (i === o) continue;
				const p = shipPatch(base >= 0 ? ticks[base][i] : null, ticks[t][i]);
				if (p) msg.ships[i + 1] = p;
			}
			buffers[o] = MatchState.encode(MatchState.fromObject(msg)).finish();
			if (measured) {
				bytes += buffers[o].length;
				messages++;
			}
		}
		const b = now();
		for (let o = 0; o < n; o++) {
			const read = MatchState.decode(buffers[o]);
			const c = clients[o];
			const full = t - LAG < 0;
			const into = c.frames[read.tick % WINDOW];
			const from = full ? null : c.frames[read.base % WINDOW];
			const ownInto = c.own[read.tick % WINDOW];
			const ownFrom = full ? ZERO : c.own[read.base % WINDOW];
			for (const k of ["lastSeq", "x", "y", "vx", "vy", "engineHeat", "energy", "reactorHeat", "dragTimer", "fireCooldown", "aimSteps", "controls", "engineLocked"]) {
				ownInto[k] = read.own && has(read.own, k) ? read.own[k] : ownFrom[k];
			}
			for (let i = 0; i < n; i++) {
				if (i === o) continue;
				const key = i + 1;
				let v = into.get(key);
				if (!v) {
					v = {};
					into.set(key, v);
				}
				const w = from ? from.get(key) : ZERO;
				const p = read.ships[key];
				for (const k of ["x", "y", "vx", "vy", "engineHeat", "aimSteps", "controls", "engineLocked"]) {
					v[k] = p && has(p, k) ? p[k] : (w ? w[k] : 0);
				}
			}
		}
		const c = now();
		if (measured) {
			sendTime += b - a;
			readTime += c - b;
		}
	}

	let inputBytes = 0, fourBytes = 0, inputCount = 0, inputTime = 0, fourTime = 0;
	for (let round = 0; round < 2; round++) {
		for (let t = 4; t < ticks.length; t++) {
			for (let o = 0; o < n; o++) {
				const s = ticks[t][o];
				const a = now();
				const one = Input.encode({seq: s.inputSeq, controls: s.inputControls, aimSteps: s.inputAim}).finish();
				Input.decode(one);
				const b = now();
				const recent = [];
				for (let k = 0; k < 4; k++) {
					const e = ticks[t - 3 + k][o];
					recent.push({seq: e.inputSeq, controls: e.inputControls, aimSteps: e.inputAim});
				}
				const four = Inputs.encode({ack: t - LAG, newest: s.inputSeq, recent}).finish();
				Inputs.decode(four);
				const c = now();
				if (round === 1) {
					inputBytes += one.length;
					fourBytes += four.length;
					inputTime += b - a;
					fourTime += c - b;
					inputCount++;
				}
			}
		}
	}

	console.log(JSON.stringify({
		system: "protobuf",
		target: "node",
		messages,
		argumentBytes: bytes / messages,
		frameBytes: bytes / messages + 5 + 9,
		sendNs: sendTime / messages,
		readNs: readTime / messages,
		allocatedPerMessage: -1,
		inputBytes: inputBytes / inputCount,
		inputNs: inputTime / inputCount,
		lastFourBytes: fourBytes / inputCount,
		lastFourNs: fourTime / inputCount
	}));
}

main();
