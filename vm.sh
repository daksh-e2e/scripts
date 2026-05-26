#!/usr/bin/env bash
# =============================================================================
# E2E Observability Agent — VM install script
# =============================================================================
#
# Usage (one command, no Docker required):
#   E2E_API_KEY=<key> E2E_PROJECT_ID=<id> E2E_CUSTOMER_ID=<id> \
#     bash -c "$(curl -L https://obs.e2enetworks.net/install/vm.sh)"
#
# Optional env vars:
#   E2E_ENV=production                       — environment label (shown in dashboards)
#   E2E_SITE=obs.e2enetworks.net             — override the default API endpoint
#   E2E_API_BASE=http://172.16.230.168:31881 — override the API base URL (testing)
#   E2E_COLLECTOR_VERSION=0.10.0             — pin a specific collector version
#   E2E_BINARY_URL=http://host:port/otelcol  — use a custom binary URL (testing)
#
# Supports: Ubuntu 20.04+, Debian 11+, AlmaLinux/RHEL 8+
# Requires: curl, systemd — nothing else
# =============================================================================

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
E2E_SITE="${E2E_SITE:-obs.e2enetworks.net}"
API_BASE="${E2E_API_BASE:-https://${E2E_SITE}}"
COLLECTOR_VERSION="${E2E_COLLECTOR_VERSION:-0.152.1}"
CDN_BASE="https://observability.objectstore.e2enetworks.net"

INSTALL_DIR="/etc/e2e-otel-collector"
DATA_DIR="/var/lib/e2e-otel-collector"
BINARY_PATH="/usr/local/bin/e2e-otelcol"
SERVICE_NAME="e2e-otel-collector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo -e "${BOLD}[e2e-collector]${RESET} $*"; }
ok()   { echo -e "${GREEN}[e2e-collector]${RESET} $*"; }
warn() { echo -e "${YELLOW}[e2e-collector] WARNING:${RESET} $*"; }
die()  { echo -e "${RED}[e2e-collector] ERROR:${RESET} $*" >&2; exit 1; }

# ── Preflight ──────────────────────────────────────────────────────────────────
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root or via sudo."
command -v curl     >/dev/null 2>&1 || die "'curl' is required but not installed."
command -v systemctl >/dev/null 2>&1 || die "'systemctl' is required. This script requires a systemd-based OS."

[[ -n "${E2E_API_KEY:-}" ]]     || die "E2E_API_KEY is not set.\n\nGet your key from: https://myaccount.e2enetworks.com/services/apiiam\nThen run:\n  E2E_API_KEY=<key> E2E_PROJECT_ID=<id> E2E_CUSTOMER_ID=<id> bash -c \"\$(curl -L ${API_BASE}/install/vm.sh)\""
[[ -n "${E2E_PROJECT_ID:-}" ]]  || die "E2E_PROJECT_ID is not set.\n\nFind it in MyAccount → Projects."
[[ -n "${E2E_CUSTOMER_ID:-}" ]] || die "E2E_CUSTOMER_ID is not set.\n\nFind it in MyAccount → Profile."

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   E2E Observability Agent — Linux VM Installer   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Detect platform ────────────────────────────────────────────────────
log "Step 1/4 — Detecting platform..."

OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-linux}")
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "Unsupported architecture: ${ARCH_RAW}. Contact support." ;;
esac

ok "Platform: ${OS_ID} / ${ARCH_RAW}"

# ── Step 2: Register with E2E Observability ────────────────────────────────────
log "Step 2/4 — Registering with E2E Observability..."

REGISTER_RESPONSE=$(curl -sf --retry 3 --retry-delay 2 --retry-all-errors \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"${E2E_API_KEY}\", \"project_id\": ${E2E_PROJECT_ID}, \"customer_id\": ${E2E_CUSTOMER_ID}, \"resource_type\": \"vm\"}" \
    "${API_BASE}/v1/install/register" 2>&1) || {
  die "Failed to reach E2E Observability API at ${API_BASE}.\nCheck your network and try again."
}

INGESTION_TOKEN=$(echo "$REGISTER_RESPONSE" | sed 's/.*"ingestion_token" *: *"\([^"]*\)".*/\1/' | grep -v '^{')
LOG_GROUP=$(echo "$REGISTER_RESPONSE"       | sed 's/.*"log_group" *: *"\([^"]*\)".*/\1/'       | grep -v '^{')

if [[ -z "$INGESTION_TOKEN" ]]; then
  if echo "$REGISTER_RESPONSE" | grep -qi "invalid\|unauthorized\|expired"; then
    die "API key rejected. Confirm the key has WRITE capability in MyAccount → API IAM."
  fi
  die "Unexpected registration response:\n${REGISTER_RESPONSE}"
