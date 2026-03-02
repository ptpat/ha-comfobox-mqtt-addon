FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    unzip \
    socat \
    mono-runtime \
    jq \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ZIP ins Image kopieren
COPY ComfoBox2Mqtt_0.4.0.zip /app/

# ZIP entpacken
RUN unzip ComfoBox2Mqtt_0.4.0.zip && rm ComfoBox2Mqtt_0.4.0.zip

# Startskript kopieren
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
