// Stellar's hot messages as protobuf (google.golang.org/protobuf, as grpc-go
// marshals them), over the ticks ReplicationBench records (`--trace`): per
// observer per tick, the own ship's patch and the other ships' patches
// against the tick acknowledged two before, as proto3 optional fields, made
// and marshalled, then unmarshalled and applied into the client's frames.
// The same halves ReplicationBench times. Prints one JSON line.
//
//	go run . --trace ../../../../export/replication/trace.bin
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"time"

	"google.golang.org/protobuf/proto"
	pb "replicationbench/replicationpb"
)

const (
	window = 32
	lag    = 2
	warm   = 60
)

type ship struct {
	x, y, vx, vy, engineHeat, energy, reactorHeat, dragTimer, fireCooldown float64
	aimSteps, controls                                                      uint32
	engineLocked                                                            bool
	lastSeq                                                                 uint32
	inputSeq                                                                uint32
	inputControls                                                           uint32
	inputAim                                                                uint32
}

func readTrace(path string) ([][]ship, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// haxe.io.BytesOutput writes little-endian.
	le := binary.LittleEndian
	ticks := int(le.Uint32(data[0:]))
	ships := int(le.Uint32(data[4:]))
	at := 8
	out := make([][]ship, ticks)
	for t := 0; t < ticks; t++ {
		out[t] = make([]ship, ships)
		for i := 0; i < ships; i++ {
			s := &out[t][i]
			f := func() float64 {
				v := math.Float64frombits(le.Uint64(data[at:]))
				at += 8
				return v
			}
			s.x, s.y, s.vx, s.vy, s.engineHeat = f(), f(), f(), f(), f()
			s.energy, s.reactorHeat, s.dragTimer, s.fireCooldown = f(), f(), f(), f()
			s.aimSteps = uint32(le.Uint16(data[at:]))
			at += 2
			s.controls = uint32(data[at])
			s.engineLocked = data[at+1] != 0
			at += 2
			s.lastSeq = le.Uint32(data[at:])
			at += 4
			s.inputSeq = le.Uint32(data[at:])
			at += 4
			s.inputControls = uint32(data[at])
			at++
			s.inputAim = uint32(le.Uint16(data[at:]))
			at += 2
		}
	}
	return out, nil
}

func sameF64(a, b float64) bool { return a == b || (a != a && b != b) }
func sameF32(a, b float64) bool {
	x, y := float32(a), float32(b)
	return x == y || (x != x && y != y)
}

// The own ship's patch against `base` (nil: every field that is not zero).
func ownPatch(p *pb.OwnPatch, base, cur *ship) {
	var zero ship
	if base == nil {
		base = &zero
	}
	set := func(dst **float64, a, b float64) {
		if !sameF64(a, b) {
			v := b
			*dst = &v
		}
	}
	if base.lastSeq != cur.lastSeq {
		v := cur.lastSeq
		p.LastSeq = &v
	}
	set(&p.X, base.x, cur.x)
	set(&p.Y, base.y, cur.y)
	set(&p.Vx, base.vx, cur.vx)
	set(&p.Vy, base.vy, cur.vy)
	set(&p.EngineHeat, base.engineHeat, cur.engineHeat)
	set(&p.Energy, base.energy, cur.energy)
	set(&p.ReactorHeat, base.reactorHeat, cur.reactorHeat)
	set(&p.DragTimer, base.dragTimer, cur.dragTimer)
	set(&p.FireCooldown, base.fireCooldown, cur.fireCooldown)
	if base.aimSteps != cur.aimSteps {
		v := cur.aimSteps
		p.AimSteps = &v
	}
	if base.controls != cur.controls {
		v := cur.controls
		p.Controls = &v
	}
	if base.engineLocked != cur.engineLocked {
		v := cur.engineLocked
		p.EngineLocked = &v
	}
}