fi

ok "Registered — project ${E2E_PROJECT_ID}, log group ${LOG_GROUP}"

# ── Step 3: Download collector binary ─────────────────────────────────────────
log "Step 3/4 — Downloading E2E OTel Collector v${COLLECTOR_VERSION} (${ARCH})..."

BINARY_URL="${E2E_BINARY_URL:-${CDN_BASE}/collector/otelcol-linux-${ARCH}}"

# Try configured URL first; fall back to the upstream otelcol-contrib release
if ! curl -fsSL --retry 3 --retry-delay 2 -o "${BINARY_PATH}.tmp" "${BINARY_URL}" 2>/dev/null; then
  warn "CDN download failed — trying upstream otelcol-contrib release..."
  UPSTREAM_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${COLLECTOR_VERSION}/otelcol-contrib_${COLLECTOR_VERSION}_linux_${ARCH}.tar.gz"
  TMPDIR_EXTRACT=$(mktemp -d)
  curl -fsSL --retry 3 --retry-delay 2 -o "${TMPDIR_EXTRACT}/otelcol.tar.gz" "${UPSTREAM_URL}" \
    || die "Could not download collector binary from CDN or upstream.\nCheck network and try again."
  tar -xzf "${TMPDIR_EXTRACT}/otelcol.tar.gz" -C "${TMPDIR_EXTRACT}"
  mv "${TMPDIR_EXTRACT}/otelcol-contrib" "${BINARY_PATH}.tmp"
  rm -rf "${TMPDIR_EXTRACT}"
fi

chmod +x "${BINARY_PATH}.tmp"
mv "${BINARY_PATH}.tmp" "${BINARY_PATH}"
ok "Installed binary: ${BINARY_PATH}  ($(${BINARY_PATH} --version 2>/dev/null || echo 'ok'))"

# ── Step 4: Write config + env, install service ────────────────────────────────
log "Step 4/4 — Writing configuration and installing service..."

HOST_NAME=$(hostname -f 2>/dev/null || hostname)
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "${DATA_DIR}/tmp"

# Env file — read by the systemd service at start
cat > "${INSTALL_DIR}/env" <<EOF
E2E_TOKEN=${INGESTION_TOKEN}
HOST_NAME=${HOST_NAME}
E2E_LOG_GROUP=${LOG_GROUP}
E2E_PROJECT_ID=${E2E_PROJECT_ID}
E2E_ENV=${E2E_ENV:-}
EOF
chmod 600 "${INSTALL_DIR}/env"

# Collector config — fetch from API; fall back to bundled default
if ! curl -fsL --retry 3 -o "${INSTALL_DIR}/config.yaml" \
    "${API_BASE}/install/vm-config.yaml" 2>/dev/null; then
  warn "Could not fetch config from ${API_BASE} — using bundled default."
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
      - type: move
        from: body.MESSAGE
        to: body
        if: 'body["MESSAGE"] != nil'
      - type: add
        field: resource["host.name"]
        value: "${env:HOST_NAME}"

  filelog/syslog:
    include: [/var/log/messages, /var/log/secure]
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
    include: [/var/log/app/*.log, /var/log/python/*.log, /root/app/*.log, /opt/app/*.log]
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
fi

# Systemd service — runs the binary directly, no Docker
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=E2E Observability Agent
Documentation=https://docs.e2enetworks.com/observability
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${INSTALL_DIR}/env
ExecStart=${BINARY_PATH} --config=${INSTALL_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" --quiet

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  systemctl restart "${SERVICE_NAME}"
  ok "Agent restarted"
else
  systemctl start "${SERVICE_NAME}"
  ok "Agent started"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   E2E Observability Agent installed and running  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Project ID :${RESET} ${E2E_PROJECT_ID}"
echo -e "  ${BOLD}Log group  :${RESET} ${LOG_GROUP}"
echo -e "  ${BOLD}Host       :${RESET} ${HOST_NAME}"
echo ""
echo -e "  ${BOLD}systemctl status ${SERVICE_NAME}${RESET}     — check agent status"
echo -e "  ${BOLD}journalctl -u ${SERVICE_NAME} -f${RESET}  — stream agent logs"
echo -e "  ${BOLD}curl -s http://localhost:13133${RESET}     — health check"
echo ""
echo -e "  Data appears in your dashboard within 2 minutes."
echo -e "  Dashboard: ${BOLD}https://${E2E_SITE}/dashboard${RESET}"
echo ""
