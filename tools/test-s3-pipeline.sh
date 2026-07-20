#!/bin/bash

# Script de teste end-to-end do pipeline Kafka → S3
# Executa um fluxo completo de teste automatizado

set -e

CONNECT_REST_BASIC_USER="${CONNECT_REST_BASIC_USER:-}"
CONNECT_REST_BASIC_PASSWORD="${CONNECT_REST_BASIC_PASSWORD:-}"
_CURL_AUTH=()
if [ -n "$CONNECT_REST_BASIC_USER" ] && [ -n "$CONNECT_REST_BASIC_PASSWORD" ]; then
  _CURL_AUTH=(-u "$CONNECT_REST_BASIC_USER:$CONNECT_REST_BASIC_PASSWORD")
fi

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Teste End-to-End: Kafka → S3 Sink${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Função para aguardar serviço
wait_for_service() {
    local service=$1
    local url=$2
    local max_tries=30
    local count=0
    
    echo -e "${YELLOW}⏳ Aguardando $service...${NC}"
    until curl -s -f -o /dev/null "${_CURL_AUTH[@]}" "$url"; do
        count=$((count + 1))
        if [ $count -ge $max_tries ]; then
            echo -e "${RED}✗ Timeout aguardando $service${NC}"
            exit 1
        fi
        printf '.'
        sleep 2
    done
    echo -e "\n${GREEN}✓ $service pronto!${NC}"
}

# 1. Verificar se os serviços estão rodando
echo -e "${YELLOW}[1/8] Verificando serviços...${NC}"
if ! podman ps | grep -q "Up"; then
    echo -e "${RED}✗ Serviços não estão rodando!${NC}"
    echo -e "${YELLOW}Execute: podman-compose up -d${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Serviços rodando${NC}"
echo ""

# 2. Aguardar Kafka Connect
echo -e "${YELLOW}[2/8] Aguardando Kafka Connect...${NC}"
wait_for_service "Kafka Connect" "http://localhost:8083"
echo ""

# 3. Aguardar LocalStack
echo -e "${YELLOW}[3/8] Aguardando LocalStack...${NC}"
wait_for_service "LocalStack" "http://localhost:4566/_localstack/health"
echo ""

# 4. Criar tópico
echo -e "${YELLOW}[4/8] Criando tópico 'events'...${NC}"
if podman exec --env KAFKA_OPTS='' broker1 sh -c 'kafka-topics --list --bootstrap-server localhost:9092' | grep -q "^events$"; then
    echo -e "${YELLOW}⚠ Tópico 'events' já existe${NC}"
else
    podman exec broker1 kafka-topics --create \
        --bootstrap-server localhost:9092 \
        --topic events \
        --partitions 3 \
        --replication-factor 3 \
        --if-not-exists > /dev/null 2>&1
    echo -e "${GREEN}✓ Tópico criado${NC}"
fi
echo ""

# 5. Criar conector S3 Sink
echo -e "${YELLOW}[5/8] Criando S3 Sink Connector...${NC}"
if curl -s "${_CURL_AUTH[@]}" http://localhost:8083/connectors | grep -q "s3-sink-connector"; then
    echo -e "${YELLOW}⚠ Conector já existe, deletando...${NC}"
    curl -s "${_CURL_AUTH[@]}" -X DELETE http://localhost:8083/connectors/s3-sink-connector > /dev/null
    sleep 2
fi

curl -s "${_CURL_AUTH[@]}" -X POST \
    -H "Content-Type: application/json" \
    --data @../connects/s3-sink-connector.json \
    http://localhost:8083/connectors > /dev/null

# Aguardar conector ficar RUNNING
echo -e "${YELLOW}⏳ Aguardando conector iniciar...${NC}"
sleep 5
STATUS=$(curl -s "${_CURL_AUTH[@]}" http://localhost:8083/connectors/s3-sink-connector/status | jq -r '.connector.state')
if [ "$STATUS" == "RUNNING" ]; then
    echo -e "${GREEN}✓ Conector RUNNING${NC}"
else
    echo -e "${RED}✗ Conector em estado: $STATUS${NC}"
    exit 1
fi
echo ""

# 6. Produzir mensagens de teste
echo -e "${YELLOW}[6/8] Produzindo mensagens de teste...${NC}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for i in {1..5}; do
    MESSAGE="{\"id\":$i,\"type\":\"test_event\",\"message\":\"Test message $i\",\"timestamp\":\"$TIMESTAMP\"}"
    echo "$MESSAGE" | podman exec -i --env KAFKA_OPTS='' broker1 kafka-console-producer \
        --bootstrap-server localhost:9092 \
        --topic events > /dev/null 2>&1
    echo -e "  ${GREEN}✓${NC} Enviada mensagem $i"
done
echo ""


# 7. Aguardar flush e verificar S3
echo -e "${YELLOW}[7/8] Aguardando flush para S3 (15 segundos)...${NC}"
sleep 15

echo -e "${YELLOW}Verificando arquivos no S3...${NC}"
FILES=$(podman exec localstack awslocal s3 ls s3://kafka-events-bucket/ --recursive 2>/dev/null || echo "")

if [ -z "$FILES" ]; then
    echo -e "${RED}✗ Nenhum arquivo encontrado no S3!${NC}"
    echo -e "${YELLOW}Diagnóstico:${NC}"
    echo -e "  1. Verificar status do conector:"
    echo -e "     ./s3-connector.sh status"
    echo -e "  2. Verificar logs:"
    echo -e "     podman-compose logs kafka-connect"
    exit 1
fi

echo -e "${GREEN}✓ Arquivos encontrados no S3:${NC}"
echo "$FILES" | while read -r line; do
    echo -e "  ${BLUE}→${NC} $line"
done
echo ""

# 8. Baixar e validar conteúdo
echo -e "${YELLOW}[8/8] Validando conteúdo dos arquivos...${NC}"

# Pegar primeiro arquivo JSON
FIRST_FILE=$(echo "$FILES" | grep "\.json$" | head -1 | awk '{print $4}')

if [ -z "$FIRST_FILE" ]; then
    echo -e "${RED}✗ Nenhum arquivo JSON encontrado${NC}"
    exit 1
fi

echo -e "${YELLOW}Baixando arquivo: $FIRST_FILE${NC}"
CONTENT=$(podman exec localstack awslocal s3 cp "s3://kafka-events-bucket/$FIRST_FILE" - 2>/dev/null)

if echo "$CONTENT" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓ Arquivo contém JSON válido${NC}"
    echo -e "${BLUE}Primeiras 3 linhas:${NC}"
    echo "$CONTENT" | head -3 | jq -c '.' | while read -r line; do
        echo -e "  ${GREEN}→${NC} $line"
    done
else
    echo -e "${RED}✗ Arquivo não contém JSON válido${NC}"
    exit 1
fi
echo ""

# Resumo
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ TESTE COMPLETO COM SUCESSO!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Resumo:${NC}"
echo -e "  • Kafka Connect: ${GREEN}✓${NC} RUNNING"
echo -e "  • LocalStack S3: ${GREEN}✓${NC} Operacional"
echo -e "  • Tópico 'events': ${GREEN}✓${NC} Criado"
echo -e "  • S3 Sink Connector: ${GREEN}✓${NC} RUNNING"
echo -e "  • Mensagens enviadas: ${GREEN}✓${NC} 5 mensagens"
echo -e "  • Arquivos no S3: ${GREEN}✓${NC} $(echo "$FILES" | wc -l) arquivo(s)"
echo -e "  • Validação JSON: ${GREEN}✓${NC} Sucesso"
echo ""
echo -e "${YELLOW}Próximos passos:${NC}"
echo -e "  • Ver todos os arquivos: ${BLUE}./s3-connector.sh show-s3${NC}"
echo -e "  • Status do conector: ${BLUE}./s3-connector.sh status${NC}"
echo -e "  • Interface AKHQ: ${BLUE}http://localhost:8080${NC}"
echo -e "  • Prometheus: ${BLUE}http://localhost:9090${NC}"
echo ""
