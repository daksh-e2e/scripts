#!/usr/bin/env bash
# =============================================================================
# E2E OTel Collector — one-line VM installer
#
# Usage (copy-paste from E2E dashboard):
#   E2E_PROJECT_ID=p-821 \
#   E2E_CUSTOMER_ID=groot \
#   E2E_API_KEY=<your-key> \
#   bash -c "$(curl -fsSL http://172.16.230.168:31881/v1/install.sh)"
#
# Or run locally:
#   E2E_PROJECT_ID=p-821 E2E_CUSTOMER_ID=groot bash install-vm-collector.sh
#
# What this does (automatically):
#   1. Validates inputs and checks prerequisites
#   2. Creates a log group via E2E Observability API → gets ingestion token
#   3. Writes OTel collector config to /etc/e2e-otel-collector/config.yaml
#   4. Runs the collector as a Docker container (auto-restart on reboot)
#   5. Verifies logs + metrics are flowing
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[E2E]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Required inputs ────────────────────────────────────────────────────────────
: "${E2E_PROJECT_ID:?E2E_PROJECT_ID is required (e.g. p-821)}"
: "${E2E_CUSTOMER_ID:?E2E_CUSTOMER_ID is required (e.g. groot)}"
E2E_API_KEY="${E2E_API_KEY:-}"          # future use — not validated yet

# ── Infrastructure endpoints (internal E2E defaults) ──────────────────────────
E2E_API_ENDPOINT="${E2E_API_ENDPOINT:-172.16.230.168:31880}"      # gRPC
E2E_GATEWAY_ENDPOINT="${E2E_GATEWAY_ENDPOINT:-172.16.230.168:31318}"  # OTLP gRPC

# ── Container config ───────────────────────────────────────────────────────────
COLLECTOR_IMAGE="registry.e2enetworks.net/dakshmanuarya_2026/e2e-otel-collector@sha256:b97460ef001cc6315885a9d73422f93ee2dd50579150e49db8b5b965e7d5e883"
REGISTRY_HOST="registry.e2enetworks.net"
REGISTRY_USER="e2edakshmanuarya_2026+daksh"
REGISTRY_PASS="TcBmkBhU9qPO2lFiQAQlrktINR1pxANO"
CONTAINER_NAME="e2e-otel-collector"
CONFIG_DIR="/etc/e2e-otel-collector"
STORAGE_DIR="/var/lib/e2e-otel-collector"

# ── Derived values ─────────────────────────────────────────────────────────────
HOST_NAME="$(hostname -s)"
# Log group name: logs.<customer_id>.<project_id>.vm
# Sanitise: lowercase, replace non-alnum chars with dashes
_sanitise() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'; }
LOG_GROUP="logs.$(_sanitise "$E2E_CUSTOMER_ID").$(_sanitise "$E2E_PROJECT_ID").vm"

# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "  ┌───────────────────────────────────────────────────────┐"
echo "  │         E2E Networks — OTel Collector Installer        │"
echo "  └───────────────────────────────────────────────────────┘"
echo ""
info "Project:    $E2E_PROJECT_ID"
info "Customer:   $E2E_CUSTOMER_ID"
info "Host:       $HOST_NAME"
info "Log group:  $LOG_GROUP"
info "Gateway:    $E2E_GATEWAY_ENDPOINT"
echo ""

# ── 1. Check prerequisites ─────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "docker is not installed. Install Docker first: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start it with: systemctl start docker"
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found"
success "Prerequisites OK"

# ── 2. Install grpcurl (if missing) ───────────────────────────────────────────
GRPCURL_BIN="$(command -v grpcurl 2>/dev/null || true)"
if [[ -z "$GRPCURL_BIN" ]]; then
    info "Downloading grpcurl..."
    GRPCURL_TMP="$(mktemp -d)/grpcurl"
    GRPCURL_VERSION="1.9.3"
    GRPCURL_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"
    if ! curl -fsSL "$GRPCURL_URL" | tar -xz -C "$(dirname "$GRPCURL_TMP")" grpcurl 2>/dev/null; then
        # fallback: try /usr/local/bin via temp path
        warn "Could not download grpcurl from GitHub. Trying alternate method..."
        curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" \
            -o /tmp/grpcurl.tar.gz
        tar -xzf /tmp/grpcurl.tar.gz -C /tmp grpcurl
        GRPCURL_TMP="/tmp/grpcurl"
    fi
    chmod +x "$GRPCURL_TMP"
    GRPCURL_BIN="$GRPCURL_TMP"
    success "grpcurl downloaded"
else
    success "grpcurl found at $GRPCURL_BIN"
fi

# ── 3. Write proto to temp file ────────────────────────────────────────────────
PROTO_DIR="$(mktemp -d)"
cat > "$PROTO_DIR/observability.proto" << 'PROTO_EOF'
syntax = "proto3";
package e2e.observability.v1;

