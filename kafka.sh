#!/bin/bash
# Helper script para executar comandos de qualquer lugar no projeto

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    echo "Kafka Project - Helper Script"
    echo ""
    echo "Uso: ./kafka.sh [comando]"
    echo ""
    echo "Comandos disponíveis:"
    echo ""
    echo "  Cluster:"
    echo "    start              - Inicia o cluster Kafka (todos os serviços)"
    echo "    stop               - Para o cluster Kafka"
    echo "    restart            - Reinicia o cluster Kafka"
    echo "    status             - Mostra status dos containers"
    echo "    logs [service]     - Mostra logs (opcional: especifique o serviço)"
    echo ""
    echo "  Testes:"
    echo "    test-connection    - Testa conectividade Kafka"
    echo "    test-pipeline      - Teste end-to-end Kafka → S3"
    echo ""
    echo "  Producer:"
    echo "    run-producer       - Executa o producer de exemplo"
    echo ""
    echo "  S3 Connector:"
    echo "    connector-create   - Cria o S3 Sink Connector"
    echo "    connector-status   - Mostra status do connector"
    echo "    connector-delete   - Deleta o connector"
    echo "    connector-restart  - Reinicia o connector"
    echo "    connector-list     - Lista todos os connectors"
    echo "    s3-list            - Lista arquivos no S3"
    echo ""
    echo "  Métricas / UIs:"
    echo "    metrics            - Mostra URLs de UIs expostas no host"
    echo ""
    echo "  Ajuda:"
    echo "    help               - Mostra esta mensagem"
    echo ""
}

case "$1" in
    start)
        cd "$SCRIPT_DIR/clusters" && docker compose up -d
        ;;
    stop)
        cd "$SCRIPT_DIR/clusters" && docker compose down
        ;;
    restart)
        cd "$SCRIPT_DIR/clusters" && docker compose restart
        ;;
    status)
        cd "$SCRIPT_DIR/clusters" && docker compose ps
        ;;
    logs)
        cd "$SCRIPT_DIR/clusters"
        if [ -z "$2" ]; then
            docker compose logs -f
        else
            docker compose logs -f "$2"
        fi
        ;;
    test-connection)
        cd "$SCRIPT_DIR/tools" && python3 test_connection.py
        ;;
    test-pipeline)
        cd "$SCRIPT_DIR/tools" && ./test-s3-pipeline.sh
        ;;
    run-producer)
        VENV="$SCRIPT_DIR/.venv"
        if [ ! -x "$VENV/bin/python" ] || [ "$SCRIPT_DIR/requirements.txt" -nt "$VENV/pyvenv.cfg" ]; then
            python3 -m venv "$VENV"
            "$VENV/bin/pip" install --quiet --upgrade pip
            "$VENV/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
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
    connector-create)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh create
        ;;
    connector-status)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh status
        ;;
    connector-delete)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh delete
        ;;
    connector-restart)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh restart
        ;;
    connector-list)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh list
        ;;
    s3-list)
        cd "$SCRIPT_DIR/connects" && ./s3-connector.sh show-s3
        ;;
    metrics)
        echo "UIs expostas no host (127.0.0.1):"
        echo "  Prometheus:      http://localhost:9090"
        echo "  Grafana:         http://localhost:3000 (admin/admin)"
        echo "  AKHQ:            http://localhost:8080"
        echo "  Schema Registry: http://localhost:8081"
        echo "  Kafka Connect:   http://localhost:8083"
        echo "  ntfy:            http://localhost:8082"
        echo "  LocalStack:      http://localhost:4566"
        echo ""
        echo "Kafka bootstrap: localhost:9092,localhost:9093,localhost:9094"
        echo ""
        echo "Nota: JMX exporters (7071-7073), Alertmanager, Loki, Tempo, Pyroscope"
        echo "      não são expostos no host — acessíveis apenas via rede 'observability'."
        ;;
    help|"")
        show_help
        ;;
    *)
        echo "Comando desconhecido: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
