#!/bin/bash
# =============================================================================
# Script  : 6_health_check.sh
# Purpose : Check health of entire monitoring pipeline
# Run on  : HyperPod Head Node OR EC2
# Usage   : bash 6_health_check.sh [--ec2-ip 10.0.1.237]
# =============================================================================

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✅]${NC} $1"; }
warn()    { echo -e "${YELLOW}[⚠️ ]${NC} $1"; }
error()   { echo -e "${RED}[❌]${NC} $1"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Parse Arguments ───────────────────────────────────────────────────────────
EC2_IP=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ec2-ip) EC2_IP="$2"; shift ;;
    esac
    shift
done

# ── 1. Head Node Services ─────────────────────────────────────────────────────
section "Head Node Services"

for service in prometheus node_exporter slurm_exporter; do
    if sudo systemctl is-active $service > /dev/null 2>&1; then
        log "$service is running"
    else
        error "$service is NOT running"
        echo "    Fix: sudo systemctl start $service"
    fi
done

# ── 2. Head Node Endpoints ────────────────────────────────────────────────────
section "Head Node Endpoints"

endpoints=(
    "Prometheus:http://localhost:9090/api/v1/status/buildinfo"
    "Node Exporter:http://localhost:9100/metrics"
    "Slurm Exporter:http://localhost:8080/metrics"
)

for entry in "${endpoints[@]}"; do
    name="${entry%%:*}"
    url="${entry#*:}"
    if curl -s --connect-timeout 5 "$url" > /dev/null 2>&1; then
        log "$name is responding ($url)"
    else
        error "$name is NOT responding ($url)"
    fi
done

# ── 3. Prometheus Targets ─────────────────────────────────────────────────────
section "Prometheus Scrape Targets"

TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null)
if [ -z "$TARGETS" ]; then
    error "Cannot connect to Prometheus"
else
    UP=$(echo "$TARGETS" | python3 -m json.tool | grep '"health": "up"' | wc -l)
    DOWN=$(echo "$TARGETS" | python3 -m json.tool | grep '"health": "down"' | wc -l)

    log "Targets UP   : $UP"
    if [ "$DOWN" -gt 0 ]; then
        error "Targets DOWN : $DOWN"
        echo "    DOWN targets:"
        echo "$TARGETS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if t['health'] == 'down':
        print(f'    ❌ {t[\"labels\"][\"job\"]} → {t[\"scrapeUrl\"]}')
        print(f'       Error: {t.get(\"lastError\", \"unknown\")}')
"
    fi
fi

# ── 4. Remote Write Status ────────────────────────────────────────────────────
section "Remote Write to EC2"

FAILED=$(curl -s 'http://localhost:9090/api/v1/query' \
    --data 'query=prometheus_remote_storage_failed_samples_total' | \
    python3 -m json.tool 2>/dev/null | grep '"value"' | head -1 || echo "")

if [ -z "$FAILED" ]; then
    warn "Remote write metrics not available yet (waiting for first scrape)"
else
    log "Remote write is active"
fi

# ── 5. EC2 Prometheus Check ───────────────────────────────────────────────────
if [ -n "$EC2_IP" ]; then
    section "EC2 Centralized Prometheus ($EC2_IP)"

    if curl -s --connect-timeout 5 http://${EC2_IP}:9090/api/v1/status/buildinfo > /dev/null 2>&1; then
        log "EC2 Prometheus is reachable"

        # Check cluster data is arriving
        CLUSTER_METRICS=$(curl -s "http://${EC2_IP}:9090/api/v1/query" \
            --data 'query=count({cluster!=""})' | \
            python3 -m json.tool 2>/dev/null | grep '"value"' | head -1 || echo "")

        if [ -n "$CLUSTER_METRICS" ]; then
            log "Cluster metrics are arriving on EC2"
        else
            warn "No cluster metrics found on EC2 yet"
        fi

        # List clusters sending data
        echo ""
        echo "  Clusters sending data to EC2:"
        curl -s "http://${EC2_IP}:9090/api/v1/label/cluster/values" | \
            python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('data', []):
    print(f'    ✅ {c}')
" 2>/dev/null || warn "Could not retrieve cluster list"
    else
        error "EC2 Prometheus is NOT reachable at ${EC2_IP}:9090"
        echo "    Check: EC2 security group allows port 9090"
    fi
fi

# ── 6. Summary ────────────────────────────────────────────────────────────────
section "Summary"
echo "  Head Node     : http://$(hostname -I | awk '{print $1}'):9090"
[ -n "$EC2_IP" ] && echo "  EC2 Prometheus: http://${EC2_IP}:9090"
echo ""
echo "  Run with EC2 check:"
echo "  bash 6_health_check.sh --ec2-ip <ec2-ip>"
echo ""
