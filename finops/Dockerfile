FROM python:3.12-slim AS build

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target /build/deps -r requirements.txt

FROM python:3.12-slim

# Non-root, matching the runAsUser in the Terraform deployment. The container
# also runs with a read-only root filesystem, so nothing may write outside
# /tmp at runtime.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin collector

WORKDIR /app
COPY --from=build /build/deps /app/deps
COPY collector /app/collector

ENV PYTHONPATH=/app/deps \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001

ENTRYPOINT ["python", "-m", "collector.main"]
