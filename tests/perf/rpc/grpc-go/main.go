// Command grpcbench makes gRPC unary calls with grpc-go in the shape of
// RpcCallBench, and samples other processes' processor time for run.js.
//
//	grpcbench server --port 5200
//	grpcbench client --port 5200 --kind num|blob --connections 1 --inflight 1 --warmup 2 --seconds 5
//	grpcbench cpu
//
// The client keeps `inflight` calls waiting on each connection (each its own
// ClientConn, so its own HTTP/2 connection), makes the next as each is
// answered, and times each round trip. It prints WINDOW_START and WINDOW_END
// around the measured window, then one RESULT line of JSON.
//
// `cpu` reads lines of process ids on standard input and answers each with a
// line of the processor time, user and kernel, each has used so far, in
// seconds (-1 for one it cannot read).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"

	"rpcbench/benchpb"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: grpcbench server|client|cpu ...")
		os.Exit(2)
	}
	opts := parseOpts(os.Args[2:])
	switch os.Args[1] {
	case "server":
		serve(opts)
	case "client":
		runClient(opts)
	case "cpu":
		sampleCPU()
	default:
		fmt.Println("usage: grpcbench server|client|cpu ...")
		os.Exit(2)
	}
}

type opts map[string]string

func parseOpts(raw []string) opts {
	o := opts{}
	for i := 0; i < len(raw); i++ {
		if strings.HasPrefix(raw[i], "--") {
			name := raw[i][2:]
			if i+1 < len(raw) && !strings.HasPrefix(raw[i+1], "--") {
				o[name] = raw[i+1]
				i++
			} else {
				o[name] = "true"
			}
		}
	}
	return o
}

func (o opts) str(name, fallback string) string {
	if v, ok := o[name]; ok {
		return v
	}
	return fallback
}

func (o opts) num(name string, fallback float64) float64 {
	if v, err := strconv.ParseFloat(o.str(name, ""), 64); err == nil {
		return v
	}
	return fallback
}

type benchServer struct {
	benchpb.UnimplementedBenchServer
}

func (benchServer) Num(_ context.Context, in *benchpb.NumMessage) (*benchpb.NumMessage, error) {
	return &benchpb.NumMessage{V: in.V}, nil
}

func (benchServer) Blob(_ context.Context, in *benchpb.BlobMessage) (*benchpb.BlobMessage, error) {
	return &benchpb.BlobMessage{Data: in.Data}, nil
}

func serve(o opts) {
	listener, err := net.Listen("tcp", "127.0.0.1:"+o.str("port", "5200"))
	if err != nil {
		fmt.Println("FAILED " + err.Error())
		os.Exit(3)
	}
	server := grpc.NewServer()
	benchpb.RegisterBenchServer(server, benchServer{})
	fmt.Println("READY")
	if err := server.Serve(listener); err != nil {
		fmt.Println("FAILED " + err.Error())
		os.Exit(3)
	}
}

// Buckets two percent wide on a log scale of microseconds, as LoadStats'
// Histogram reads them.
type histogram struct {
	counts [1024]int64
	count  int64
	max    float64 // ms
}

func (h *histogram) add(ms float64) {
	us := ms * 1000
	bucket := 0
	if us > 1 {
		bucket = int(math.Log(us) / math.Log(1.02))
	}
	if bucket >= 1024 {
		bucket = 1023
	}
	h.counts[bucket]++
	h.count++
	if ms > h.max {
		h.max = ms
	}
}

func (h *histogram) merge(other *histogram) {
	for b := range h.counts {
		h.counts[b] += other.counts[b]
	}
	h.count += other.count
	if other.max > h.max {
		h.max = other.max
	}
}

func (h *histogram) percentile(p float64) float64 {
	if h.count == 0 {
		return 0
	}
	wanted := float64(h.count) * p
	var seen int64
	for b := 0; b < 1024; b++ {
		seen += h.counts[b]
		if float64(seen) >= wanted && seen > 0 {
			ms := math.Pow(1.02, float64(b)+0.5) / 1000
			if ms > h.max {
				return h.max
			}
			return ms
		}
	}
	return h.max
}

