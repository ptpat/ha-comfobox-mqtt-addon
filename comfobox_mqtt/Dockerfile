FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Alle Pakete aus Debian Standard-Repository — kein externes Repo nötig.
# mono-complete ist in Debian bookworm enthalten (Version 6.8).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        socat \
        unzip \
        tzdata \
        jq \
        mono-runtime \
        libmono-system-runtime4.0-cil \
        libmono-system-xml4.0-cil \
        libmono-system-net-http4.0-cil \
        libmono-system-servicemodel4.0a-cil \
        libmono-corlib4.5-cil \
        libmono-posix4.0-cil \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
