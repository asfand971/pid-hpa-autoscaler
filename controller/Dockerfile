# Stage 1: Build dependencies
FROM python:3.11-slim AS builder

WORKDIR /app

# Install dependencies into a prefix for clean copying
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2: Minimal runtime image
FROM python:3.11-slim

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy controller source
COPY pid.py prom_client.py k8s_client.py controller.py ./

# Run as non-root for security
RUN useradd --no-create-home --shell /bin/false controller
USER controller

# Environment variable defaults (overridden by Kubernetes Deployment env)
ENV PROMETHEUS_URL=http://prometheus-kube-prometheus-prometheus.default.svc.cluster.local:9090 \
    DEPLOYMENT_NAME=go-plant \
    NAMESPACE=default \
    LOOP_INTERVAL=15 \
    KP=0.5 \
    KI=0.05 \
    KD=0.1 \
    SETPOINT=0.0 \
    MIN_REPLICAS=1 \
    MAX_REPLICAS=10 \
    DEAD_BAND=2.0 \
    LOG_LEVEL=INFO

CMD ["python", "controller.py"]