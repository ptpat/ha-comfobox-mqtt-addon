# ComfoBox MQTT Bridge — Home Assistant Add-on

Home Assistant add-on for the **Zehnder ComfoBox Series 5** (ELESTA controller) via a Waveshare RS485/Ethernet adapter.

## Architecture

```
Zehnder ComfoBox Series 5
  │  RS485 / BACnet MSTP
  │
Waveshare RS485-to-Ethernet adapter  (TCP)
  │
socat  →  virtual serial port  /tmp/comfobox
  │
RF77 ComfoBox2Mqtt  (Mono / .NET)
  │  MQTT
MQTT Broker  (Mosquitto)
  │
Home Assistant
```

## Requirements

| Component | Details |
|---|---|
| Heating unit | Zehnder ComfoBox Series 5 with ELESTA controller |
| Adapter | Waveshare RS485-to-ETH, wired in parallel to the ComfoBox RS485 bus |
| MQTT broker | Mosquitto add-on (or any external broker) |
| HA architecture | **amd64 or aarch64 only** — Mono does not run on armv7 |

## Installation

1. In Home Assistant go to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**
2. Add repository URL: `https://github.com/ptpat/ha-comfobox-mqtt-addon`
3. Install **ComfoBox MQTT Bridge**
4. Configure the add-on (see below) and start it

## Configuration

| Option | Description | Default |
|---|---|---|
| `waveshare_host` | IP address or hostname of the Waveshare adapter | *(required)* |
| `waveshare_port` | TCP port of the Waveshare adapter | `8899` |
| `baudrate` | RS485 baudrate — must match the ComfoBox OEM setting | `76800` |
| `mqtt_host` | MQTT broker hostname | `core-mosquitto` |
| `mqtt_port` | MQTT broker port | `1883` |
| `mqtt_user` | MQTT username (leave empty if no auth) | *(optional)* |
| `mqtt_pass` | MQTT password (leave empty if no auth) | *(optional)* |
| `mqtt_base_topic` | Root topic for all ComfoBox values | `ComfoBox` |
| `bacnet_master_id` | BACnet device ID of the ComfoBox (check OEM menu) | `1` |
| `bacnet_client_id` | BACnet ID of this bridge on the MSTP bus | `3` |

### Finding the correct baudrate

The ComfoBox baudrate is visible in the **OEM menu** of the controller. Common values are `38400` and `76800`. The Waveshare adapter must be configured to the same baudrate.

### BACnet IDs

- `bacnet_master_id` — the device ID the ComfoBox uses on the MSTP bus (usually `1`)
- `bacnet_client_id` — the ID this bridge uses on the bus; must be **different** from the master ID (default `3`)

When the bridge connects successfully, the ComfoBox display will show an **hourglass symbol** — confirming an active BACnet client is present on the bus.

## MQTT Topics

After startup, all ComfoBox values are published under the configured base topic, for example:

```
ComfoBox/Climate/ActualTemperature_WaterHeater
ComfoBox/Climate/SetPoint_RoomTemperature
ComfoBox/Ventilation/FanSpeed
ComfoBox/Special/NumberOfWritesPer24h
```

Writable values accept commands via the `/Set` suffix:

```
ComfoBox/Climate/SetPoint_RoomTemperature/Set  →  21.5
```

> ⚠️ RF77 writes values to the EEPROM of the ComfoBox. The EEPROM has a limited write cycle life (~1,000,000 writes). Avoid automations that write values at high frequency.

A full topic list is available in the [RF77 documentation](https://github.com/RF77/comfobox-mqtt/blob/master/docs/topics.md).

## Troubleshooting

Check the add-on log under **Settings → Add-ons → ComfoBox MQTT Bridge → Log**.

| Log message | Cause | Fix |
|---|---|---|
| `PTY not ready after 15s` | Cannot reach Waveshare adapter | Check IP, port and network connectivity |
| `Exception connecting to the broker` | Wrong MQTT host/port or credentials | Verify `mqtt_host`, `mqtt_port`, `mqtt_user`, `mqtt_pass` |
| `Didn't get any messages from the Bacnet Master` | BACnet communication failure | Check baudrate and BACnet IDs match the ComfoBox OEM settings |
| `mono crashed` | Runtime error | Check full log for the exception detail above this message |

## Credits & Licensing

This add-on bundles a pre-compiled binary from **[RF77/comfobox-mqtt](https://github.com/RF77/comfobox-mqtt)** — the actual BACnet/MSTP to MQTT bridge written in C#/.NET by RF77. Without this work, this add-on would not exist.

| Component | Author | License |
|---|---|---|
| `ComfoBox2Mqtt_0.4.0.zip` (bundled binary) | [RF77](https://github.com/RF77) | [Eclipse Public License v1.0](https://www.eclipse.org/legal/epl-v10.html) |
| Add-on wrapper (run.sh, Dockerfile, config.yaml, …) | ptpat | MIT |

See [NOTICE](./NOTICE) and [LICENSE-RF77](./LICENSE-RF77) for full license texts.
