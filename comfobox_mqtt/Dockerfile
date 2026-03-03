ARG BUILD_FROM
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     ca-certificates \
     tzdata \
     jq \
     socat \
     unzip \
     mono-complete \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Add-on Dateien rein
COPY . /app

# RF77 ZIP entpacken (führt zu /app/ComfoBox2Mqtt/...)
RUN unzip -o /app/ComfoBox2Mqtt_0.4.0.zip -d /app \
  && rm -f /app/ComfoBox2Mqtt_0.4.0.zip

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
