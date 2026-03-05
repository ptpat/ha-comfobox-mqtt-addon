FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        socat \
        unzip \
        tzdata \
        jq \
        mono-complete \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
