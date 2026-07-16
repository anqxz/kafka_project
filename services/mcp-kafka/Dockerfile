# Tier-0 read-only MCP server for the Kafka cluster. Contract lives in
# 02-INTEGRATION-ARCHITECTURE.md §3. Multi-stage: deps in a builder image,
# only the venv and app copied into the slim runtime.
ARG PYTHON_TAG=3.13-slim

FROM python:${PYTHON_TAG} AS builder
WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:${PYTHON_TAG}
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MCP_MODE=read-only \
    MCP_TRANSPORT=sse \
    MCP_PORT=3001
COPY --from=builder /install /usr/local
WORKDIR /app
COPY app/ /app/
EXPOSE 3001
CMD ["python", "server.py"]
