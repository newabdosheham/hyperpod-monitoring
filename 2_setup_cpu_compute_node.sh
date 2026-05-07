#!/bin/bash
# =============================================================================
# Script  : 2_setup_compute_node.sh
# Purpose : Install Node Exporter + DCGM Exporter on compute node
# Run on  : Each HyperPod Compute Node
# Usage   : sudo bash 2_setup_compute_node.sh
# Notes   : Handles shared FSx Lustre storage (binary already exists case)
#           Automatically detects GPU vs CPU-only nodes
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
log " Hostname  : $(hostname)"
log " Node type : $(nvidia-smi &>/dev/null && echo 'GPU' || echo 'CPU-only')"
log " Node Exporter v${NODE_EXPORTER_VERSION}"
log " DCGM Exporter v${DCGM_VERSION}"
log "======================================================"

# ── 1. Create node_exporter user ──────────────────────────────────────────────
log "Creating node_exporter user..."
sudo useradd -rs /bin/false node_exporter 2>/dev/null || warn "User already exists"

# ── 2. Install Node Exporter ──────────────────────────────────────────────────
log "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

# Check if binary already exists (shared FSx Lustre case)
if [ -f /usr/local/bin/node_exporter ]; then
    warn "node_exporter binary already exists — skipping download and copy"
    warn "This is expected when nodes share FSx Lustre storage"
else
    cd /tmp
    wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
    tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz > /dev/null

    # Stop service before copying if running (avoids "Text file busy" error)
    sudo systemctl stop node_exporter 2>/dev/null || true
    sudo cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
    rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
    log "node_exporter binary installed"
fi

# Always create/update service file (each node needs its own systemd service)
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
sudo systemctl restart node_exporter
log "Node Exporter status: $(sudo systemctl is-active node_exporter)"

# ── 3. Detect GPU and Install DCGM if available ───────────────────────────────
GPU_AVAILABLE=false

if nvidia-smi &> /dev/null; then
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    log "GPU detected: ${GPU_COUNT} GPU(s) found"
    GPU_AVAILABLE=true
else
    warn "No GPU detected — this is a CPU-only node. Skipping DCGM Exporter."
fi

if [ "$GPU_AVAILABLE" = true ]; then
    log "Installing DCGM Exporter..."

    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker first."
    fi

    # Check if DCGM container already running
    if sudo docker ps | grep -q dcgm-exporter; then
        warn "DCGM exporter container already running — restarting with correct config"
        sudo docker stop dcgm-exporter 2>/dev/null || true
        sudo docker rm dcgm-exporter 2>/dev/null || true
    fi

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
fi

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

# DCGM Exporter (only if GPU available)
if [ "$GPU_AVAILABLE" = true ]; then
    if curl -s http://localhost:9400/metrics | grep -q "DCGM" 2>/dev/null; then
        GPU_COUNT=$(curl -s http://localhost:9400/metrics | grep "DCGM_FI_DEV_SM_CLOCK" | wc -l)
        log "✅ DCGM Exporter  : http://localhost:9400/metrics (${GPU_COUNT} GPUs detected)"
    else
        warn "❌ DCGM Exporter not responding on :9400"
        log "Docker logs:"
        sudo docker logs dcgm-exporter 2>&1 | tail -5
    fi
else
    log "⏭️  DCGM Exporter  : Skipped (CPU-only node)"
fi

log "======================================================"
log " Compute node setup complete on $(hostname)!"
log " Node type : $([ "$GPU_AVAILABLE" = true ] && echo 'GPU' || echo 'CPU-only')"
log " IP        : $(hostname -I | awk '{print $1}')"
log "======================================================"
