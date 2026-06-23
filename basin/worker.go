package basin

import (
	"crypto/rand"
	"math/big"
	"time"
)

// runHeartbeatLoop ticks every 200ms to push presence probes to every
// known neighbour. Receipt on the other side drives trust recovery.
func (n *Node) runHeartbeatLoop() {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-n.shutdownCh:
			return
		case <-ticker.C:
			n.stateMu.RLock()
			neighbors := append([]string{}, n.Neighbors...)
			n.stateMu.RUnlock()

			for _, addr := range neighbors {
				pkt := Packet{Type: MsgHeartbeat, SenderID: n.ID, SenderAddr: n.Addr}
				go n.sendPacket(addr, pkt)
			}
		}
	}
}

// runGossipLoop ticks every 500ms. It broadcasts this node's current
// capacity/load/queue to all neighbours, and emits the STATE_SYNC and
// POTENTIAL records used as the primary playback tick for visualization.
func (n *Node) runGossipLoop() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-n.shutdownCh:
			return
		case <-ticker.C:
			n.stateMu.RLock()
			targets := append([]string{}, n.Neighbors...)

			gData := &GossipData{
				AvailableRes:  n.AvailableRes,
				Load:          n.Load,
				QueuePressure: n.QueuePressure,
			}

			// Snapshot for logging — copy values out from under the lock.
			load := n.Load
			queue := n.QueuePressure
			avail := n.AvailableRes
			peerCount := len(n.PeerCache)
			neighborCount := len(n.Neighbors)
			n.stateMu.RUnlock()

			logger.Emit(n, EvStateSync, F(
				"load", load,
				"queue", queue,
				"comp", avail[1],
				"mem", avail[2],
				"net", avail[4],
				"peers", peerCount,
				"neighbors", neighborCount,
			))

			pkt := Packet{
				Type:          MsgStateGossip,
				SenderID:      n.ID,
				SenderAddr:    n.Addr,
				GossipPayload: gData,
			}

			for _, addr := range targets {
				go n.sendPacket(addr, pkt)
			}

			// Emit potential field sample after the gossip snapshot so the
			// playback timeline has a consistent (state, field) pair per tick.
			n.emitPotentialField()
		}
	}
}

// emitPotentialField logs this node's own potential plus one entry per
// cached peer. This is the primary input for the 3D potential field view.
func (n *Node) emitPotentialField() {
	type peerField struct {
		Addr      string  `json:"addr"`
		Trust     float64 `json:"trust"`
		Load      float64 `json:"load"`
		Queue     float64 `json:"queue"`
		Comp      float64 `json:"comp"`
		Mem       float64 `json:"mem"`
		Net       float64 `json:"net"`
		Potential float64 `json:"potential"`
		PhiSelf   float64 `json:"phi_self"`
		AgeMs     int64   `json:"age_ms"`
	}

	n.stateMu.RLock()
	defer n.stateMu.RUnlock()

	// Self potential — evaluated against a hypothetical task shaped like
	// the node's own capacity envelope. Note: this returns +Inf whenever
	// any task is running (AvailableRes < Capacity), because the envelope
	// no longer fits. The visualization clips it for display.
	selfPotential := n.EvaluatePotential(
		Task{Requirement: n.Capacity, Mass: 1.0},
		n.AvailableRes, n.Load, n.QueuePressure, 1.0,
	)
	selfPhi := CalculatePhi(n.AvailableRes, n.Capacity)

	peers := make([]peerField, 0, len(n.PeerCache))
	for addr, p := range n.PeerCache {
		trust := n.TrustTable[addr]
		if trust < 1e-4 {
			trust = 1e-4
		}
		// Peer potential is evaluated with this node's capacity envelope as
		// the task requirement, yielding a scalar comparable across peers.
		peerPot := n.EvaluatePotential(
			Task{Requirement: n.Capacity, Mass: 1.0},
			p.AvailableRes, p.Load, p.QueuePressure, trust,
		)
		peerPhi := CalculatePhi(p.AvailableRes, n.Capacity)

		peers = append(peers, peerField{
			Addr:      addr,
			Trust:     trust,
			Load:      p.Load,
			Queue:     p.QueuePressure,
			Comp:      p.AvailableRes[1],
			Mem:       p.AvailableRes[2],
			Net:       p.AvailableRes[4],
			Potential: peerPot,
			PhiSelf:   peerPhi,
			AgeMs:     time.Since(p.LastUpdated).Milliseconds(),
		})
	}

	logger.Emit(n, EvPotential, F(
		"self_potential", selfPotential,
		"self_phi", selfPhi,
		"self_comp", n.AvailableRes[1],
		"self_mem", n.AvailableRes[2],
		"self_net", n.AvailableRes[4],
		"self_load", n.Load,
		"self_queue", n.QueuePressure,
		"peers", peers,
	))
}

