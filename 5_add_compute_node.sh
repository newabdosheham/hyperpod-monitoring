#!/bin/bash
# =============================================================================
# Script  : 5_add_compute_node.sh
# Purpose : Add a new compute node to existing cluster monitoring
# Run on  : HyperPod Head Node (controller)
# Usage   : sudo bash 5_add_compute_node.sh --node-ip "10.0.x.x"
# =============================================================================

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Parse Arguments ───────────────────────────────────────────────────────────
NODE_IP=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --node-ip) NODE_IP="$2"; shift ;;
        *) error "Unknown parameter: $1" ;;
    esac
    shift
done

[ -z "$NODE_IP" ] && error "--node-ip is required (e.g. --node-ip 10.0.x.x)"

PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"

log "======================================================"
log " Adding New Compute Node: ${NODE_IP}"
log "======================================================"

# ── 1. Verify node is reachable ───────────────────────────────────────────────
log "Checking connectivity to ${NODE_IP}..."
if ! ping -c 1 -W 3 $NODE_IP > /dev/null 2>&1; then
    error "Cannot reach ${NODE_IP}. Check network connectivity."
fi
log "✅ Node is reachable"

# ── 2. Check exporters are running on new node ────────────────────────────────
log "Checking exporters on ${NODE_IP}..."

GPU_NODE=false

if curl -s --connect-timeout 5 http://${NODE_IP}:9100/metrics > /dev/null 2>&1; then
    log "✅ Node Exporter is running on ${NODE_IP}:9100"
else
    error "❌ Node Exporter not responding on ${NODE_IP}:9100. Run 2_setup_compute_node.sh first."
fi

if curl -s --connect-timeout 5 http://${NODE_IP}:9400/metrics | grep -q "DCGM" 2>/dev/null; then
    GPU_COUNT=$(curl -s http://${NODE_IP}:9400/metrics | grep "DCGM_FI_DEV_SM_CLOCK" | wc -l)
    log "✅ DCGM Exporter is running on ${NODE_IP}:9400 (${GPU_COUNT} GPUs)"
    GPU_NODE=true
else
    warn "⚠️  DCGM not found on ${NODE_IP}:9400 — treating as CPU-only node"
    log "   Only Node Exporter :9100 will be added to monitoring"
fi

# ── 3. Check if node already exists in config ─────────────────────────────────
if grep -q "$NODE_IP" $PROMETHEUS_CONFIG; then
    warn "Node ${NODE_IP} already exists in prometheus.yml"
    warn "No changes needed."
    exit 0
fi

# ── 4. Backup existing config ─────────────────────────────────────────────────
BACKUP="${PROMETHEUS_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
cp $PROMETHEUS_CONFIG $BACKUP
log "Backup saved: ${BACKUP}"

# ── 5. Add node using Python (handles IPs with dots safely) ──────────────────
log "Adding ${NODE_IP} to Prometheus config..."

python3 << PYEOF
import re

node_ip = "${NODE_IP}"
gpu_node = "${GPU_NODE}" == "true"
config_file = "${PROMETHEUS_CONFIG}"

with open(config_file, 'r') as f:
    content = f.read()

# Always add to compute-node job (:9100)
content = re.sub(
    r"(job_name: 'compute-node'.*?targets:.*?)((\s+- '[^']+:9100')+)",
    lambda m: m.group(0) + f"\n          - '{node_ip}:9100'",
    content,
    flags=re.DOTALL
)

# Only add to compute-gpu job (:9400) if GPU node
if gpu_node:
    content = re.sub(
        r"(job_name: 'compute-gpu'.*?targets:.*?)((\s+- '[^']+:9400')+)",
        lambda m: m.group(0) + f"\n          - '{node_ip}:9400'",
        content,
        flags=re.DOTALL
    )
    print(f"Added {node_ip} to compute-node and compute-gpu jobs")
else:
    print(f"Added {node_ip} to compute-node job only (CPU-only node)")

with open(config_file, 'w') as f:
    f.write(content)
PYEOF

# ── 6. Validate updated config ────────────────────────────────────────────────
log "Validating configuration..."
if promtool check config $PROMETHEUS_CONFIG; then
    log "✅ Config is valid"
else
    warn "Config validation failed! Restoring backup..."
    cp $BACKUP $PROMETHEUS_CONFIG
    error "Config restored from backup. Please add node manually using nano."
fi

# ── 7. Verify node was added to both jobs ────────────────────────────────────
if grep -q "${NODE_IP}:9100" $PROMETHEUS_CONFIG && \
   grep -q "${NODE_IP}:9400" $PROMETHEUS_CONFIG; then
    log "✅ Node ${NODE_IP} added to both compute-node and compute-gpu jobs"
else
    error "Node was not added correctly. Please check config manually."
fi

# ── 8. Restart Prometheus ─────────────────────────────────────────────────────
log "Restarting Prometheus..."
systemctl restart prometheus
sleep 10

if systemctl is-active prometheus > /dev/null 2>&1; then
    log "✅ Prometheus restarted successfully"
else
    error "Prometheus failed to restart! Check: journalctl -u prometheus -f"
fi

# ── 9. Verify new node is being scraped ──────────────────────────────────────
log "Waiting for first scrape (30s)..."
sleep 30

log "Checking target health for ${NODE_IP}..."
TARGETS=$(curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool)
NODE_HEALTH=$(echo "$TARGETS" | grep -A5 "\"${NODE_IP}:9100\"" | \
    grep "health" | head -1 | tr -d ' ",' | cut -d: -f2)
GPU_HEALTH=$(echo "$TARGETS" | grep -A5 "\"${NODE_IP}:9400\"" | \
    grep "health" | head -1 | tr -d ' ",' | cut -d: -f2)

log "======================================================"
log " New Node Added Successfully!"
log ""
log " Node IP        : ${NODE_IP}"
log " Node Exporter  : ${NODE_HEALTH:-pending}"
log " DCGM Exporter  : ${GPU_HEALTH:-pending}"
log ""
log " All current targets:"
curl -s http://localhost:9090/api/v1/targets | \
    python3 -m json.tool | \
    grep -E '"instance"|"health"' | \
    paste - - | \
    awk '{print "   " $0}'
log "======================================================"
