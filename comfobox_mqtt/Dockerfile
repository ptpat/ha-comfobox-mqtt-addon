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
        gcc \
        libc6-dev \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# LD_PRELOAD Wrapper: tcsetattr() ENOTTY auf PTY/aarch64 abfangen.
# C-Code via base64 eingebettet um Shell-Escaping-Probleme zu vermeiden.
RUN echo "I2RlZmluZSBfR05VX1NPVVJDRQojaW5jbHVkZSA8dGVybWlvcy5oPgojaW5jbHVkZSA8ZXJybm8uaD4KI2luY2x1ZGUgPGRsZmNuLmg+CnR5cGVkZWYgaW50ICgqZm5fdCkoaW50LGludCxjb25zdCBzdHJ1Y3QgdGVybWlvcyopOwppbnQgdGNzZXRhdHRyKGludCBmZCxpbnQgYWN0LGNvbnN0IHN0cnVjdCB0ZXJtaW9zKnQpewogIHN0YXRpYyBmbl90IHJlYWw9TlVMTDsKICBpZighcmVhbClyZWFsPShmbl90KWRsc3ltKFJUTERfTkVYVCwidGNzZXRhdHRyIik7CiAgaW50IHI9cmVhbChmZCxhY3QsdCk7CiAgaWYocj09LTEmJmVycm5vPT1FTk9UVFkpe2Vycm5vPTA7cmV0dXJuIDA7fQogIHJldHVybiByOwp9Cg==" \
        | base64 -d > /tmp/tcsetattr_fix.c \
    && gcc -shared -fPIC -o /usr/local/lib/tcsetattr_fix.so /tmp/tcsetattr_fix.c -ldl \
    && rm /tmp/tcsetattr_fix.c

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
