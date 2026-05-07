#!/bin/bash
# =============================================================================
# Script  : 3_configure_prometheus.sh
# Purpose : Configure and start Prometheus on head node with remote_write to EC2
# Run on  : HyperPod Head Node (controller)
# Usage   : bash 3_configure_prometheus.sh \
#             --cluster-name "Shared-Cluster" \
#             --region "us-west-1" \
#             --ec2-ip "10.0.1.237"
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
CLUSTER_NAME=""
REGION=""
EC2_IP=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --cluster-name) CLUSTER_NAME="$2"; shift ;;
        --region)       REGION="$2";       shift ;;
        --ec2-ip)       EC2_IP="$2";       shift ;;
        *) error "Unknown parameter: $1" ;;
    esac
    shift
done

# ── Validate Arguments ────────────────────────────────────────────────────────
[ -z "$CLUSTER_NAME" ] && error "--cluster-name is required (e.g. Shared-Cluster)"
[ -z "$REGION" ]       && error "--region is required (e.g. us-west-1)"
[ -z "$EC2_IP" ]       && error "--ec2-ip is required (e.g. 10.0.1.237)"

log "======================================================"
log " Configuring Prometheus"
log " Cluster : ${CLUSTER_NAME}"
log " Region  : ${REGION}"
log " EC2 IP  : ${EC2_IP}"
log "======================================================"

# ── 1. Get Compute Node IPs from Slurm ───────────────────────────────────────
log "Discovering compute nodes from Slurm..."

if ! command -v scontrol &> /dev/null; then
    error "scontrol not found. Is Slurm installed on this node?"
fi

COMPUTE_IPS=$(scontrol show nodes -o | grep -oP 'NodeAddr=\K\S+' | sort -u)

if [ -z "$COMPUTE_IPS" ]; then
    warn "No compute nodes found from Slurm. Check scontrol show nodes"
    COMPUTE_IPS=""
fi

log "Compute nodes found:"
for ip in $COMPUTE_IPS; do
    log "  - $ip"
done

# ── 2. Build compute-node targets ────────────────────────────────────────────
NODE_TARGETS=""
GPU_TARGETS=""
for ip in $COMPUTE_IPS; do
    NODE_TARGETS="${NODE_TARGETS}          - '${ip}:9100'\n"
    GPU_TARGETS="${GPU_TARGETS}          - '${ip}:9400'\n"
done

# ── 3. Write Prometheus Config ───────────────────────────────────────────────
log "Writing Prometheus configuration..."

sudo tee /etc/prometheus/prometheus.yml > /dev/null << EOF
global:
  scrape_interval:     60s
  evaluation_interval: 60s
  external_labels:
    cluster: '${CLUSTER_NAME}'
    region:  '${REGION}'

remote_write:
  - url: http://${EC2_IP}:9090/api/v1/write
    remote_timeout: 30s
    queue_config:
      capacity:             10000
      max_samples_per_send: 2000
      max_shards:           10

scrape_configs:

  - job_name: 'head-node'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
        labels:
          node_type: 'head'
          node:      '$(hostname)'

  - job_name: 'slurm'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:8080']
        labels:
          node_type: 'head'
          node:      '$(hostname)'

  - job_name: 'compute-node'
    scrape_interval: 60s
    static_configs:
      - targets:
$(echo -e "$NODE_TARGETS")
        labels:
          node_type: 'compute'

  - job_name: 'compute-gpu'
    scrape_interval: 60s
    honor_timestamps: false
    static_configs:
      - targets:
$(echo -e "$GPU_TARGETS")
        labels:
          node_type: 'compute'
EOF

# ── 4. Validate Config ────────────────────────────────────────────────────────
log "Validating configuration..."
promtool check config /etc/prometheus/prometheus.yml || error "Config validation failed!"
log "✅ Config is valid"

# ── 5. Create Systemd Service ─────────────────────────────────────────────────
log "Creating Prometheus systemd service..."

sudo tee /etc/systemd/system/prometheus.service > /dev/null << 'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.enable-remote-write-receiver \
  --web.listen-address=0.0.0.0:9090
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# ── 6. Start Prometheus ───────────────────────────────────────────────────────
log "Starting Prometheus..."
sudo systemctl daemon-reload
sudo systemctl enable prometheus

# Use reload if already running, start if not
if sudo systemctl is-active prometheus > /dev/null 2>&1; then
    sudo systemctl reload prometheus
    log "Prometheus reloaded with new config"
else
    sudo systemctl start prometheus
    log "Prometheus started"
fi

# ── 7. Verify ─────────────────────────────────────────────────────────────────
log "Waiting for Prometheus to start..."
sleep 10

if curl -s http://localhost:9090/api/v1/status/buildinfo > /dev/null 2>&1; then
    log "✅ Prometheus is running: http://localhost:9090"
else
    error "Prometheus is not responding. Check: sudo journalctl -u prometheus -f"
fi

# ── 8. Check Targets ──────────────────────────────────────────────────────────
log "Waiting for first scrape cycle (60s)..."
sleep 65

log "Target health status:"
curl -s http://localhost:9090/api/v1/targets | \
    python3 -m json.tool | \
    grep -E '"health"|"job"|"instance"' | \
    paste - - - | \
    awk '{print "  " $0}'

log "======================================================"
log " Prometheus configured successfully!"
log " Cluster    : ${CLUSTER_NAME}"
log " Region     : ${REGION}"
log " Remote Write → http://${EC2_IP}:9090"
log " Local UI   → http://$(hostname -I | awk '{print $1}'):9090"
log "======================================================"
