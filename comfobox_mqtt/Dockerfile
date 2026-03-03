ARG BUILD_FROM=ghcr.io/hassio-addons/base:15.0.7
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install runtime deps
RUN apk add --no-cache \
    socat \
    mono \
    ca-certificates \
    icu-libs \
    tzdata \
    bash \
    coreutils \
    findutils \
    grep \
    sed \
    awk \
    unzip

# Copy add-on files
COPY run.sh /app/run.sh
COPY ComfoBox2Mqtt_0.4.0.zip /app/ComfoBox2Mqtt_0.4.0.zip

RUN chmod +x /app/run.sh \
    && mkdir -p /app/ComfoBox2Mqtt \
    && unzip -o /app/ComfoBox2Mqtt_0.4.0.zip -d /app/ComfoBox2Mqtt \
    && rm -f /app/ComfoBox2Mqtt_0.4.0.zip

CMD [ "/app/run.sh" ]
