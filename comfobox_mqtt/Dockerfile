ARG BUILD_FROM
FROM ${BUILD_FROM}

# Alpine default shell exists (/bin/sh). Do NOT switch to bash here.
SHELL ["/bin/sh", "-o", "pipefail", "-c"]

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
  # mono sometimes only in edge/community
  apk add --no-cache \
    --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
    --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    mono \
  ; \
  update-ca-certificates

WORKDIR /app

COPY ComfoBox2Mqtt_0.4.0.zip /app/ComfoBox2Mqtt_0.4.0.zip
COPY run.sh /app/run.sh

RUN chmod +x /app/run.sh \
  && rm -rf /app/ComfoBox2Mqtt \
  && unzip -q /app/ComfoBox2Mqtt_0.4.0.zip -d /app \
  && test -f /app/ComfoBox2Mqtt/ComfoBoxMqttConsole.exe

CMD ["/app/run.sh"]