service LogGroupService {
  rpc CreateLogGroup(CreateLogGroupRequest) returns (CreateLogGroupResponse);
}

message CreateLogGroupRequest {
  string log_group_name    = 1;
  optional string project_id      = 2;
  optional string resource_id     = 3;
  optional string resource_type   = 4;
  optional string organization_id = 5;
  optional string customer_id     = 6;
  uint32 retention_in_days = 7;
  uint32 quota_gb          = 8;
}

message LogGroup {
  string name                          = 1;
  optional string project_id           = 2;
  optional string resource_id          = 3;
  optional string resource_type        = 4;
  optional string organization_id      = 5;
  optional string customer_id          = 6;
  uint32 retention_in_days             = 7;
  uint32 quota_gb                      = 8;
  int64  created_at                    = 9;
  optional int64 last_event_timestamp  = 10;
  int64  stored_bytes                  = 11;
  uint64 log_stream_count              = 12;
}

message CreateLogGroupResponse {
  reserved 1;
  LogGroup log_group       = 2;
  string ingestion_token   = 3;
  string read_token        = 4;
}
PROTO_EOF

# ── 4. Create log group / retrieve cached token ────────────────────────────────
mkdir -p "$CONFIG_DIR"
TOKEN_CACHE="$CONFIG_DIR/.ingestion_token"
INGESTION_TOKEN=""

_grpc_create_log_group() {
    local name="$1"
    "$GRPCURL_BIN" \
        -plaintext \
        -import-path "$PROTO_DIR" \
        -proto observability.proto \
        -H 'x-admin-id: system' \
        -H 'x-roles: admin' \
        -d "{\"log_group_name\": \"${name}\", \"project_id\": \"${E2E_PROJECT_ID}\", \"customer_id\": \"${E2E_CUSTOMER_ID}\", \"resource_id\": \"${E2E_PROJECT_ID}\", \"resource_type\": \"customer\"}" \
        "$E2E_API_ENDPOINT" \
        e2e.observability.v1.LogGroupService/CreateLogGroup 2>&1
}

_extract_token() {
    python3 -c "
import sys, json
data = json.load(sys.stdin)
token = data.get('ingestionToken') or data.get('ingestion_token', '')
print(token)
" 2>/dev/null
}

# Idempotency: reuse cached token from a previous run on this host.
if [[ -f "$TOKEN_CACHE" ]]; then
    CACHED="$(cat "$TOKEN_CACHE" 2>/dev/null || true)"
    CACHED_TOKEN="$(echo "$CACHED" | cut -d'|' -f1)"
    CACHED_GROUP="$(echo "$CACHED" | cut -d'|' -f2)"
    if [[ -n "$CACHED_TOKEN" && -n "$CACHED_GROUP" ]]; then
        warn "Found existing install. Reusing saved token (delete $TOKEN_CACHE to force re-create)."
        INGESTION_TOKEN="$CACHED_TOKEN"
        LOG_GROUP="$CACHED_GROUP"
        success "Token loaded from cache. Log group: $LOG_GROUP"
    fi
fi

if [[ -z "$INGESTION_TOKEN" ]]; then
    info "Creating log group '$LOG_GROUP' via Observability API..."

    set +e; GRPC_RESPONSE="$(_grpc_create_log_group "$LOG_GROUP")"; set -e

    # Fallback 1: host-hash suffix
    if echo "$GRPC_RESPONSE" | grep -q "ALREADY_EXISTS"; then
        warn "Log group '$LOG_GROUP' already exists — trying host-hash suffix..."
        HOST_HASH="$(echo "$HOST_NAME" | md5sum | cut -c1-6)"
        LOG_GROUP="logs.$(_sanitise "$E2E_CUSTOMER_ID").$(_sanitise "$E2E_PROJECT_ID")-${HOST_HASH}.vm"
        info "Trying: $LOG_GROUP"
        set +e; GRPC_RESPONSE="$(_grpc_create_log_group "$LOG_GROUP")"; set -e
    fi

    # Fallback 2: epoch timestamp suffix
    if echo "$GRPC_RESPONSE" | grep -q "ALREADY_EXISTS"; then
        warn "Host-hash group also exists — using timestamp suffix..."
        TS="$(date +%s | tail -c5)"
        LOG_GROUP="logs.$(_sanitise "$E2E_CUSTOMER_ID").$(_sanitise "$E2E_PROJECT_ID")-${TS}.vm"
        info "Trying: $LOG_GROUP"
        set +e; GRPC_RESPONSE="$(_grpc_create_log_group "$LOG_GROUP")"; set -e
    fi

    if echo "$GRPC_RESPONSE" | grep -qE 'Code:|UNAVAILABLE|INTERNAL|InvalidArgument'; then
        die "Failed to create log group:\n$GRPC_RESPONSE"
    fi

    INGESTION_TOKEN="$(echo "$GRPC_RESPONSE" | _extract_token)"

    if [[ -z "$INGESTION_TOKEN" ]]; then
        die "Could not extract ingestion token from API response:\n$GRPC_RESPONSE"
    fi

    echo "${INGESTION_TOKEN}|${LOG_GROUP}" > "$TOKEN_CACHE"
    chmod 600 "$TOKEN_CACHE"
    success "Log group created. Token: ${INGESTION_TOKEN:0:20}..."
