#!/usr/bin/env python3
"""
Producer de exemplo para enviar eventos ao tópico 'events'
que serão persistidos no S3 via S3 Sink Connector

Instalação:
    pip install kafka-python

Uso:
    python producer_example.py
"""

from kafka import KafkaProducer
import json
import time
import logging
from datetime import datetime, timezone
import random

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(name)s otelSpanID=%(otelSpanID)s otelTraceID=%(otelTraceID)s %(message)s'
)
logger = logging.getLogger("kafka-producer")

# Configuração
BOOTSTRAP_SERVERS = ['localhost:9092']
TOPIC = 'events'

# Tipos de eventos de exemplo
EVENT_TYPES = [
    'user_login',
    'user_logout',
    'page_view',
    'button_click',
    'purchase',
    'add_to_cart',
    'search',
    'signup'
]

PAGES = ['/home', '/products', '/cart', '/checkout', '/profile', '/about']
PRODUCTS = ['laptop', 'mouse', 'keyboard', 'monitor', 'headphones', 'webcam']
USERS = ['alice', 'bob', 'charlie', 'david', 'emma', 'frank']


def create_producer():
    """Cria e retorna um KafkaProducer"""
    return KafkaProducer(
        bootstrap_servers=BOOTSTRAP_SERVERS,
        value_serializer=lambda v: json.dumps(v).encode('utf-8'),
        key_serializer=lambda k: k.encode('utf-8') if k else None,
        acks='all',  # Aguardar confirmação de todas as replicas
        retries=3,
        compression_type='gzip'
    )


def generate_event(event_id):
    """Gera um evento de exemplo"""
    event_type = random.choice(EVENT_TYPES)
    user = random.choice(USERS)
    
    event = {
        'id': event_id,
        'type': event_type,
        'user': user,
        'timestamp': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    }
    
    # Adicionar campos específicos por tipo
    if event_type == 'page_view':
        event['page'] = random.choice(PAGES)
        event['duration_seconds'] = random.randint(5, 300)
    
    elif event_type == 'purchase':
        event['product'] = random.choice(PRODUCTS)
        event['amount'] = round(random.uniform(50, 2000), 2)
        event['quantity'] = random.randint(1, 5)
    
    elif event_type == 'add_to_cart':
        event['product'] = random.choice(PRODUCTS)
        event['quantity'] = random.randint(1, 3)
    
    elif event_type == 'search':
        event['query'] = random.choice(PRODUCTS)
        event['results_count'] = random.randint(0, 100)
    
    elif event_type == 'button_click':
        event['button_id'] = f'btn_{random.randint(1, 20)}'
        event['page'] = random.choice(PAGES)
    
    return event


def send_batch(producer, num_events=10, delay=0.5):
    """Envia um lote de eventos"""
    print(f"\n🚀 Enviando {num_events} eventos para o tópico '{TOPIC}'...\n")
    
    for i in range(1, num_events + 1):
        event = generate_event(i)
        
        # Usar user como chave para garantir ordenação por usuário
        key = event['user']
        
        # Enviar evento
        future = producer.send(
            topic=TOPIC,
            key=key,
            value=event
        )
        
        # Aguardar confirmação
        try:
            record_metadata = future.get(timeout=10)
            logger.info(
                "sent event",
                extra={"event_id": i, "event_type": event["type"], "user": event["user"],
                       "partition": record_metadata.partition, "offset": record_metadata.offset}
            )
        except Exception as e:
            logger.error("send failed", extra={"event_id": i, "error": str(e)})
        
        # Delay entre mensagens
        if delay > 0:
            time.sleep(delay)
    
    # Garantir que todas as mensagens foram enviadas
    producer.flush()
    print(f"\n✅ {num_events} eventos enviados com sucesso!")


def send_continuous(producer, events_per_second=2, duration_seconds=60):
    """Envia eventos continuamente"""
    print(f"\n🔄 Modo contínuo: {events_per_second} eventos/segundo por {duration_seconds} segundos")
    print("Pressione Ctrl+C para parar\n")
    
    event_id = 1
    start_time = time.time()
    delay = 1.0 / events_per_second
    
    try:
        while (time.time() - start_time) < duration_seconds:
            event = generate_event(event_id)
            key = event['user']
            
            future = producer.send(topic=TOPIC, key=key, value=event)
            
            try:
                record_metadata = future.get(timeout=10)
                logger.info(
                    "sent event",
                    extra={"event_type": event["type"], "user": event["user"],
                           "partition": record_metadata.partition, "offset": record_metadata.offset}
                )
            except Exception as e:
                logger.error("send failed", extra={"error": str(e)})
            
            event_id += 1
            time.sleep(delay)
    
    except KeyboardInterrupt:
        print("\n\n⏸️  Interrompido pelo usuário")
    
    producer.flush()
    total_sent = event_id - 1
    print(f"\n✅ Total enviado: {total_sent} eventos")


def main():
    """Função principal"""
    print("=" * 60)
    print("  Kafka Producer - Eventos para S3 Sink")
    print("=" * 60)
    
    # Criar producer
    print("\n📡 Conectando ao Kafka...")
    try:
        producer = create_producer()
        print("✓ Conectado!")
    except Exception as e:
        print(f"✗ Erro ao conectar: {e}")
        return
    
    # Menu
    print("\nEscolha o modo:")
    print("  1. Enviar lote de eventos (padrão: 10 eventos)")
    print("  2. Enviar modo contínuo (padrão: 2 eventos/segundo por 60s)")
    print("  3. Teste rápido (3 eventos para testar S3 flush)")
    
    choice = input("\nOpção [1-3] (Enter=1): ").strip() or "1"
    
    try:
        if choice == "1":
            num = input("Quantos eventos? (Enter=10): ").strip()
            num_events = int(num) if num else 10
            send_batch(producer, num_events=num_events)
        
        elif choice == "2":
            rate = input("Eventos por segundo? (Enter=2): ").strip()
            events_per_second = int(rate) if rate else 2
            duration = input("Duração em segundos? (Enter=60): ").strip()
            duration_seconds = int(duration) if duration else 60
            send_continuous(producer, events_per_second, duration_seconds)
        
        elif choice == "3":
            print("\n🧪 Teste rápido - 3 eventos (força flush no S3)")
            send_batch(producer, num_events=3, delay=0)
            print("\n💡 Aguarde 5-10 segundos e execute:")
            print("   ./s3-connector.sh show-s3")
        
        else:
            print("Opção inválida!")
    
    except ValueError as e:
        print(f"✗ Valor inválido: {e}")
    except Exception as e:
        print(f"✗ Erro: {e}")
    finally:
        producer.close()
        print("\n👋 Producer fechado")


if __name__ == "__main__":
    main()