// runTaskProcessor is the routing loop. For every dequeued task it
// evaluates the local potential, samples two random neighbours (Po2C),
// and forwards if either offers a meaningfully lower potential. Tasks
// that exceed MaxHops are force-accepted to break oscillation. On
// accept, AvailableRes is decremented (resource consumption); on
// completion it is restored. This makes the potential field genuinely
// shape-sensitive.
func (n *Node) runTaskProcessor() {
	for {
		select {
		case <-n.shutdownCh:
			return
		case t := <-n.TaskQueue:
			n.stateMu.Lock()
			currentPotential := n.EvaluatePotential(t, n.AvailableRes, n.Load, n.QueuePressure, 1.0)

			// Hop-count cap: once a task has been forwarded MaxHops times,
			// accept it locally to prevent pathological oscillation.
			forceAccept := t.HopCount >= MaxHops

			bestAddr := ""
			bestPotential := currentPotential

			if !forceAccept {
				for _, addr := range n.samplePo2CCandidates() {
					peer, exists := n.PeerCache[addr]
					trust := n.TrustTable[addr]

					if exists && trust < 1e-4 {
						trust = 1e-4
					}

					if exists {
						p := n.EvaluatePotential(t, peer.AvailableRes, peer.Load, peer.QueuePressure, trust)
						if ShouldMigrate(bestPotential, p) {
							bestPotential = p
							bestAddr = addr
						}
					}
				}
			}

			if bestAddr != "" && bestAddr != n.Addr {
				n.QueuePressure--
				n.stateMu.Unlock()

				if !n.sendPacket(bestAddr, Packet{
					Type: MsgTaskMigrate, SenderID: n.ID, SenderAddr: n.Addr, TaskPayload: &t,
				}) {
					// Wire failure — re-enqueue and let trust decay ride.
					n.stateMu.Lock()
					n.QueuePressure++
					n.stateMu.Unlock()
					n.TaskQueue <- t
					logger.Emit(n, EvTaskReject, F(
						"task", t.UUID,
						"target", bestAddr,
						"reason", "WIRE_FAIL",
						"hops", t.HopCount,
					))
				} else {
					logger.Emit(n, EvTaskMigrate, F(
						"task", t.UUID,
						"target", bestAddr,
						"hops", t.HopCount,
						"split_depth", t.SplitDepth,
						"potential", bestPotential,
					))
				}
			} else {
				// Local acceptance — consume resources, execute, restore.
				phi := CalculatePhi(n.AvailableRes, t.Requirement)
				for i, r := range t.Requirement {
					n.AvailableRes[i] -= r
					if n.AvailableRes[i] < 0 {
						n.AvailableRes[i] = 0
					}
				}
				n.Load += 0.15
				n.QueuePressure--
				n.stateMu.Unlock()

				logger.Emit(n, EvTaskAccept, F(
					"task", t.UUID,
					"phi", phi,
					"potential", currentPotential,
					"hops", t.HopCount,
					"load", n.Load,
					"queue", n.QueuePressure,
				))

				time.Sleep(n.TaskLatency)

				n.stateMu.Lock()
				n.Load -= 0.15
				if n.Load < 0 {
					n.Load = 0
				}
				for i, r := range t.Requirement {
					n.AvailableRes[i] += r
					if n.AvailableRes[i] > n.Capacity[i] {
						n.AvailableRes[i] = n.Capacity[i]
					}
				}
				n.stateMu.Unlock()

				logger.Emit(n, EvTaskComplete, F(
					"task", t.UUID,
					"latency_ms", n.TaskLatency.Milliseconds(),
				))
			}
		}
	}
}

// samplePo2CCandidates returns two distinct neighbour addresses chosen
// uniformly at random (Power-of-Two-Choices). If fewer than two
// neighbours are known, all of them are returned.
func (n *Node) samplePo2CCandidates() []string {
	if len(n.Neighbors) < 2 {
		return n.Neighbors
	}

	sampled := make([]string, 0, 2)
	for len(sampled) < 2 {
		idx, _ := rand.Int(rand.Reader, big.NewInt(int64(len(n.Neighbors))))
		addr := n.Neighbors[idx.Int64()]

		dup := false
		for _, s := range sampled {
			if s == addr {
				dup = true
			}
		}
		if !dup {
			sampled = append(sampled, addr)
		}
	}
	return sampled
}
