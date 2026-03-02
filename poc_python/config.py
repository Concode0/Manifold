# Manifold Cluster Configuration

# Network Settings
BASE_PORT = 9001
CLIENT_LISTEN_PORT = 9000

# Cluster Size
NODE_COUNT = 24

# Virtual Machine & Task Settings
DEFAULT_CAPACITY = 10.0
TASK_SPLIT_COUNT = 32  # Number of shards created during Mitosis

# Topology Settings
TOPOLOGY_K_LOCAL = 2
TOPOLOGY_K_LONG = 2
ROUTING_TOP_K = 3     # Pick from top K neighbors during dispatch