// Another ship's patch, at single precision; nil when nothing changed.
func shipPatch(base, cur *ship) *pb.ShipPatch {
	var zero ship
	if base == nil {
		base = &zero
	}
	var p *pb.ShipPatch
	get := func() *pb.ShipPatch {
		if p == nil {
			p = &pb.ShipPatch{}
		}
		return p
	}
	set := func(field func(*pb.ShipPatch) **float32, a, b float64) {
		if !sameF32(a, b) {
			v := float32(b)
			*field(get()) = &v
		}
	}
	set(func(s *pb.ShipPatch) **float32 { return &s.X }, base.x, cur.x)
	set(func(s *pb.ShipPatch) **float32 { return &s.Y }, base.y, cur.y)
	set(func(s *pb.ShipPatch) **float32 { return &s.Vx }, base.vx, cur.vx)
	set(func(s *pb.ShipPatch) **float32 { return &s.Vy }, base.vy, cur.vy)
	set(func(s *pb.ShipPatch) **float32 { return &s.EngineHeat }, base.engineHeat, cur.engineHeat)
	if base.aimSteps != cur.aimSteps {
		v := cur.aimSteps
		get().AimSteps = &v
	}
	if base.controls != cur.controls {
		v := cur.controls
		get().Controls = &v
	}
	if base.engineLocked != cur.engineLocked {
		v := cur.engineLocked
		get().EngineLocked = &v
	}
	return p
}

// A client's view of a ship, as it applies patches.
type view struct {
	x, y, vx, vy, engineHeat float32
	aimSteps, controls       uint32
	engineLocked             bool
}

type ownView struct {
	lastSeq                                                                 uint32
	x, y, vx, vy, engineHeat, energy, reactorHeat, dragTimer, fireCooldown float64
	aimSteps, controls                                                      uint32
	engineLocked                                                            bool
}

func applyOwn(into *ownView, from *ownView, p *pb.OwnPatch) {
	if from != nil && from != into {
		*into = *from
	} else if from == nil {
		*into = ownView{}
	}
	if p == nil {
		return
	}
	if p.LastSeq != nil {
		into.lastSeq = *p.LastSeq
	}
	if p.X != nil {
		into.x = *p.X
	}
	if p.Y != nil {
		into.y = *p.Y
	}
	if p.Vx != nil {
		into.vx = *p.Vx
	}
	if p.Vy != nil {
		into.vy = *p.Vy
	}
	if p.EngineHeat != nil {
		into.engineHeat = *p.EngineHeat
	}
	if p.Energy != nil {
		into.energy = *p.Energy
	}
	if p.ReactorHeat != nil {
		into.reactorHeat = *p.ReactorHeat
	}
	if p.DragTimer != nil {
		into.dragTimer = *p.DragTimer
	}
	if p.FireCooldown != nil {
		into.fireCooldown = *p.FireCooldown
	}
	if p.AimSteps != nil {
		into.aimSteps = *p.AimSteps
	}
	if p.Controls != nil {
		into.controls = *p.Controls
	}
	if p.EngineLocked != nil {
		into.engineLocked = *p.EngineLocked
	}
}

func applyShip(into *view, p *pb.ShipPatch) {
	if p.X != nil {
		into.x = *p.X
	}
	if p.Y != nil {
		into.y = *p.Y
	}
	if p.Vx != nil {
		into.vx = *p.Vx
	}
	if p.Vy != nil {
		into.vy = *p.Vy
	}
	if p.EngineHeat != nil {
		into.engineHeat = *p.EngineHeat
	}
	if p.AimSteps != nil {
		into.aimSteps = *p.AimSteps
	}
	if p.Controls != nil {
		into.controls = *p.Controls
	}
	if p.EngineLocked != nil {
		into.engineLocked = *p.EngineLocked
	}
}

