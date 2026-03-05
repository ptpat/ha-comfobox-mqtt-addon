ARG BUILD_FROM=ghcr.io/hassio-addons/base:19.0.0
FROM ${BUILD_FROM}

# Runtime-Abhängigkeiten installieren
RUN set -eux; \
    apk add --no-cache \
        bash \
        ca-certificates \
        socat \
        unzip \
        tzdata \
        icu-libs \
        libstdc++ \
        libgcc \
        jq \
    ; \
    # Mono aus Alpine edge (einzige verfügbare Quelle für Alpine)
    apk add --no-cache \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
        mono \
    ; \
    update-ca-certificates

WORKDIR /app

# Add-on Dateien kopieren
COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
