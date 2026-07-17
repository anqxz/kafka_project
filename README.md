# Kafka KRaft Cluster com S3 Sink & Monitoring

Este projeto contém um cluster Kafka completo com KRaft (sem Zookeeper), Kafka Connect S3 Sink, LocalStack para testes S3 locais, e monitoramento via Prometheus.

> 📁 **Estrutura do Projeto**: Este projeto está organizado em pastas modulares. Veja [STRUCTURE.md](STRUCTURE.md) para detalhes da estrutura e use o script helper `./kafka.sh help` para comandos rápidos.

## 🏗️ Arquitetura

### Kafka Cluster
- **3 Controllers** (KRaft): Gerenciam metadados do cluster
  - controller1: porta 19093 (JMX: 19101)
  - controller2: porta 19094 (JMX: 19102)
  - controller3: porta 19095 (JMX: 19103)

- **3 Brokers**: Processam mensagens
  - broker1: porta 9092 (JMX: 9101)
  - broker2: porta 9093 (JMX: 9102)
  - broker3: porta 9094 (JMX: 9103)

### Kafka Connect & S3
- **Kafka Connect**: http://localhost:8083
  - S3 Sink Connector configurado
  - Streaming de tópicos para S3 (LocalStack)
  
- **LocalStack**: http://localhost:4566
  - Emulador AWS S3 local
  - Bucket: `kafka-events-bucket`
  - Sem custos AWS!

### Administração
- **AKHQ**: http://localhost:8080
  - ✅ **Gerenciamento completo** - Topics, Consumers, Configs
  - ✅ **Kafka Connect UI** - Gerenciar conectores visualmente
  - ✅ **Monitoramento JMX** - Métricas de todos os brokers

### Monitoramento
- **Prometheus**: http://localhost:9090
- **JMX direto**: AKHQ acessa JMX diretamente, sem exporters extras!

## ⚙️ Prerequisites (Podman rootless)

This stack is validated on rootless Podman 4.9 (Ubuntu 24.04). Docker Engine works with no extra setup, but Podman needs:

1. **netavark backend + aardvark-dns** (container-to-container DNS is required for `broker*`, `schema-registry`, `kafka-connect`, `loki`, `tempo`, etc. to resolve each other).

   ```bash
   sudo apt install -y netavark aardvark-dns
   mkdir -p ~/.config/containers
   printf '[network]\nnetwork_backend = "netavark"\n' > ~/.config/containers/containers.conf
   echo netavark > ~/.local/share/containers/storage/defaultNetworkBackend
   rm -f ~/.local/share/containers/storage/networks/*.json \
         ~/.local/share/containers/storage/networks/netavark.lock
   systemctl --user restart podman.socket podman.service
   podman info --format '{{.Host.NetworkBackend}}'   # → netavark
   ```

   Without this, containers cannot resolve each other by name (CNI without `dnsname` plugin) and `kafka-connect` / `schema-registry` fail on broker DNS lookup.

2. **After `podman system reset`** — restart the socket before running compose:

   ```bash
   systemctl --user restart podman.socket podman.service
   ```

   Otherwise you'll see `attempt to write a readonly database` from the stale service.

3. **Network `ipam.config`** is set explicitly in `clusters/docker-compose.yml` (compose v5.3.1 crashes with `ParseAddr("<nil>")` on internal bridges when the gateway is left implicit).

## 🚀 Como Usar

### Guia Completo S3 Sink

📖 **Veja o guia detalhado:** [S3-SINK-GUIDE.md](S3-SINK-GUIDE.md)

O guia completo inclui:
- Arquitetura do S3 Sink
- Como produzir mensagens de teste
- Como verificar arquivos no S3
- Gerenciamento de conectores
- Troubleshooting completo

### Início Rápido

```bash
# 1. Subir toda a infraestrutura
cd clusters/
docker compose up -d

# Ou use o helper script:
./kafka.sh start

# 2. Aguardar serviços iniciarem (30-60 segundos)
sleep 60

# 3. Criar tópico 'events'
docker exec -it broker1 kafka-topics --create \
    --bootstrap-server localhost:9092 \
    --topic events \
    --partitions 3 \
    --replication-factor 3

# 4. Criar conector S3 Sink
cd connects/
./s3-connector.sh create

# Ou use o helper:
./kafka.sh connector-create

# 5. Produzir mensagens de teste
docker exec -it broker1 kafka-console-producer \
    --bootstrap-server localhost:9092 \
    --topic events

# Digite 3 mensagens JSON:
# {"id":1,"message":"test1"}
# {"id":2,"message":"test2"}
# {"id":3,"message":"test3"}
# Pressione Ctrl+C para sair

# 6. Verificar arquivos no S3 LocalStack
cd connects/
./s3-connector.sh show-s3

# Ou use o helper:
./kafka.sh s3-list
```