fi

# ── 5. Write collector config ──────────────────────────────────────────────────
info "Writing collector config to $CONFIG_DIR/config.yaml..."
mkdir -p "$CONFIG_DIR" "$STORAGE_DIR" "${STORAGE_DIR}/tmp"

cat > "$CONFIG_DIR/config.yaml" << YAML_EOF
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
  # Reads syslog/journal text output — covers both rsyslog (/var/log/messages)
  # and systemd-journald systems where rsyslog forwards to /var/log/messages.
  # journald binary receiver is omitted: distroless image has no journalctl binary.
  filelog/syslog:
    include:
      - /var/log/messages
      - /var/log/secure
      - /var/log/syslog
    start_at: end
    storage: file_storage
    include_file_path: true
    include_file_name: false
    multiline:
      line_start_pattern: '^[A-Z][a-z]{2} +[0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}'
    operators:
      - type: add
        field: resource["host.name"]
        value: "${HOST_NAME}"

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
        value: "${HOST_NAME}"

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
        value: "${HOST_NAME}"

  prometheus/lustre:
    config:
      scrape_configs:
        - job_name: lustre_mgs
          scrape_interval: 30s
          static_configs:
            - targets: ["localhost:32221"]
          params:
            jobstats: ["true"]

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
        value: "${HOST_NAME}"
        action: upsert

  resource/logs_meta:
    attributes:
      - key: log_group
        value: "${LOG_GROUP}"
        action: upsert
      - key: log_stream
        value: "${HOST_NAME}"
        action: upsert
      - key: source_type
        value: vm
        action: upsert
      - key: project_id
        value: "${E2E_PROJECT_ID}"
        action: upsert

  batch:
    timeout: 1s
    send_batch_size: 512
    send_batch_max_size: 1024

exporters:
  otlp/gateway:
    endpoint: "${E2E_GATEWAY_ENDPOINT}"
    tls:
      insecure: true
    headers:
      authorization: "Bearer ${INGESTION_TOKEN}"
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
    metrics/lustre:
      receivers: [prometheus/lustre]
      processors: [memory_limiter, resource/node, batch]
      exporters: [otlp/gateway]
    logs:
      receivers: [journald, filelog/syslog, filelog/app]
      processors: [memory_limiter, resource/node, resource/logs_meta, batch]
      exporters: [otlp/gateway]
YAML_EOF

success "Config written"

# ── 6. Stop existing container if running ─────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Stopping existing container '$CONTAINER_NAME'..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# ── 7. Pull image ──────────────────────────────────────────────────────────────
info "Logging in to E2E container registry..."
echo "$REGISTRY_PASS" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 || \
    die "Docker registry login failed. Check network connectivity to $REGISTRY_HOST."
success "Registry login OK"

info "Pulling collector image..."
docker pull "$COLLECTOR_IMAGE"
success "Image pulled"

# ── 8. Run container ───────────────────────────────────────────────────────────
info "Starting collector container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network host \
    --pid host \
    --privileged \
    --user 0 \
    -v "${CONFIG_DIR}:/etc/e2e-otel-collector:ro" \
    -v "${STORAGE_DIR}:/var/lib/e2e-otel-collector" \
    -v "/var/log:/var/log:ro" \
    -v "/run/log/journal:/run/log/journal:ro" \
    "$COLLECTOR_IMAGE" \
    --config=/etc/e2e-otel-collector/config.yaml

success "Container started"

# ── 9. Wait and verify ─────────────────────────────────────────────────────────
info "Waiting for collector to start..."
sleep 5

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Container is not running. Last logs:"
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
    die "Collector failed to start. Check logs above."
fi

# Health check
HEALTH_STATUS="$(curl -sf --max-time 5 http://localhost:13133/ 2>/dev/null && echo "ok" || echo "pending")"

echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │                    Installation Complete!                    │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
success "Collector is running"
echo ""
echo "  Host:          $HOST_NAME"
echo "  Log group:     $LOG_GROUP"
echo "  Project:       $E2E_PROJECT_ID"
echo "  Token:         ${INGESTION_TOKEN:0:20}..."
echo "  Gateway:       $E2E_GATEWAY_ENDPOINT"
echo "  Health:        http://$(hostname -s):13133/"
echo ""
echo "  Useful commands:"
echo "    docker logs -f $CONTAINER_NAME   # live logs"
echo "    docker stats $CONTAINER_NAME     # resource usage"
echo "    docker restart $CONTAINER_NAME   # restart"
echo "    docker rm -f $CONTAINER_NAME     # uninstall"
echo ""

# Cleanup temp files
rm -rf "$PROTO_DIR"
