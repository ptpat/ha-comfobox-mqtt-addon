ARG BUILD_FROM
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Mono ist nicht in jedem Alpine-Repo gleich verfügbar -> edge/community als Fallback
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
  ; \
  apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    mono \
  ; \
  update-ca-certificates

WORKDIR /app

# Dein RF77 Zip liegt im Add-on Ordner
COPY ComfoBox2Mqtt_0.4.0.zip /app/ComfoBox2Mqtt_0.4.0.zip
COPY run.sh /app/run.sh

RUN chmod +x /app/run.sh \
  && rm -rf /app/ComfoBox2Mqtt \
  && unzip -q /app/ComfoBox2Mqtt_0.4.0.zip -d /app \
  && test -f /app/ComfoBox2Mqtt/ComfoBoxMqttConsole.exe

CMD ["/app/run.sh"]
