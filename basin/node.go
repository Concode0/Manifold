package basin

import (
	"net"
	"sync"
	"time"
)

// PeerState is the cached snapshot of a neighbour's last gossip broadcast.
type PeerState struct {
	Addr          string
	AvailableRes  Multivector
	Load          float64
	QueuePressure float64
	Trust         float64
	LastUpdated   time.Time
}

type Node struct {
	ID   string
	Addr string // Advertised address (what peers dial)

	Capacity      Multivector // Static e1/e2/e3 ceiling
	AvailableRes  Multivector // Current free capacity (capacity − running tasks)
	Load          float64
	QueuePressure float64

	Neighbors []string // Dial strings of known peers

	stateMu    sync.RWMutex
	PeerCache  map[string]PeerState
	TrustTable map[string]float64

	TaskQueue  chan Task
	shutdownCh chan struct{}
	listener   net.Listener

	// BindAddr is the actual TCP bind target. Defaults to Addr.
	// In Docker, Addr is the service name (advertised) while BindAddr is 0.0.0.0.
	BindAddr string

	// TaskLatency is the simulated execution time for an accepted task.
	TaskLatency time.Duration

	// PeerTTL is how long a peer entry remains valid without gossip refresh.
	PeerTTL time.Duration
}

func NewNode(id string, addr string, capacity Multivector) *Node {
	return &Node{
		ID:           id,
		Addr:         addr,
		BindAddr:     addr,
		Capacity:     capacity,
		AvailableRes: capacity,
		PeerCache:    make(map[string]PeerState),
		TrustTable:   make(map[string]float64),
		TaskQueue:    make(chan Task, 1000),
		shutdownCh:   make(chan struct{}),
		TaskLatency:  300 * time.Millisecond,
		PeerTTL:      5 * time.Second,
	}
}

// PushTask increments queue pressure and enqueues a task.
func (n *Node) PushTask(t Task) {
	n.stateMu.Lock()
	n.QueuePressure++
	n.stateMu.Unlock()
	n.TaskQueue <- t
}

// AddNeighbor registers a peer address and seeds trust at 1.0.
func (n *Node) AddNeighbor(addr string) {
	n.stateMu.Lock()
	defer n.stateMu.Unlock()
	n.Neighbors = append(n.Neighbors, addr)
	n.TrustTable[addr] = 1.0
}
