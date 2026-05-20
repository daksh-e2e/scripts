#!/usr/bin/env bash
# =============================================================================
# E2E Observability Agent — VM install script
# =============================================================================
#
# Usage:
#   E2E_API_KEY=<your-api-key> E2E_PROJECT_ID=<project-id> E2E_CUSTOMER_ID=<customer-id> \
#     bash -c "$(curl -L https://obs.e2enetworks.net/install/vm.sh)"
#
# Optional:
#   E2E_ENV=production          — environment label (shown in dashboards)
#   E2E_SITE=obs.e2enetworks.net — override the default API endpoint
#
# Supports: AlmaLinux/RHEL 8+, Ubuntu 20.04+, Debian 11+
# Requires: curl, docker, systemd, root or sudo
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
E2E_SITE="${E2E_SITE:-obs.e2enetworks.net}"
API_BASE="https://${E2E_SITE}"
INSTALL_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

COLLECTOR_IMAGE="registry.e2enetworks.net/dakshmanuarya_2026/e2e-otel-collector@sha256:b97460ef001cc6315885a9d73422f93ee2dd50579150e49db8b5b965e7d5e883"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo -e "${BOLD}[e2e-collector]${RESET} $*"; }
ok()     { echo -e "${GREEN}[e2e-collector]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[e2e-collector] WARNING:${RESET} $*"; }
die()    { echo -e "${RED}[e2e-collector] ERROR:${RESET} $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Please install it and retry."
}

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root (or via sudo)."
[[ -n "${E2E_API_KEY:-}" ]]      || die "E2E_API_KEY is not set.\n\nGet your API key from: https://myaccount.e2enetworks.com/services/apiiam\nThen run:\n  E2E_API_KEY=<key> E2E_PROJECT_ID=<project-id> E2E_CUSTOMER_ID=<customer-id> bash -c \"\$(curl -L ${API_BASE}/install/vm.sh)\""
[[ -n "${E2E_PROJECT_ID:-}" ]]   || die "E2E_PROJECT_ID is not set.\n\nFind your Project ID in MyAccount → Projects.\nThen run:\n  E2E_API_KEY=<key> E2E_PROJECT_ID=<project-id> E2E_CUSTOMER_ID=<customer-id> bash -c \"\$(curl -L ${API_BASE}/install/vm.sh)\""
[[ -n "${E2E_CUSTOMER_ID:-}" ]]  || die "E2E_CUSTOMER_ID is not set.\n\nFind your Customer ID in MyAccount → Profile.\nThen run:\n  E2E_API_KEY=<key> E2E_PROJECT_ID=<project-id> E2E_CUSTOMER_ID=<customer-id> bash -c \"\$(curl -L ${API_BASE}/install/vm.sh)\""

require_cmd curl
require_cmd systemctl
require_cmd docker

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   E2E Observability Agent — Linux VM Installer   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Detect OS ─────────────────────────────────────────────────────────
log "Step 1/5 — Detecting platform..."

OS_ID=""
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release && echo "${ID}")
fi

ok "Platform: ${OS_ID:-linux} / $(uname -m)"

# ── Step 2: Register with E2E Observability API ───────────────────────────────
log "Step 2/5 — Registering with E2E Observability..."

REGISTER_RESPONSE=$(curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"${E2E_API_KEY}\", \"project_id\": ${E2E_PROJECT_ID}, \"customer_id\": ${E2E_CUSTOMER_ID}, \"resource_type\": \"vm\"}" \
    "${API_BASE}/v1/install/register" 2>&1) || {
    die "Failed to reach E2E Observability API at ${API_BASE}.\nCheck your network connectivity and try again."
}

# Parse response fields (handles both compact and spaced JSON)
INGESTION_TOKEN=$(echo "$REGISTER_RESPONSE" | sed 's/.*"ingestion_token" *: *"\([^"]*\)".*/\1/' | grep -v '^{')
PROJECT_ID="${E2E_PROJECT_ID}"
LOG_GROUP=$(echo "$REGISTER_RESPONSE" | sed 's/.*"log_group" *: *"\([^"]*\)".*/\1/' | grep -v '^{')

if [[ -z "$INGESTION_TOKEN" ]]; then
    if echo "$REGISTER_RESPONSE" | grep -qi "invalid\|unauthorized\|expired"; then
        die "API key rejected. Confirm your key has WRITE capability in MyAccount → API IAM."
    fi
    die "Unexpected response from registration API:\n${REGISTER_RESPONSE}"
fi

ok "Registered successfully"
ok "  Project ID : ${PROJECT_ID}"
ok "  Log group  : ${LOG_GROUP}"

# ── Step 3: Pull collector image ──────────────────────────────────────────────
log "Step 3/5 — Pulling e2e-otel-collector image..."

docker pull "${COLLECTOR_IMAGE}" || die "Failed to pull collector image from registry."

ok "Image pulled: ${COLLECTOR_IMAGE%%@*}"

# ── Step 4: Write config and env file ─────────────────────────────────────────
log "Step 4/5 — Writing configuration..."

HOST_NAME=$(hostname -f 2>/dev/null || hostname)
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "${DATA_DIR}/tmp"

# Write the env file — passed to the container at runtime
cat > "${INSTALL_DIR}/env" <<EOF
# E2E Observability Agent — environment variables
# Do not edit manually. Re-run the install script to update.
E2E_TOKEN=${INGESTION_TOKEN}
HOST_NAME=${HOST_NAME}
E2E_LOG_GROUP=${LOG_GROUP}
E2E_PROJECT_ID=${PROJECT_ID}
E2E_ENV=${E2E_ENV:-}
EOF
chmod 600 "${INSTALL_DIR}/env"

