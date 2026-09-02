# syntax=docker/dockerfile:1

# ============================================================
# BUILD STAGE
# ============================================================

FROM haskell:9.10.3-slim-bookworm AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        libpq-dev \
        pkg-config \
        zlib1g-dev \
        libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

RUN cabal update

RUN cabal build exe:haskell-datahub

RUN mkdir -p /out \
    && cp "$(cabal list-bin exe:haskell-datahub)" \
          /out/haskell-datahub


# ============================================================
# RUNTIME STAGE
# ============================================================

FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libpq5 \
        libgmp10 \
        libffi8 \
        libnuma1 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build \
    /out/haskell-datahub \
    /usr/local/bin/haskell-datahub

COPY migrations /app/migrations

COPY clickhouse-migrations /app/clickhouse-migrations

RUN groupadd --system --gid 10001 datahub \
    && useradd \
        --system \
        --uid 10001 \
        --gid datahub \
        --home-dir /app \
        --shell /usr/sbin/nologin \
        datahub \
    && chown -R datahub:datahub /app

USER datahub

EXPOSE 8080

ENTRYPOINT ["haskell-datahub"]