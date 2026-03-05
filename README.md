# ComfoBox MQTT Bridge

Home Assistant Add-on für die Zehnder ComfoBox Series 5 (ELESTA-Controller) via Waveshare RS485/TCP-Adapter.

## Architektur

```
ComfoBox (RS485/MSTP BACnet)
    ↕
Waveshare RS485/Ethernet-Adapter (TCP)
    ↕
socat (virtueller serieller Port /tmp/comfobox)
    ↕
RF77 ComfoBox2Mqtt (Mono/.NET)
    ↕
MQTT Broker (Mosquitto)
    ↕
Home Assistant
```

## Voraussetzungen

- Zehnder ComfoBox Series 5 mit ELESTA-Controller
- [Waveshare RS485/Ethernet-Adapter](https://www.waveshare.com/rs485-to-eth.htm) parallel an den RS485-Bus der ComfoBox angeschlossen
- MQTT Broker (z.B. Mosquitto Add-on in HA)
- Home Assistant auf **amd64** oder **aarch64** (Mono läuft nicht auf armv7)

## Installation

1. In Home Assistant: **Einstellungen → Add-ons → Add-on Store → ⋮ → Repositories**
2. Repository URL hinzufügen: `https://github.com/ptpat/ha-comfobox-mqtt-addon`
3. Add-on **ComfoBox MQTT Bridge** installieren

## Konfiguration

| Parameter | Beschreibung | Standard |
|---|---|---|
| `waveshare_host` | IP des Waveshare-Adapters | — |
| `waveshare_port` | TCP-Port des Waveshare-Adapters | `8899` |
| `baudrate` | RS485-Baudrate (muss mit ComfoBox übereinstimmen) | `76800` |
| `mqtt_host` | MQTT Broker | `core-mosquitto` |
| `mqtt_port` | MQTT Port | `1883` |
| `mqtt_user` | MQTT Benutzername (optional) | — |
| `mqtt_pass` | MQTT Passwort (optional) | — |
| `mqtt_base_topic` | Basis-Topic für alle Werte | `ComfoBox` |
| `bacnet_master_id` | BACnet Device-ID der ComfoBox | `1` |
| `bacnet_client_id` | BACnet ID dieses Bridges | `3` |

### Baudrate ermitteln

Die Baudrate der ComfoBox kann im OEM-Menü eingesehen werden. Typische Werte sind `38400` oder `76800`.

### BACnet IDs

Die `bacnet_master_id` ist die Device-ID der ComfoBox auf dem MSTP-Bus (üblicherweise `1`).
Die `bacnet_client_id` muss eine andere, freie ID auf dem Bus sein (Standard `3`).

## MQTT Topics

Nach dem Start publiziert das Add-on alle ComfoBox-Werte unter dem konfigurierten Base-Topic, z.B.:

```
ComfoBox/Climate/ActualTemperature_WaterHeater
ComfoBox/Climate/SetPoint_RoomTemperature
ComfoBox/Ventilation/FanSpeed
...
```

Schreibbare Werte können über das `/Set`-Suffix gesetzt werden:
```
ComfoBox/Climate/SetPoint_RoomTemperature/Set  → 21.5
```

Eine vollständige Topic-Liste findet sich in der [RF77 Dokumentation](https://github.com/RF77/comfobox-mqtt/blob/master/docs/topics.md).

## Basiert auf

- [RF77/comfobox-mqtt](https://github.com/RF77/comfobox-mqtt) — BACnet/MSTP zu MQTT Bridge (.NET/Mono)
