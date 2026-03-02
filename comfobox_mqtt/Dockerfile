FROM debian:bookworm-slim

# Installiere benötigte Tools: socat, mono (für comfobox-mqtt)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    socat \
    mono-runtime \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Comfobox-MQTT Binaries (wir kopieren sie später hier rein)
COPY rootfs/ / 

RUN chmod +x /run.sh

CMD ["/run.sh"]
