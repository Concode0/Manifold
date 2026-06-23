package basin

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"
)

// EventName identifies a discrete observable phenomenon emitted by a node.
type EventName string

const (
	EvNodeStart    EventName = "NODE_START"
	EvNodeStop     EventName = "NODE_STOP"
	EvLinkAdd      EventName = "LINK_ADD"
	EvTrustUpdate  EventName = "TRUST_UPDATE"
	EvStateSync    EventName = "STATE_SYNC"
	EvPotential    EventName = "POTENTIAL"
	EvTaskMigrate  EventName = "TASK_MIGRATE"
	EvTaskAccept   EventName = "TASK_ACCEPT"
	EvTaskComplete EventName = "TASK_COMPLETE"
	EvTaskReject   EventName = "TASK_REJECT"
	EvPeerExpire   EventName = "PEER_EXPIRE"
)

// LogRecord is the canonical structured envelope for every emitted event.
// One JSON object per line (NDJSON) so playback scripts can stream
// line-by-line without a streaming parser.
type LogRecord struct {
	// Ts is the UTC microsecond timestamp at emit time.
	Ts string `json:"ts"`
	// TsUnix is the monotonic Unix microsecond value used for delta math.
	TsUnix int64 `json:"ts_unix"`
	// Event is the discriminant tag for downstream fan-out.
	Event EventName `json:"event"`
	// Node is the emitting node's ID.
	Node string `json:"node"`
	// Addr is the emitting node's advertised address.
	Addr string `json:"addr,omitempty"`
	// Seq is a per-node monotonic sequence counter for ordering reconstruction.
	Seq uint64 `json:"seq"`
	// Fields is the event-specific payload.
	Fields map[string]any `json:"fields,omitempty"`
}

// jsonLogger emits NDJSON records on stdout. Stdout is chosen so Docker
// container logs capture everything directly without log-file mounts.
type jsonLogger struct {
	seq uint64
}

var logger = &jsonLogger{}

// Emit writes a structured record. The map is built lazily by callers
// using the F() helper so unused fields don't cost allocations.
func (l *jsonLogger) Emit(node *Node, event EventName, fields map[string]any) {
	l.seq++
	rec := LogRecord{
		Ts:     time.Now().UTC().Format("2006-01-02T15:04:05.000000Z"),
		TsUnix: time.Now().UnixMicro(),
		Event:  event,
		Node:   node.ID,
		Addr:   node.Addr,
		Seq:    l.seq,
		Fields: fields,
	}
	b, _ := json.Marshal(rec)
	fmt.Fprintln(os.Stdout, string(b))
}

// F is a small map literal helper to keep call sites compact.
func F(kv ...any) map[string]any {
	m := make(map[string]any, len(kv)/2)
	for i := 0; i+1 < len(kv); i += 2 {
		k, ok := kv[i].(string)
		if !ok {
			panic("F: odd key must be string")
		}
		m[k] = kv[i+1]
	}
	return m
}

// emitRaw writes a single line before a Node exists (used for boot errors).
func emitRaw(s string) {
	log.New(os.Stdout, "", 0).Println(s)
}

func init() {
	// NDJSON is self-describing — drop the standard logger's prefix and date.
	log.SetFlags(0)
	log.SetOutput(os.Stdout)
}
