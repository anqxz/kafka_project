#!/bin/bash
#
# Script de inicialização para LocalStack
# Cria bucket S3 e recursos iniciais
#

set -e

echo "🚀 Inicializando LocalStack..."

# Wait for LocalStack to be ready
echo "⏳ Aguardando LocalStack..."
sleep 5

# S3 Bucket
echo "📦 Criando bucket S3..."
awslocal s3 mb s3://kafka-data-bucket || echo "  Bucket já existe"
awslocal s3api put-bucket-versioning \
    --bucket kafka-data-bucket \
    --versioning-configuration Status=Enabled

# Criar prefixos
echo "📁 Criando prefixos S3..."
for prefix in topics/ backups/ schemas/ dead-letter-queue/; do
    echo "{}" | awslocal s3 cp - s3://kafka-data-bucket/${prefix}.keep
done

# Bucket antigo para compatibilidade
awslocal s3 mb s3://kafka-events-bucket || echo "  Bucket kafka-events-bucket já existe"

echo "✅ LocalStack inicializado com sucesso!"
echo "Buckets criados:"
awslocal s3 ls

