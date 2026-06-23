package basin

type MessageType string

const (
	MsgHeartbeat   MessageType = "HEARTBEAT"
	MsgStateGossip MessageType = "STATE_GOSSIP"
	MsgTaskMigrate MessageType = "TASK_MIGRATE"
)

type Packet struct {
	Type       MessageType `json:"type"`
	SenderID   string      `json:"sender_id"`
	SenderAddr string      `json:"sender_addr"`

	GossipPayload *GossipData `json:"gossip_payload,omitempty"`
	TaskPayload   *Task       `json:"task_payload,omitempty"`
}

type GossipData struct {
	AvailableRes  Multivector `json:"available_res"`
	Load          float64     `json:"load"`
	QueuePressure float64     `json:"queue_pressure"`
}

type Task struct {
	UUID        string      `json:"uuid"`
	Requirement Multivector `json:"requirement"`
	Mass        float64     `json:"mass"`
	HopCount    int         `json:"hop_count"`
	SplitDepth  int         `json:"split_depth"`
}
