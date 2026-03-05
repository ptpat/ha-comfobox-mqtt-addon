# Debian Bookworm als Basis statt Alpine/musl
# Grund: Mono's SerialPort.Open() + isatty() funktioniert nur mit glibc (Debian/Raspbian),
# nicht mit musl libc (Alpine). RF77 hat v0.4.0 explizit auf Raspberry Pi (Raspbian) getestet.
#
# HA-Addon-Kompatibilität:
# - Das offizielle HA-Addon-System erwartet ARG BUILD_FROM für Multi-Arch-Builds.
# - Für aarch64/HA Green verwenden wir debian:bookworm-slim direkt.
# - s6-overlay wird NICHT benötigt — run.sh wird direkt als CMD ausgeführt.

FROM debian:bookworm-slim

# Umgebungsvariablen
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Europe/Zurich

# System-Pakete + Mono-Repository installieren
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
        dirmngr \
    ; \
    # Mono offizielles Repository (identisch zu Raspbian-Installation)
    gpg --homedir /tmp --no-default-keyring \
        --keyring /usr/share/keyrings/mono-official.gpg \
        --keyserver hkp://keyserver.ubuntu.com:80 \
        --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF; \
    echo "deb [signed-by=/usr/share/keyrings/mono-official.gpg] https://download.mono-project.com/repo/debian stable-bookworm main" \
        > /etc/apt/sources.list.d/mono-official-stable.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mono-complete \
    ; \
    # Aufräumen
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    update-ca-certificates

WORKDIR /app

# Add-on Dateien kopieren
COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
