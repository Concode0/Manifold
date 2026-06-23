package basin

import (
	"encoding/json"
	"net"
	"time"
)

// Start opens the TCP listener and spawns the background loops:
// accept, heartbeat, gossip, task processor, and peer reaper.
func (n *Node) Start() {
	bind := n.BindAddr
	if bind == "" {
		bind = n.Addr
	}
	listener, err := net.Listen("tcp", bind)
	if err != nil {
		emitRaw(`{"event":"NODE_START_ERROR","node":"` + n.ID + `","error":"` + err.Error() + `"}`)
		panic(err)
	}
	n.listener = listener

	go n.acceptLoop()
	go n.runHeartbeatLoop()
	go n.runGossipLoop()
	go n.runTaskProcessor()
	go n.runPeerReaper()

	logger.Emit(n, EvNodeStart, F(
		"comp", n.Capacity[1],
		"mem", n.Capacity[2],
		"net", n.Capacity[4],
		"neighbors", len(n.Neighbors),
		"task_latency_ms", n.TaskLatency.Milliseconds(),
	))
}

// Stop closes the listener and signals all loops to exit.
func (n *Node) Stop() {
	close(n.shutdownCh)
	if n.listener != nil {
		_ = n.listener.Close()
	}
	logger.Emit(n, EvNodeStop, F())
}

// acceptLoop only accepts connections and spawns handlers.
func (n *Node) acceptLoop() {
	for {
		conn, err := n.listener.Accept()
		if err != nil {
			select {
			case <-n.shutdownCh:
				return
			default:
				continue
			}
		}
		go n.handleConnection(conn)
	}
}

// handleConnection decodes one packet per connection. Discovery and trust
// updates happen under stateMu, but channel sends are deferred until after
// the lock is released (prevents deadlock on a full TaskQueue).
func (n *Node) handleConnection(conn net.Conn) {
	defer conn.Close()

	var pkt Packet
	if err := json.NewDecoder(conn).Decode(&pkt); err != nil {
		return
	}

	// Discovery / trust seeding — short critical section, no channel ops.
	if pkt.SenderAddr != "" && pkt.SenderAddr != n.Addr {
		n.stateMu.Lock()
		known := false
		for _, neighbor := range n.Neighbors {
			if neighbor == pkt.SenderAddr {
				known = true
				break
			}
		}
		if !known {
			n.Neighbors = append(n.Neighbors, pkt.SenderAddr)
			n.TrustTable[pkt.SenderAddr] = 1.0
			n.stateMu.Unlock()
			logger.Emit(n, EvLinkAdd, F(
				"peer_addr", pkt.SenderAddr,
				"peer_id", pkt.SenderID,
				"trust", 1.0,
				"neighbor_count", len(n.Neighbors),
			))
		} else {
			n.stateMu.Unlock()
		}
	}

	switch pkt.Type {
	case MsgHeartbeat:
		// Trust recovery: +0.05 per heartbeat, capped at 1.0.
		n.stateMu.Lock()
		oldTrust := n.TrustTable[pkt.SenderAddr]
		newTrust := 1.0
		if oldTrust+0.05 < 1.0 {
			newTrust = oldTrust + 0.05
		}
		n.TrustTable[pkt.SenderAddr] = newTrust
		n.stateMu.Unlock()

		if oldTrust < 1.0 {
			logger.Emit(n, EvTrustUpdate, F(
				"peer_addr", pkt.SenderAddr,
				"old", oldTrust,
				"new", newTrust,
				"status", "RECOVERED",
			))
		}

	case MsgStateGossip:
		if pkt.GossipPayload == nil {
			return
		}
		n.stateMu.Lock()
		n.PeerCache[pkt.SenderAddr] = PeerState{
			Addr:          pkt.SenderAddr,
			AvailableRes:  pkt.GossipPayload.AvailableRes,
			Load:          pkt.GossipPayload.Load,
			QueuePressure: pkt.GossipPayload.QueuePressure,
			Trust:         n.TrustTable[pkt.SenderAddr],
			LastUpdated:   time.Now(),
		}
		n.stateMu.Unlock()

	case MsgTaskMigrate:
		if pkt.TaskPayload == nil {
			return
		}
		t := *pkt.TaskPayload
		t.HopCount++
		// Account for the task in our queue pressure before enqueueing.
		// The channel send happens outside the lock to avoid blocking on
		// a full TaskQueue while holding stateMu.
		n.stateMu.Lock()
		n.QueuePressure++
		n.stateMu.Unlock()
		n.TaskQueue <- t
	}
}

// sendPacket dials a peer, encodes one packet, and applies trust decay
// (-0.2, floored at 0) on any dial/encode failure.
func (n *Node) sendPacket(targetAddr string, pkt Packet) bool {
	conn, err := net.DialTimeout("tcp", targetAddr, 100*time.Millisecond)
	if err != nil {
		n.stateMu.Lock()
		oldTrust := n.TrustTable[targetAddr]
		newTrust := oldTrust - 0.2
		if newTrust < 0 {
			newTrust = 0
		}
		n.TrustTable[targetAddr] = newTrust
		n.stateMu.Unlock()

		if oldTrust > 0 {
			logger.Emit(n, EvTrustUpdate, F(
				"peer_addr", targetAddr,
				"old", oldTrust,
				"new", newTrust,
				"status", "DEGRADED",
			))
		}
		return false
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(pkt); err != nil {
		return false
	}
	return true
}

// runPeerReaper evicts peer cache entries that haven't gossiped within PeerTTL.
func (n *Node) runPeerReaper() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-n.shutdownCh:
			return
		case <-ticker.C:
			now := time.Now()
			var expired []string
			n.stateMu.Lock()
			for addr, p := range n.PeerCache {
				if now.Sub(p.LastUpdated) > n.PeerTTL {
					delete(n.PeerCache, addr)
					expired = append(expired, addr)
				}
			}
			n.stateMu.Unlock()
			for _, addr := range expired {
				logger.Emit(n, EvPeerExpire, F("peer_addr", addr))
			}
		}
	}
}