### Usar o Script Helper

O projeto inclui um script helper para facilitar comandos comuns:

```bash
# Ver todos os comandos disponíveis
./kafka.sh help

# Exemplos de uso:
./kafka.sh start              # Inicia o cluster
./kafka.sh test-connection    # Testa conectividade
./kafka.sh run-producer       # Executa producer de exemplo
./kafka.sh connector-status   # Status do S3 connector
./kafka.sh ui                 # Mostra URLs de todas UIs
./kafka.sh doctor             # Diagnóstico de podman/DNS/OTLP
./kafka.sh build [svc]        # Rebuilda imagem(s)
./kafka.sh run-loadgen        # Sobe container loadgen (tráfego contínuo)
```

### Gerenciar Conector S3

```bash
# Ver status
cd connects/
./s3-connector.sh status

# Listar arquivos S3
./s3-connector.sh show-s3

# Reiniciar conector
./s3-connector.sh restart

# Deletar conector
./s3-connector.sh delete

# Ajuda
./s3-connector.sh help
```

### Comandos Úteis

#### Iniciar componentes específicos
```bash
# Apenas Kafka (controllers + brokers)
podman-compose up -d controller1 controller2 controller3 broker1 broker2 broker3

# Kafka + Connect + LocalStack
podman-compose up -d controller1 controller2 controller3 broker1 broker2 broker3 kafka-connect localstack

# Apenas AKHQ
podman-compose up -d akhq

# Apenas Prometheus
podman-compose up -d prometheus
```

#### Verificar status
```bash
# Status de todos os serviços
podman-compose ps

# Verificar saúde do LocalStack
curl http://localhost:4566/_localstack/health

# Verificar Kafka Connect
curl http://localhost:8083/ | jq '.'
```

### Ver logs
```bash
# Logs de um serviço específico
./kafka.sh logs broker1
./kafka.sh logs kafka-connect
./kafka.sh logs localstack

# Logs de todos os brokers
./kafka.sh logs broker1 broker2 broker3
```

### Parar o ambiente
```bash
podman-compose down
```

### Parar e limpar volumes (dados serão perdidos)
```bash
podman-compose down -v
```

## 📊 Métricas no Prometheus

### Métricas Disponíveis

#### Kafka Brokers/Controllers
- `kafka_server_*` - Métricas gerais do servidor Kafka
- `kafka_network_*` - Métricas de rede (requests, responses)
- `kafka_controller_*` - Métricas específicas do controller
- `kafka_log_*` - Métricas de logs e segmentos
- `kafka_cluster_*` - Métricas do cluster (partições, replicas)

#### JVM
- `jvm_memory_*` - Uso de memória heap e non-heap
- `jvm_gc_*` - Garbage collection
- `jvm_threads_*` - Threads da JVM

### Queries Úteis no Prometheus

Acesse http://localhost:9090 e experimente estas queries:

```promql
# Taxa de mensagens por segundo (entrada)
rate(kafka_server_brokertopicmetrics_messagesinpersec[1m])

# Taxa de bytes de entrada por broker
sum by (instance) (rate(kafka_server_brokertopicmetrics_bytesinpersec[1m]))

# Uso de memória heap dos brokers
jvm_memory_heap_used / jvm_memory_heap_max * 100

# Número de partições under-replicated
kafka_server_replicamanager_underreplicatedpartitions

# Latência de requisições de produce
kafka_network_requestmetrics_totaltimems{request="Produce"}

# Número de ISR (In-Sync Replicas) por partição
kafka_server_replicamanager_isrexpandspersec
```

## 🔍 Dashboards Grafana (opcional)

Para visualizar as métricas graficamente, você pode adicionar o Grafana:

```yaml
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus
```

