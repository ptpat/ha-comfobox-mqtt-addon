FROM mono:6.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    unzip \
    socat \
    jq \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY ComfoBox2Mqtt_0.4.0.zip /app/
RUN unzip ComfoBox2Mqtt_0.4.0.zip && rm ComfoBox2Mqtt_0.4.0.zip

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
