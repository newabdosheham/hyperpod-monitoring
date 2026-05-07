#!/bin/bash
# =============================================================================
# Script  : 4_setup_ec2_prometheus.sh
# Purpose : Setup centralized Prometheus on EC2 instance (run ONCE)
# Run on  : EC2 Instance
# Usage   : bash 4_setup_ec2_prometheus.sh
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

PROMETHEUS_VERSION="3.11.3"

log "======================================================"
log " EC2 Centralized Prometheus Setup"
log " Version: ${PROMETHEUS_VERSION}"
log "======================================================"

# ── 1. Create user and directories ───────────────────────────────────────────
log "Creating prometheus user and directories..."
sudo useradd -rs /bin/false prometheus 2>/dev/null || warn "User already exists"
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# ── 2. Install Prometheus ─────────────────────────────────────────────────────
log "Installing Prometheus v${PROMETHEUS_VERSION}..."
cd /tmp
wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz > /dev/null
sudo cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
sudo cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64*
log "Prometheus installed: $(prometheus --version 2>&1 | head -1)"

# ── 3. Write minimal config ───────────────────────────────────────────────────
log "Writing Prometheus configuration..."
sudo tee /etc/prometheus/prometheus.yml > /dev/null << 'EOF'
# EC2 Centralized Prometheus
# This instance ONLY receives data via remote_write from cluster Prometheus instances
# No scrape_configs needed here

global:
  scrape_interval:     60s
  evaluation_interval: 60s
EOF

promtool check config /etc/prometheus/prometheus.yml
log "✅ Config is valid"

# ── 4. Create systemd service ─────────────────────────────────────────────────
log "Creating systemd service..."
sudo tee /etc/systemd/system/prometheus.service > /dev/null << 'EOF'
[Unit]
Description=Prometheus Centralized
After=network.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=2y \
  --web.enable-remote-write-receiver \
  --web.listen-address=0.0.0.0:9090
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# ── 5. Start service ──────────────────────────────────────────────────────────
log "Starting Prometheus..."
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus

sleep 5

# ── 6. Verify ─────────────────────────────────────────────────────────────────
if curl -s http://localhost:9090/api/v1/status/buildinfo > /dev/null 2>&1; then
    log "✅ Prometheus is running"
else
    error "Prometheus is not responding!"
fi

# Check remote write receiver is enabled
RW_ENABLED=$(curl -s http://localhost:9090/api/v1/status/flags | \
    python3 -m json.tool | \
    grep "remote-write-receiver" | \
    grep "true" || true)

if [ -n "$RW_ENABLED" ]; then
    log "✅ Remote write receiver is enabled"
else
    error "Remote write receiver is NOT enabled!"
fi

# ── 7. Get EC2 public IP ──────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "N/A")
PRIVATE_IP=$(hostname -I | awk '{print $1}')

log "======================================================"
log " EC2 Prometheus setup complete!"
log ""
log " Private IP : http://${PRIVATE_IP}:9090"
log " Public IP  : http://${PUBLIC_IP}:9090"
log " Retention  : 2 years"
log ""
log " Share with on-prem Grafana admin:"
log "   URL: http://${PUBLIC_IP}:9090"
log ""
log " IMPORTANT: Update EC2 Security Group to allow:"
log "   Port 9090 from each cluster head node IP"
log "   Port 9090 from on-prem Grafana IP"
log "======================================================"