// The design's shapes, as ReplicationBench --shapes makes them.
func shapes() {
	remoteBase := ship{x: 1520, y: -310, vx: 120, vy: -45, aimSteps: 16000, controls: 5, engineHeat: 180}
	remote := remoteBase
	remote.x, remote.y, remote.aimSteps = 1524, -311.5, 16384
	ownBase := remoteBase
	ownBase.lastSeq, ownBase.energy, ownBase.reactorHeat, ownBase.dragTimer, ownBase.fireCooldown = 990, 200, 50, 0.01, 0.05
	own := ownBase
	own.lastSeq = 1000
	own.x += 4.1
	own.y -= 1.3
	own.vx += 3.3
	own.vy -= 0.7
	own.engineHeat += 5
	own.energy -= 1.5
	own.reactorHeat += 0.25
	own.fireCooldown -= 0.033
	own.aimSteps = 16384
	tick := func(others int, o *ship) int {
		msg := &pb.MatchState{Tick: 36000, Base: 35998, Own: &pb.OwnPatch{}, Ships: map[int32]*pb.ShipPatch{}}
		ownPatch(msg.Own, &ownBase, o)
		for i := 0; i < others; i++ {
			msg.Ships[int32(2+i)] = shipPatch(&remoteBase, &remote)
		}
		b, _ := proto.Marshal(msg)
		return len(b)
	}
	none := tick(0, &ownBase)
	in, _ := proto.Marshal(&pb.Input{Seq: 1000, Controls: 5, AimSteps: 16384})
	four := &pb.Inputs{Ack: 36000, Newest: 1000}
	for k := 0; k < 4; k++ {
		four.Recent = append(four.Recent, &pb.Input{Seq: uint32(997 + k), Controls: 5, AimSteps: 16384})
	}
	fourBytes, _ := proto.Marshal(four)
	line, _ := json.Marshal(map[string]any{
		"system":            "protobuf",
		"remoteShipBytes":   tick(1, &ownBase) - none,
		"ownShipBytes":      tick(0, &own) - none,
		"tickArgumentBytes": tick(16, &own),
		"tickFrameBytes":    tick(16, &own) + 5 + 9,
		"inputBytes":        len(in),
		"lastFourBytes":     len(fourBytes),
	})
	fmt.Println(string(line))
}

type client struct {
	own    [window]ownView
	frames [window]map[int32]*view
}

