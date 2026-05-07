#!/bin/bash
# =============================================================================
# Script  : 1_setup_head_node.sh
# Purpose : Install Prometheus + Node Exporter + Slurm Exporter on head node
# Run on  : HyperPod Head Node (controller)
# Usage   : bash 1_setup_head_node.sh
# =============================================================================

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Versions ──────────────────────────────────────────────────────────────────
PROMETHEUS_VERSION="3.11.3"
NODE_EXPORTER_VERSION="1.8.1"

log "======================================================"
log " HyperPod Head Node Setup"
log " Prometheus v${PROMETHEUS_VERSION}"
log " Node Exporter v${NODE_EXPORTER_VERSION}"
log " Slurm Exporter (latest)"
log "======================================================"

# ── 1. Create prometheus user ─────────────────────────────────────────────────
log "Creating prometheus user..."
sudo useradd -rs /bin/false prometheus 2>/dev/null || warn "User prometheus already exists"
sudo useradd -rs /bin/false node_exporter 2>/dev/null || warn "User node_exporter already exists"

# ── 2. Create directories ─────────────────────────────────────────────────────
log "Creating directories..."
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# ── 3. Install Prometheus ─────────────────────────────────────────────────────
log "Installing Prometheus v${PROMETHEUS_VERSION}..."
cd /tmp
wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz > /dev/null
sudo cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
sudo cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64*
log "Prometheus installed: $(prometheus --version 2>&1 | head -1)"

# ── 4. Install Node Exporter ──────────────────────────────────────────────────
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

# ── 5. Install Slurm Exporter ─────────────────────────────────────────────────
log "Installing Slurm Exporter..."

# Check if Go is available
if ! command -v go &> /dev/null; then
    log "Installing Go..."
    sudo apt-get install -y golang-go git 2>/dev/null || \
    sudo yum install -y golang git 2>/dev/null || \
    error "Could not install Go. Please install manually."
fi

cd /tmp
if [ -d "prometheus-slurm-exporter" ]; then
    rm -rf prometheus-slurm-exporter
fi
git clone -q https://github.com/vpenso/prometheus-slurm-exporter.git
cd prometheus-slurm-exporter
sudo go build -o prometheus-slurm-exporter . 2>/dev/null
sudo cp prometheus-slurm-exporter /usr/local/bin/
cd /tmp && rm -rf prometheus-slurm-exporter

sudo tee /etc/systemd/system/slurm_exporter.service > /dev/null << 'EOF'
[Unit]
Description=Slurm Exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/prometheus-slurm-exporter
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable slurm_exporter
sudo systemctl start slurm_exporter
log "Slurm Exporter status: $(sudo systemctl is-active slurm_exporter)"

# ── 6. Verify ─────────────────────────────────────────────────────────────────
log "======================================================"
log " Verifying installations..."
log "======================================================"

sleep 5

# Node Exporter
if curl -s http://localhost:9100/metrics > /dev/null 2>&1; then
    log "✅ Node Exporter  : http://localhost:9100/metrics"
else
    warn "❌ Node Exporter not responding on :9100"
fi

# Slurm Exporter
if curl -s http://localhost:8080/metrics > /dev/null 2>&1; then
    log "✅ Slurm Exporter : http://localhost:8080/metrics"
else
    warn "❌ Slurm Exporter not responding on :8080"
fi

log "======================================================"
log " Head node setup complete!"
log " Next: Run 2_setup_compute_node.sh on each compute node"
log " Then: Run 3_configure_prometheus.sh on this head node"
log "======================================================"