// What one caller (a goroutine keeping one call in flight) saw.
type caller struct {
	rtt      histogram
	answers  int64 // in the window
	total    int64 // all of the run
	failures int64
}

const (
	phaseWarm int32 = iota
	phaseMeasure
	phaseStop
)

func runClient(o opts) {
	kind := o.str("kind", "num")
	connections := int(o.num("connections", 1))
	inflight := int(o.num("inflight", 1))
	warmup := o.num("warmup", 2)
	seconds := o.num("seconds", 5)
	target := o.str("target", "127.0.0.1:"+o.str("port", "5200"))

	nanos() // the clock calibrates itself on first use

	blob := make([]byte, 4096)
	for i := range blob {
		blob[i] = byte((i*31 + 7) & 0xff)
	}

	clients := make([]benchpb.BenchClient, connections)
	ready, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for i := range clients {
		conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			fmt.Println("FAILED " + err.Error())
			os.Exit(3)
		}
		conn.Connect()
		for state := conn.GetState(); state != connectivity.Ready; state = conn.GetState() {
			if !conn.WaitForStateChange(ready, state) {
				fmt.Println("FAILED connection " + strconv.Itoa(i) + " not ready: " + state.String())
				os.Exit(3)
			}
		}
		clients[i] = benchpb.NewBenchClient(conn)
	}

	var phase atomic.Int32
	callers := make([]*caller, 0, connections*inflight)
	var group sync.WaitGroup
	for _, client := range clients {
		for j := 0; j < inflight; j++ {
			c := &caller{}
			callers = append(callers, c)
			group.Add(1)
			go func(client benchpb.BenchClient, c *caller) {
				defer group.Done()
				ctx := context.Background()
				v := int32(0)
				for {
					p := phase.Load()
					if p == phaseStop {
						return
					}
					sent := nanos()
					var err error
					if kind == "blob" {
						_, err = client.Blob(ctx, &benchpb.BlobMessage{Data: blob})
					} else {
						_, err = client.Num(ctx, &benchpb.NumMessage{V: v & 0xffff})
						v++
					}
					if err != nil {
						c.failures++
						time.Sleep(time.Millisecond)
						continue
					}
					c.total++
					if p == phaseMeasure && phase.Load() == phaseMeasure {
						c.answers++
						c.rtt.add(float64(nanos()-sent) / 1e6)
					}
				}
			}(client, c)
		}
	}

	time.Sleep(time.Duration(warmup * float64(time.Second)))
	fmt.Println("WINDOW_START")
	started := time.Now()
	phase.Store(phaseMeasure)
	time.Sleep(time.Duration(seconds * float64(time.Second)))
	phase.Store(phaseStop)
	elapsed := time.Since(started).Seconds()
	fmt.Println("WINDOW_END")
	group.Wait()

	var all histogram
	var answers, total, failures int64
	for _, c := range callers {
		all.merge(&c.rtt)
		answers += c.answers
		total += c.total
		failures += c.failures
	}
	record := map[string]any{
		"system":       "grpc-go",
		"kind":         kind,
		"connections":  connections,
		"inflight":     inflight,
		"callsPerSec":  math.Round(float64(answers) / elapsed),
		"rttP50us":     math.Round(all.percentile(0.5) * 1000),
		"rttP99us":     math.Round(all.percentile(0.99) * 1000),
		"failures":     failures,
		"totalAnswers": total,
	}
	line, _ := json.Marshal(record)
	fmt.Println("RESULT " + string(line))
	os.Exit(0)
}

func sampleCPU() {
	in := bufio.NewScanner(os.Stdin)
	out := bufio.NewWriter(os.Stdout)
	fmt.Fprintln(out, "READY")
	out.Flush()
	for in.Scan() {
		// A shell's pipe can start the input with a byte-order mark.
		fields := strings.Fields(strings.TrimPrefix(in.Text(), string(rune(0xFEFF))))
		answers := make([]string, len(fields))
		for i, f := range fields {
			pid, err := strconv.Atoi(f)
			seconds := -1.0
			if err == nil {
				seconds = processSeconds(pid)
			}
			answers[i] = strconv.FormatFloat(seconds, 'f', 6, 64)
		}
		fmt.Fprintln(out, strings.Join(answers, " "))
		out.Flush()
	}
}
