#!/usr/bin/env bash
# Helper for the Kafka + observability stack. Runs from anywhere in the repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/clusters"
compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }

show_help() {
  cat <<'EOF'
Kafka Project — helper

Usage: ./kafka.sh <command> [args]

Stack
  start [svc...]     Start the stack (or specific services)
  stop               Stop and remove containers (volumes kept)
  restart [svc]      Restart the stack or one service
  status             Show container status
  logs [svc]         Tail logs (all services if svc omitted)
  build [svc...]     Rebuild image(s); all services if none given
  rebuild [svc...]   build + up -d --force-recreate

Traffic
  run-loadgen        Start the containerized loadgen service (compose up)
  stop-loadgen       Stop the loadgen container
  run-producer       One-shot host-side producer (uses .venv, OTel wired)

Connectors (S3 sink)
  connector-create | connector-status | connector-restart
  connector-delete  | connector-list   | s3-list

Tests
  test-connection    Ping brokers from tools/
  test-pipeline      End-to-end Kafka → S3 test

Diagnostics
  ui                 Print every host-exposed UI + Kafka bootstrap
  doctor             Check podman backend + DNS + OTLP endpoint

  help               This message
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  start)         compose up -d "$@" ;;
  stop)          compose down ;;
  restart)       compose restart "$@" ;;
  status)        compose ps ;;
  logs)          compose logs -f "$@" ;;
  build)         compose build "$@" ;;
  rebuild)       compose build "$@" && compose up -d --force-recreate "$@" ;;

  run-loadgen)   compose up -d loadgen ;;
  stop-loadgen)  compose stop loadgen ;;

  run-producer)
    VENV="$SCRIPT_DIR/.venv"
    REQS="$SCRIPT_DIR/requirements.txt"
    if [ ! -x "$VENV/bin/python" ] || [ "$REQS" -nt "$VENV/pyvenv.cfg" ]; then
      python3 -m venv "$VENV"
      "$VENV/bin/pip" install --quiet --upgrade pip
      "$VENV/bin/pip" install --quiet -r "$REQS"
      touch "$VENV/pyvenv.cfg"
    fi
    cd "$SCRIPT_DIR/producers"
    export OTEL_SERVICE_NAME=kafka-producer
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
    export OTEL_TRACES_EXPORTER=otlp
    export OTEL_LOGS_EXPORTER=otlp
    export OTEL_METRICS_EXPORTER=none
    export OTEL_PYTHON_LOG_CORRELATION=true
    export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
    "$VENV/bin/opentelemetry-instrument" "$VENV/bin/python" producer_example.py
    ;;

  connector-create)  cd "$SCRIPT_DIR/connects" && ./s3-connector.sh create ;;
  connector-status)  cd "$SCRIPT_DIR/connects" && ./s3-connector.sh status ;;
  connector-delete)  cd "$SCRIPT_DIR/connects" && ./s3-connector.sh delete ;;
  connector-restart) cd "$SCRIPT_DIR/connects" && ./s3-connector.sh restart ;;
  connector-list)    cd "$SCRIPT_DIR/connects" && ./s3-connector.sh list ;;
  s3-list)           cd "$SCRIPT_DIR/connects" && ./s3-connector.sh show-s3 ;;

  test-connection)   cd "$SCRIPT_DIR/tools" && python3 test_connection.py ;;
  test-pipeline)     cd "$SCRIPT_DIR/tools" && ./test-s3-pipeline.sh ;;

  ui)
    cat <<'EOF'
Host-exposed UIs (127.0.0.1):
  AKHQ (Kafka admin)   http://localhost:8080
  Schema Registry      http://localhost:8081
  Kafka Connect REST   http://localhost:8083
  Cruise Control REST  http://localhost:9095
  Kroxylicious proxy   localhost:9192 (Kafka protocol)
  Toxiproxy API        http://localhost:8474
  MCP-Kafka (SSE)      http://localhost:3001
  ntfy                 http://localhost:8082
  LocalStack (AWS)     http://localhost:4566
  Prometheus           http://localhost:9090
  Grafana              http://localhost:3000 (admin/admin)
  OTLP (host push)     http://localhost:4317 (gRPC), http://localhost:4318 (HTTP)

Kafka bootstrap:       localhost:9092,localhost:9093,localhost:9094

Cluster-internal only (reach via docker exec or Grafana):
  Loki 3100, Tempo 3200, Pyroscope 4040, Alertmanager 9093, Blackbox 9115,
  JMX exporter :7071 on every JVM.
EOF
    ;;

  doctor)
    printf 'podman backend : ' ; podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo missing
    printf 'aardvark-dns   : ' ; dpkg-query -W -f='${Status}\n' aardvark-dns 2>/dev/null | grep -q 'install ok installed' && echo installed || echo MISSING
    printf 'netavark       : ' ; dpkg-query -W -f='${Status}\n' netavark      2>/dev/null | grep -q 'install ok installed' && echo installed || echo MISSING
    printf 'docker CLI     : ' ; docker version --format '{{.Server.Version}}' 2>/dev/null || echo unreachable
    printf 'compose        : ' ; docker compose version --short 2>/dev/null || echo missing
    printf 'OTLP HTTP :4318: ' ; curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4318/v1/traces -X POST -H 'content-type: application/json' -d '{"resourceSpans":[]}' 2>/dev/null || echo down
    printf 'Grafana   :3000: ' ; curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/api/health 2>/dev/null || echo down
    printf 'Broker    :9092: ' ; timeout 2 bash -c '</dev/tcp/127.0.0.1/9092' 2>/dev/null && echo open || echo closed
    ;;

  help|-h|--help|"") show_help ;;
  *) echo "Unknown command: $cmd" >&2; show_help; exit 1 ;;
esac
