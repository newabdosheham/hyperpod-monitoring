#!/bin/bash
# =============================================================================
# Script  : 2_setup_compute_node.sh
# Purpose : Install Node Exporter + DCGM Exporter on compute node
# Run on  : Each HyperPod Compute Node
# Usage   : bash 2_setup_compute_node.sh
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

# ── Versions ──────────────────────────────────────────────────────────────────
NODE_EXPORTER_VERSION="1.8.1"
DCGM_VERSION="3.3.5-3.4.0-ubuntu22.04"

log "======================================================"
log " HyperPod Compute Node Setup"
log " Hostname: $(hostname)"
log " Node Exporter v${NODE_EXPORTER_VERSION}"
log " DCGM Exporter v${DCGM_VERSION}"
log "======================================================"

# ── 1. Create node_exporter user ──────────────────────────────────────────────
log "Creating node_exporter user..."
sudo useradd -rs /bin/false node_exporter 2>/dev/null || warn "User already exists"

# ── 2. Install Node Exporter ──────────────────────────────────────────────────
log "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."
cd /tmp
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz > /dev/null
sudo cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*

sudo tee /etc/systemd/system/node_exporter.service > /dev/null << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter
log "Node Exporter status: $(sudo systemctl is-active node_exporter)"

# ── 3. Install DCGM Exporter ──────────────────────────────────────────────────
log "Installing DCGM Exporter..."

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    error "Docker not found. Please install Docker first."
fi

# Check if GPU is available
if ! nvidia-smi &> /dev/null; then
    warn "nvidia-smi not found. DCGM may not work correctly."
fi

# Stop existing container if running
sudo docker stop dcgm-exporter 2>/dev/null || true
sudo docker rm dcgm-exporter 2>/dev/null || true

# Start DCGM exporter
sudo docker run -d \
    --gpus all \
    --restart always \
    --cap-add SYS_ADMIN \
    --name dcgm-exporter \
    -p 9400:9400 \
    nvcr.io/nvidia/k8s/dcgm-exporter:${DCGM_VERSION}

log "Waiting for DCGM to initialize..."
sleep 20

# ── 4. Verify ─────────────────────────────────────────────────────────────────
log "======================================================"
log " Verifying installations..."
log "======================================================"

# Node Exporter
if curl -s http://localhost:9100/metrics > /dev/null 2>&1; then
    log "✅ Node Exporter  : http://localhost:9100/metrics"
else
    warn "❌ Node Exporter not responding on :9100"
fi

# DCGM Exporter
if curl -s http://localhost:9400/metrics | grep -q "DCGM" 2>/dev/null; then
    GPU_COUNT=$(curl -s http://localhost:9400/metrics | grep "DCGM_FI_DEV_SM_CLOCK" | wc -l)
    log "✅ DCGM Exporter  : http://localhost:9400/metrics (${GPU_COUNT} GPUs detected)"
else
    warn "❌ DCGM Exporter not responding on :9400"
    log "Docker logs:"
    sudo docker logs dcgm-exporter 2>&1 | tail -5
fi

log "======================================================"
log " Compute node setup complete on $(hostname)!"
log " IP: $(hostname -I | awk '{print $1}')"
log "======================================================"