# Download the collector config template from the API
curl -fsL -o "${INSTALL_DIR}/config.yaml" \
    "${API_BASE}/install/vm-config.yaml" 2>/dev/null || {
    warn "Could not download config template from ${API_BASE}. Using bundled default."
    cat > "${INSTALL_DIR}/config.yaml" <<'YAML'
extensions:
  health_check:
    endpoint: "0.0.0.0:13133"
  file_storage:
    directory: /var/lib/e2e-otel-collector
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/e2e-otel-collector/tmp

receivers:
  journald:
    directory: /run/log/journal
    priority: info
    operators:
      - type: copy
        from: body.SYSLOG_IDENTIFIER
        to: attributes["service.name"]
        if: 'body["SYSLOG_IDENTIFIER"] != nil'
      - type: copy
        from: body.PRIORITY
        to: attributes["syslog.priority"]
        if: 'body["PRIORITY"] != nil'
      - type: copy
        from: body._SYSTEMD_UNIT
        to: attributes["systemd.unit"]
        if: 'body["_SYSTEMD_UNIT"] != nil'
      - type: move
        from: body.MESSAGE
        to: body
        if: 'body["MESSAGE"] != nil'
      - type: add
        field: resource["host.name"]
        value: "${env:HOST_NAME}"

  filelog/syslog:
    include:
      - /var/log/messages
      - /var/log/secure
    start_at: end
    storage: file_storage
    include_file_path: true
    include_file_name: false
    multiline:
      line_start_pattern: '^[A-Z][a-z]{2} +[0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}'
    operators:
      - type: add
        field: resource["host.name"]
        value: "${env:HOST_NAME}"

  filelog/app:
    include:
      - /var/log/app/*.log
      - /var/log/python/*.log
      - /root/app/*.log
      - /opt/app/*.log
    start_at: end
    storage: file_storage
    include_file_path: true
    include_file_name: false
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}'
    operators:
      - type: add
        field: resource["host.name"]
        value: "${env:HOST_NAME}"

  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      disk: {}
      network: {}
      load: {}
      filesystem:
        exclude_mount_points:
          mount_points: ["/dev/*", "/proc/*", "/sys/*"]
          match_type: regexp
        exclude_fs_types:
          fs_types: [autofs, binfmt_misc, bpf, cgroup2, configfs, debugfs,
                     devpts, devtmpfs, fusectl, hugetlbfs, mqueue, nsfs,
                     overlay, proc, procfs, pstore, securityfs, sysfs]
          match_type: strict

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 200
    spike_limit_mib: 50

  resource/node:
    attributes:
      - key: host.name
        value: "${env:HOST_NAME}"
        action: upsert
      - key: log_group
        value: "${env:E2E_LOG_GROUP}"
        action: upsert
      - key: project_id
        value: "${env:E2E_PROJECT_ID}"
        action: upsert

  batch:
    timeout: 1s
    send_batch_size: 512
    send_batch_max_size: 1024

exporters:
  otlp/gateway:
    endpoint: "172.16.230.168:31318"
    tls:
      insecure: true
    headers:
      authorization: "Bearer ${env:E2E_TOKEN}"
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  extensions: [health_check, file_storage]
  pipelines:
    metrics/infrastructure:
      receivers: [hostmetrics]
      processors: [memory_limiter, resource/node, batch]
      exporters: [otlp/gateway]
    logs:
      receivers: [journald, filelog/syslog, filelog/app]
      processors: [memory_limiter, resource/node, batch]
      exporters: [otlp/gateway]
YAML
}

ok "Configuration written to ${INSTALL_DIR}/"

# ── Step 5: Create and start systemd service ──────────────────────────────────
log "Step 5/5 — Installing systemd service..."

# Remove any old container so the service can always docker run fresh
docker rm -f "${SERVICE_NAME}" 2>/dev/null || true

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=E2E Observability Agent
Documentation=https://docs.e2enetworks.com/observability
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=3
ExecStartPre=-/usr/bin/docker rm -f ${SERVICE_NAME}
ExecStart=/usr/bin/docker run --rm --name ${SERVICE_NAME} \
  --env-file ${INSTALL_DIR}/env \
  --network host \
  --pid host \
  -v ${INSTALL_DIR}/config.yaml:/etc/otelcol/config.yaml:ro \
  -v ${DATA_DIR}:/var/lib/e2e-otel-collector \
  -v /var/log:/var/log:ro \
  -v /run/log/journal:/run/log/journal:ro \
  ${COLLECTOR_IMAGE}
ExecStop=/usr/bin/docker stop ${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" --quiet

log "Step 5/5 — Starting agent..."

if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl restart "$SERVICE_NAME"
    ok "Agent restarted"
else
    systemctl start "$SERVICE_NAME"
    ok "Agent started"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   E2E Observability Agent installed and running  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Project ID :${RESET} ${PROJECT_ID}"
echo -e "  ${BOLD}Log group  :${RESET} ${LOG_GROUP}"
echo -e "  ${BOLD}Host       :${RESET} ${HOST_NAME}"
echo ""
echo -e "  Verify: ${BOLD}systemctl status ${SERVICE_NAME}${RESET}"
echo -e "  Logs:   ${BOLD}journalctl -u ${SERVICE_NAME} -f${RESET}"
echo -e "  Health: ${BOLD}curl -s http://localhost:13133${RESET}"
echo ""
echo -e "  Data will appear in your dashboard within 2 minutes."
echo -e "  Dashboard: ${BOLD}https://${E2E_SITE}/dashboard${RESET}"
echo ""
