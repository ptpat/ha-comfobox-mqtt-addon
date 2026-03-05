FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gnupg \
        socat \
        unzip \
        tzdata \
        jq \
        apt-transport-https \
    ; \
    # Mono offizielles Repository via curl (stabiler als gpg keyserver)
    curl -fsSL https://download.mono-project.com/repo/xamarin.gpg \
        | gpg --dearmor \
        > /usr/share/keyrings/mono-official.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/mono-official.gpg] https://download.mono-project.com/repo/debian stable-bookworm main" \
        > /etc/apt/sources.list.d/mono-official-stable.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mono-complete \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    update-ca-certificates

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
