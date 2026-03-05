# ComfoBox MQTT Bridge — Home Assistant Add-on

Verbindet eine **Zehnder ComfoBox Series 5 (ELESTA)** über einen Waveshare RS485/Ethernet-Adapter mit Home Assistant via MQTT. Basiert auf dem [RF77 ComfoBox2Mqtt](https://github.com/RF77/comfobox-mqtt) Projekt (v0.4.0).

---

## Architektur

```
ComfoBox Series 5
  │ RS485 / BACnet MSTP
  ▼
Waveshare RS485-to-ETH (TCP Server, Port 8899)
  │ TCP
  ▼
socat PTY-Bridge (im Add-on Container)
  │ virtueller serieller Port (/dev/pts/X)
  ▼
Mono — RF77 ComfoBoxMqttConsole.exe
  │ MQTT
  ▼
Mosquitto Broker (core-mosquitto)
  │
  ▼
Home Assistant
```

---

## Voraussetzungen

### Hardware
- Zehnder ComfoBox Series 5 (ELESTA Steuerung)
- Waveshare RS485-to-ETH Adapter (z.B. USR-TCP232-306 oder ähnlich)
- RS485-Kabel: ComfoBox RS485-Port → Waveshare A/B Klemmen

### Waveshare Konfiguration
Öffne `http://<waveshare-ip>` im Browser (kein Passwort):
- **Work Mode:** TCP Server
- **Local Port:** 8899
- **Baud Rate:** 38400 (muss mit ComfoBox OEM-Einstellung übereinstimmen)
- **Data Bits:** 8, **Parity:** None, **Stop Bits:** 1

### ComfoBox OEM-Menü
Die ComfoBox muss auf **38400 Baud** konfiguriert sein (Werkseinstellung ist 76800).
Zugang über das OEM-Menü der ComfoBox-Bedieneinheit.

### MQTT Broker
Das Add-on benötigt **anonymen MQTT-Zugang** — RF77 ComfoBoxMqttConsole unterstützt keine MQTT-Authentifizierung.

Mosquitto-Konfiguration (`/share/mosquitto/mosquitto.conf`):
```
listener 1883
allow_anonymous true
```

---

## Installation

1. **Repository hinzufügen** in HA unter Settings → Add-ons → Repositories:
   ```
   https://github.com/ptpat/ha-comfobox-mqtt-addon
   ```

2. **Add-on installieren:** ComfoBox MQTT Bridge

3. **Konfiguration anpassen** (siehe unten)

4. **Add-on starten**

---

## Konfiguration

| Option | Typ | Default | Beschreibung |
|--------|-----|---------|--------------|
| `waveshare_host` | string | — | IP-Adresse des Waveshare Adapters |
| `waveshare_port` | int | 8899 | TCP-Port des Waveshare Adapters |
| `baudrate` | int | 38400 | Baudrate (muss mit ComfoBox OEM übereinstimmen) |
| `mqtt_host` | string | core-mosquitto | MQTT Broker Hostname |
| `mqtt_port` | int | 1883 | MQTT Broker Port |
| `mqtt_base_topic` | string | ComfoBox | MQTT Basis-Topic |
| `bacnet_master_id` | int | 1 | BACnet-Adresse der ComfoBox |
| `bacnet_client_id` | int | 3 | BACnet-Adresse dieses Clients (muss verschieden von master_id sein) |

Beispiel:
```yaml
waveshare_host: "192.168.0.24"
waveshare_port: 8899
baudrate: 38400
mqtt_host: core-mosquitto
mqtt_port: 1883
mqtt_base_topic: ComfoBox
bacnet_master_id: 1
bacnet_client_id: 3
```

---

## MQTT Topics

Alle Topics beginnen mit dem konfigurierten `mqtt_base_topic` (Standard: `ComfoBox`).

Lesen: `ComfoBox/<Kategorie>/<Name>`
Schreiben: `ComfoBox/<Kategorie>/<Name>/Set`

Beispiele:
- `ComfoBox/Climate/OutdoorTemperature` — Aussentemperatur
- `ComfoBox/Ventilation/VentilationMode` — Lüftungsstufe
- `ComfoBox/Ventilation/VentilationMode/Set` — Lüftungsstufe setzen
- `ComboBox/Special/NumberOfWritesPer24h` — Anzahl Schreibvorgänge heute

Eine vollständige Topic-Liste findet sich in der [RF77 Dokumentation](https://github.com/RF77/comfobox-mqtt).

> **Achtung:** Die ComfoBox speichert Schreibwerte im EEPROM (~1'000'000 Schreibzyklen). Schreibwerte sparsam verwenden.

---

## Technische Details / Bekannte Probleme

### aarch64 (HA Green) — tcsetattr ENOTTY
Mono's `SerialPort` ruft `tcsetattr()` auf dem virtuellen seriellen Port auf. Auf ARM/aarch64 gibt der Linux-Kernel `ENOTTY` zurück wenn der Port ein PTY-Slave ist. Das Add-on löst dies mit einem `LD_PRELOAD`-Wrapper (`tcsetattr_fix.so`) der `ENOTTY` abfängt und Erfolg zurückgibt.

### Baudrate
RF77 berichtet dass auf dem Raspberry Pi nur **38400 Baud** funktioniert hat — die ComfoBox muss im OEM-Menü entsprechend konfiguriert werden (Werkseinstellung 76800).

### RS485 Polarität
Falls keine BACnet-Kommunikation zustande kommt, A/B Kabel am Waveshare tauschen.

---

## Entwicklungsgeschichte — Was nicht funktioniert hat

Für alle die dasselbe Problem debuggen, hier die Irrwege:

### Alpine Linux (ghcr.io/hassio-addons/base)
Die Standard-HA-Addon-Basis verwendet Alpine mit **musl libc**. Mono's `SerialPort.isatty()` gibt auf musl `false` zurück für PTY-Slaves → `Not a tty` Fehler. Lösung: Wechsel zu **Debian bookworm-slim** (glibc).

### /dev/ttyS0 via devices:
`/dev/ttyS0` auf HA Green ist ein dummy UART ohne echte Hardware. `socat` kann darauf nicht schreiben → `I/O error`. Kein brauchbarer serieller Port.

### socat mit ispeed/ospeed
`socat PTY,ispeed=76800` — socat kennt 76800 nicht als Standard-Baudrate → `cfsetispeed: Invalid argument`. Nicht-Standard-Baudraten werden von socat nicht unterstützt.

### socat rawer statt raw
`rawer` setzt intern Baudrate-Optionen auf dem PTY → `cfsetispeed: Invalid argument`. Lösung: `raw` verwenden.

### stty vor Mono-Start
`stty -F /dev/pts/1 38400` auf einem PTY-Slave schlägt lautlos fehl (`|| true`). Mono ruft trotzdem `tcsetattr()` auf → `ENOTTY`. stty hilft nicht.

### socat PTY↔PTY Topologie
Zwei socat-Prozesse: PTY-A↔PTY-B und PTY-B↔TCP. Mono bekommt PTY-A. Trotzdem `ENOTTY` — PTY-Slaves auf ARM/aarch64 Linux unterstützen `tcsetattr()` grundsätzlich nicht vollständig, unabhängig von der Topologie.

### Baudrate 76800
RF77 README: *"On my Raspberry only a baudrate of 38400 was working."* Die ComfoBox muss im OEM-Menü auf 38400 umgestellt werden.

### Mono aus externem Repository (mono-project.com)
Im HA-Build-Container kein Internetzugang für `gpg keyserver` oder `curl` zu externen Repos → Build schlägt fehl mit Exit Code 100. Lösung: `mono-complete` direkt aus Debian Bookworm Standard-Repository.

---

## Lizenz

Dieses Add-on basiert auf [RF77/comfobox-mqtt](https://github.com/RF77/comfobox-mqtt) — siehe `License rf77` für die ursprüngliche Lizenz.