Depois:
1. Acesse http://localhost:3000 (admin/admin)
2. Adicione Prometheus como datasource (http://prometheus:9090)
3. Importe dashboards prontos:
   - Dashboard ID 721 (Kafka Overview)
   - Dashboard ID 7589 (Kafka Exporter Overview)

## 📝 Configurações Importantes

### JMX Configuration
Todos os brokers e controllers expõem métricas JMX nas portas 9101.

### Prometheus Scrape Interval
As métricas são coletadas a cada 15 segundos (configurável em `prometheus.yml`).

### Volumes Persistentes
Os dados são armazenados em volumes Docker:
- `controller{1,2,3}-data`: Metadados dos controllers
- `broker{1,2,3}-data`: Dados das mensagens
- `prometheus-data`: Métricas históricas
- `localstack-data`: Dados do S3 (bucket kafka-events-bucket)

## 📁 Estrutura do Projeto

```
kafka-project/
├── docker-compose.yml              # Orquestração de todos os serviços
├── prometheus.yml                  # Configuração do Prometheus
├── jmx-exporter-config.yml        # Regras de métricas JMX
├── s3-sink-connector.json         # Configuração do S3 Sink Connector
├── s3-connector.sh                # Script de gerenciamento do conector
├── localstack-init/               # Scripts de inicialização LocalStack
│   └── 01-create-bucket.sh        # Cria bucket S3
├── S3-SINK-GUIDE.md              # Guia completo S3 Sink
├── METRICS-ARCHITECTURE.md        # Arquitetura de métricas
└── README.md                      # Este arquivo
```

## 🛠️ Troubleshooting

### Kafka Connect

```bash
# Verificar se o plugin S3 está instalado
curl http://localhost:8083/connector-plugins | jq '.[] | select(.class | contains("S3"))'

# Ver logs do Kafka Connect
./kafka.sh logs kafka-connect

# Verificar status do conector
./s3-connector.sh status
```

### LocalStack S3

```bash
# Verificar saúde do LocalStack
curl http://localhost:4566/_localstack/health

# Listar buckets
podman exec -it localstack awslocal s3 ls

# Recriar bucket manualmente
podman exec -it localstack awslocal s3 mb s3://kafka-events-bucket
```

### Arquivos Não Aparecem no S3

⚠️ **Lembre-se:** Arquivos só são criados após:
- **3 mensagens** (flush.size) OU
- **60 segundos** (rotate.interval.ms)

**Solução:** Envie 3 mensagens de teste para forçar flush.

### Brokers não iniciam
```bash
# Verifique os logs
./kafka.sh logs broker1

# Verifique se os controllers estão rodando
podman-compose ps | grep controller
```

### Prometheus não coleta métricas
```bash
# Verifique os targets no Prometheus
# Acesse: http://localhost:9090/targets

# Teste conexão JMX manualmente
podman exec -it broker1 kafka-broker-api-versions --bootstrap-server localhost:9092
```

### JMX Exporter não conecta
```bash
# Verifique se a porta JMX está acessível
podman exec -it broker1 nc -zv localhost 9101
```

## 📚 Documentação

- **[S3-SINK-GUIDE.md](S3-SINK-GUIDE.md)** - Guia completo do S3 Sink Connector
- **[METRICS-ARCHITECTURE.md](METRICS-ARCHITECTURE.md)** - Arquitetura de métricas
- [Kafka KRaft Documentation](https://kafka.apache.org/documentation/#kraft)
- [Confluent S3 Sink Connector](https://docs.confluent.io/kafka-connectors/s3-sink/current/overview.html)
- [LocalStack Documentation](https://docs.localstack.cloud/)
- [AKHQ Documentation](https://akhq.io/)
- [Prometheus JMX Exporter](https://github.com/prometheus/jmx_exporter)

## 🎯 Features Implementadas

✅ Kafka KRaft (3 controllers + 3 brokers)  
✅ Kafka Connect com S3 Sink Connector  
✅ LocalStack para testes S3 locais (sem AWS!)  
✅ AKHQ - Interface completa de administração  
✅ Prometheus - Monitoramento de métricas  
✅ JMX direto - Sem containers de exporter desnecessários  
✅ Scripts de gerenciamento (`s3-connector.sh`)  
✅ Documentação completa em português  

## 🚀 Próximos Passos Sugeridos

1. **Adicionar Grafana** para dashboards visuais
2. **Configurar Alertmanager** para alertas de métricas
3. **Adicionar Schema Registry** para validação Avro/Protobuf
4. **Implementar mais conectores** (JDBC, Elasticsearch, etc.)
5. **Configurar autenticação** (SASL/SSL)
6. **Adicionar Kafka Streams** para processamento em tempo real

---

💡 **Dica:** Comece explorando o AKHQ em http://localhost:8080 para ter uma visão visual completa do seu cluster!