func main() {
	tracePath := flag.String("trace", "export/replication/trace.bin", "the ticks ReplicationBench recorded")
	shapesOnly := flag.Bool("shapes", false, "print the bytes of the design's shapes and stop")
	flag.Parse()
	if *shapesOnly {
		shapes()
		return
	}
	ticks, err := readTrace(*tracePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	n := len(ticks[0])
	clients := make([]*client, n)
	for o := range clients {
		c := &client{}
		for i := range c.frames {
			c.frames[i] = map[int32]*view{}
		}
		clients[o] = c
	}
	buffers := make([][]byte, n)
	read := &pb.MatchState{}
	var sendTime, readTime time.Duration
	var bytes, messages int
	var before, after runtime.MemStats
	// The ticks ReplicationBench measures: past its warm ones, up to the
	// last 60 it records for the inputs' sake.
	for t := 0; t < len(ticks)-60; t++ {
		if t == warm {
			runtime.GC()
			runtime.ReadMemStats(&before)
		}
		measured := t >= warm
		a := time.Now()
		for o := 0; o < n; o++ {
			var baseOwn *ship
			base := t - lag
			if base >= 0 {
				baseOwn = &ticks[base][o]
			}
			msg := &pb.MatchState{Tick: uint32(t), Base: uint32(base & 0x7fffffff), Own: &pb.OwnPatch{}, Ships: map[int32]*pb.ShipPatch{}}
			ownPatch(msg.Own, baseOwn, &ticks[t][o])
			for i := 0; i < n; i++ {
				if i == o {
					continue
				}
				var b *ship
				if base >= 0 {
					b = &ticks[base][i]
				}
				if p := shipPatch(b, &ticks[t][i]); p != nil {
					msg.Ships[int32(i+1)] = p
				}
			}
			buffers[o], _ = proto.MarshalOptions{}.MarshalAppend(buffers[o][:0], msg)
			if measured {
				bytes += len(buffers[o])
				messages++
			}
		}
		b := time.Now()
		for o := 0; o < n; o++ {
			proto.Reset(read)
			if err := proto.Unmarshal(buffers[o], read); err != nil {
				panic(err)
			}
			c := clients[o]
			into := c.frames[read.Tick%window]
			var from map[int32]*view
			full := t-lag < 0
			if !full {
				from = c.frames[read.Base%window]
			}
			var fromOwn *ownView
			if !full {
				fromOwn = &c.own[read.Base%window]
			}
			applyOwn(&c.own[read.Tick%window], fromOwn, read.Own)
			for i := 0; i < n; i++ {
				key := int32(i + 1)
				if i == o {
					continue
				}
				v := into[key]
				if v == nil {
					v = &view{}
					into[key] = v
				}
				if from != nil {
					if w := from[key]; w != nil && w != v {
						*v = *w
					}
				} else {
					*v = view{}
				}
				if p := read.Ships[key]; p != nil {
					applyShip(v, p)
				}
			}
		}
		c := time.Now()
		if measured {
			sendTime += b.Sub(a)
			readTime += c.Sub(b)
		}
	}
	runtime.ReadMemStats(&after)
	allocated := float64(after.TotalAlloc-before.TotalAlloc) / float64(messages)

	// Inputs: one a tick, and the last four.
	var inputBytes, fourBytes, inputCount int
	var inputTime, fourTime time.Duration
	in := &pb.Input{}
	four := &pb.Inputs{Recent: []*pb.Input{{}, {}, {}, {}}}
	readIn := &pb.Input{}
	readFour := &pb.Inputs{}
	var buf []byte
	for round := 0; round < 2; round++ {
		for t := 4; t < len(ticks); t++ {
			for o := 0; o < n; o++ {
				s := &ticks[t][o]
				a := time.Now()
				in.Seq, in.Controls, in.AimSteps = s.inputSeq, s.inputControls, s.inputAim
				buf, _ = proto.MarshalOptions{}.MarshalAppend(buf[:0], in)
				size := len(buf)
				proto.Reset(readIn)
				if err := proto.Unmarshal(buf, readIn); err != nil {
					panic(err)
				}
				b := time.Now()
				four.Ack, four.Newest = uint32(t-lag), s.inputSeq
				for k := 0; k < 4; k++ {
					e := &ticks[t-3+k][o]
					four.Recent[k].Seq, four.Recent[k].Controls, four.Recent[k].AimSteps = e.inputSeq, e.inputControls, e.inputAim
				}
				buf, _ = proto.MarshalOptions{}.MarshalAppend(buf[:0], four)
				fourSize := len(buf)
				proto.Reset(readFour)
				if err := proto.Unmarshal(buf, readFour); err != nil {
					panic(err)
				}
				c := time.Now()
				if round == 1 {
					inputBytes += size
					fourBytes += fourSize
					inputTime += b.Sub(a)
					fourTime += c.Sub(b)
					inputCount++
				}
			}
		}
	}

	result := map[string]any{
		"system":              "protobuf",
		"target":              "go",
		"messages":            messages,
		"argumentBytes":       float64(bytes) / float64(messages),
		"frameBytes":          float64(bytes)/float64(messages) + 5 + 9,
		"sendNs":              float64(sendTime.Nanoseconds()) / float64(messages),
		"readNs":              float64(readTime.Nanoseconds()) / float64(messages),
		"allocatedPerMessage": allocated,
		"inputBytes":          float64(inputBytes) / float64(inputCount),
		"inputNs":             float64(inputTime.Nanoseconds()) / float64(inputCount),
		"lastFourBytes":       float64(fourBytes) / float64(inputCount),
		"lastFourNs":          float64(fourTime.Nanoseconds()) / float64(inputCount),
	}
	line, _ := json.Marshal(result)
	fmt.Println(string(line))
}
