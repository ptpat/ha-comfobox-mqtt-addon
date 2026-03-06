ARG BUILD_FROM
FROM ${BUILD_FROM}

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
        gcc \
        libc6-dev \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# LD_PRELOAD Wrapper: tcsetattr() ENOTTY auf PTY/aarch64 abfangen.
COPY tcsetattr_fix.c /tmp/tcsetattr_fix.c
RUN gcc -shared -fPIC -o /usr/local/lib/tcsetattr_fix.so /tmp/tcsetattr_fix.c -ldl \
    && rm /tmp/tcsetattr_fix.c

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
