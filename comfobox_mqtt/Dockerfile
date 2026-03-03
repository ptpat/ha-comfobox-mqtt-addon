ARG BUILD_FROM
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     mono-complete \
     socat \
     ca-certificates \
     tzdata \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# App-Dateien rein
COPY . /app

# run.sh ausführbar machen
RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
