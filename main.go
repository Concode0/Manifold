package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"basin/basin"
)

// pseudoUUID generates a short trace identifier for tasks.
func pseudoUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func main() {
	// Node identity & networking.
	nodeID := flag.String("id", "node_01", "Node identifier")
	nodeAddr := flag.String("addr", "127.0.0.1:8001", "Advertised address (IP:PORT) shared with peers")
	bindAddr := flag.String("bind", "", "TCP bind target (IP:PORT). Defaults to -addr. Use 0.0.0.0:PORT in Docker.")
	joinAddr := flag.String("join", "", "Comma-separated seed addresses to bootstrap from")

	// Heterogeneous capacity profile (e1, e2, e3).
	compCap := flag.Float64("c", 10.0, "Compute capacity (e1)")
	memCap := flag.Float64("m", 10.0, "Memory capacity (e2)")
	netCap := flag.Float64("n", 5.0, "Network capacity (e3)")

	// Continuous workload generator.
	injectWorkloads := flag.Bool("task", false, "Enable continuous local task generation")

	// Task requirement vector — configurable for parameter sweeps.
	taskComp := flag.Float64("task-comp", 4.0, "Task compute requirement (e1)")
	taskMem := flag.Float64("task-mem", 0.8, "Task memory requirement (e2)")
	taskNet := flag.Float64("task-net", 2.0, "Task network requirement (e3)")
	taskMass := flag.Float64("task-mass", 1.0, "Task mass (numerator in V)")
	taskInterval := flag.Duration("task-interval", 1500*time.Millisecond, "Interval between spawned tasks")
	taskLatency := flag.Duration("latency", 300*time.Millisecond, "Simulated execution latency per accepted task")
	hysteresis := flag.Float64("hysteresis", 0.15, "Minimum relative V improvement to justify a migration hop. Below 1-exp(-Beta)≈0.39 the system oscillates by design; above 0.39 it converges.")

	flag.Parse()

	basin.MigrationHysteresis = *hysteresis

	log.SetFlags(0)

	capacity := basin.NewVector(*compCap, *memCap, *netCap)
	node := basin.NewNode(*nodeID, *nodeAddr, capacity)
	if *bindAddr != "" {
		node.BindAddr = *bindAddr
	}
	node.TaskLatency = *taskLatency

	// Listener + background loops (gossip, heartbeat, task processor, reaper).
	node.Start()

	// Bootstrap: announce ourselves to seed nodes.
	if *joinAddr != "" {
		for _, target := range strings.Split(*joinAddr, ",") {
			target = strings.TrimSpace(target)
			if target == "" {
				continue
			}
			log.Printf("[%s] joining seed %s", *nodeID, target)

			bootPkt := basin.Packet{
				Type:       basin.MsgStateGossip,
				SenderID:   node.ID,
				SenderAddr: node.Addr,
				GossipPayload: &basin.GossipData{
					AvailableRes:  node.AvailableRes,
					Load:          node.Load,
					QueuePressure: node.QueuePressure,
				},
			}

			conn, err := net.DialTimeout("tcp", target, 2*time.Second)
			if err != nil {
				log.Printf("[%s] join failed: seed %s unreachable: %v", *nodeID, target, err)
			} else {
				_ = json.NewEncoder(conn).Encode(bootPkt)
				conn.Close()
				node.AddNeighbor(target)
				log.Printf("[%s] joined seed %s", *nodeID, target)
			}
		}
	}

	// Continuous local task generator.
	if *injectWorkloads {
		go func() {
			time.Sleep(3 * time.Second)
			log.Printf("[%s] task generator started", *nodeID)

			ticker := time.NewTicker(*taskInterval)
			defer ticker.Stop()

			for range ticker.C {
				task := basin.Task{
					UUID:        pseudoUUID(),
					Requirement: basin.NewVector(*taskComp, *taskMem, *taskNet),
					Mass:        *taskMass,
				}
				log.Printf("[%s] spawned task %s", *nodeID, task.UUID[:8])
				node.PushTask(task)
			}
		}()
	}

	// Block until SIGINT/SIGTERM.
	signalBuffer := make(chan os.Signal, 1)
	signal.Notify(signalBuffer, syscall.SIGINT, syscall.SIGTERM)

	<-signalBuffer
	log.Printf("[%s] shutting down", *nodeID)
	node.Stop()
	log.Printf("[%s] stopped", *nodeID)
}
