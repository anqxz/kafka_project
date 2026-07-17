#!/bin/bash

# Script para gerenciar o S3 Sink Connector
# Uso: ./s3-connector.sh [comando]

CONNECT_URL="http://localhost:8083"
CONNECTOR_NAME="s3-sink-connector"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Aguardar Kafka Connect
wait_connect() {
    echo -e "${YELLOW}Aguardando Kafka Connect...${NC}"
    until curl -s -f -o /dev/null "${CONNECT_URL}"; do
        printf '.'
        sleep 2
    done
    echo -e "\n${GREEN}✓ Kafka Connect pronto!${NC}"
}

# Criar conector
create() {
    echo -e "${YELLOW}Criando S3 Sink Connector...${NC}"
    wait_connect
    
    curl -s -X POST \
        -H "Content-Type: application/json" \
        --data @s3-sink-connector.json \
        "${CONNECT_URL}/connectors" | jq '.'
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Conector criado!${NC}"
    else
        echo -e "${RED}✗ Erro ao criar conector${NC}"
    fi
}

# Status do conector
status() {
    echo -e "${YELLOW}Status do conector:${NC}"
    curl -s "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | jq '.'
}

# Listar conectores
list() {
    echo -e "${YELLOW}Conectores disponíveis:${NC}"
    curl -s "${CONNECT_URL}/connectors" | jq '.'
}

# Deletar conector
delete() {
    echo -e "${YELLOW}Deletando conector...${NC}"
    curl -s -X DELETE "${CONNECT_URL}/connectors/${CONNECTOR_NAME}"
    echo -e "${GREEN}✓ Conector deletado${NC}"
}

# Restart conector
restart() {
    echo -e "${YELLOW}Reiniciando conector...${NC}"
    curl -s -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/restart"
    echo -e "${GREEN}✓ Conector reiniciado${NC}"
}

# Ver arquivos no S3
show_s3() {
    echo -e "${YELLOW}Arquivos no bucket S3:${NC}"
    docker exec -it localstack awslocal s3 ls s3://kafka-events-bucket/ --recursive
}

# Baixar arquivo do S3
download_s3() {
    FILE=$1
    if [ -z "$FILE" ]; then
        echo -e "${RED}Uso: $0 download <caminho-do-arquivo>${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Baixando arquivo...${NC}"
    docker exec -it localstack awslocal s3 cp "s3://kafka-events-bucket/${FILE}" /tmp/
    docker cp localstack:/tmp/$(basename $FILE) .
    echo -e "${GREEN}✓ Arquivo baixado: $(basename $FILE)${NC}"
}

# Ajuda
help() {
    echo -e "${GREEN}=== S3 Connector Manager ===${NC}"
    echo ""
    echo "Comandos:"
    echo "  create      - Criar o S3 Sink Connector"
    echo "  status      - Ver status do conector"
    echo "  list        - Listar todos os conectores"
    echo "  delete      - Deletar o conector"
    echo "  restart     - Reiniciar o conector"
    echo "  show-s3     - Listar arquivos no S3"
    echo "  download    - Baixar arquivo do S3"
    echo "  help        - Mostrar esta ajuda"
    echo ""
    echo "Exemplos:"
    echo "  $0 create"
    echo "  $0 status"
    echo "  $0 show-s3"
}

case "$1" in
    create)
        create
        ;;
    status)
        status
        ;;
    list)
        list
        ;;
    delete)
        delete
        ;;
    restart)
        restart
        ;;
    show-s3)
        show_s3
        ;;
    download)
        download_s3 "$2"
        ;;
    help|--help|-h|"")
        help
        ;;
    *)
        echo -e "${RED}Comando inválido: $1${NC}"
        help
        exit 1
        ;;
esac
