# wid-dle-wemote

A passive multi-radio Wi-Fi intrusion-detection rig, built as a DEF CON-style
security-art installation. It listens to 802.11 management/control frames in the
air, flags known attack signatures (deauth floods, evil twins, karma APs,
handshakes, beacon floods, …), streams those detections onto an MQTT event bus,
and keeps privacy-minded aggregate metrics — all feeding an LED wall and a TV
dashboard.

**Passive by design.** Nothing here transmits, injects, deauths, or associates
from a monitoring radio. Packet *payloads* are never written to disk — only
frame headers and management-frame contents are parsed, and frame bodies are
dropped after feature extraction.

> The `AA:BB:CC:00:00:0N` MAC addresses and the `CHANGE_ME_PSK` passphrase in
> the configs are **placeholders**. Real per-deployment values (radio MACs, the
> AP passphrase, the Kismet API credential) are filled in / generated on the box
> at install time and are deliberately kept out of this repo.

## Layout

```
server/          The rig itself — capture, detection, event bus, metrics.
  bin/           Daemons and operator tools (installed to /usr/local/sbin).
  config/        /etc configuration (Kismet, hostapd, dnsmasq, wids, udev, …).
  systemd/       Unit files and drop-ins.
  install.sh     Places everything and generates on-box secrets.
  README.md      Full operator manual — architecture, tuning, runbooks.
led-controller/  ESP32 + FastLED firmware for the channel-button wall.
                 (Seam: the contract is documented; firmware not yet built.)
```

## Architecture at a glance

```
capture radios (monitor mode; pinned / hopping / dynamically tracked)
      |
   Kismet ─ owns radios + channel hopping; live frame stream + its WIDS alerts
      |            (no pcap logging to disk)
      v
 wids-detect ─ sliding-window signature detection, config-driven thresholds
      |
      ├──> MQTT (Mosquitto)      wids/events/#, wids/occupancy/#, wids/stats/#
      │        ├──> LED controller   (this repo, led-controller/)
      │        └──> TV / Grafana wall
      ├──> Prometheus  :9924     low-cardinality aggregates
      └──> Redis / SQLite        bounded top-K + hourly rollups

 wids-chanctl ─ parks "tracker" radios on the busiest channels (dynamic 5 GHz)
```

## Quick start (server)

On a Ubuntu box with the capture radios plugged in:

```bash
cd server
sudo ./install.sh
```

Then set the AP passphrase and bring it up — see [server/README.md](server/README.md),
which is the full manual (hardware table, channel plan, detection tuning,
operator tools, cold-boot behaviour, and the LED/TV seam contracts).

## Hardware

- A Ubuntu server with a built-in Wi-Fi radio (management AP) + several USB
  Wi-Fi adapters for capture (ath9k_htc / mt76 work well in monitor mode).
- Wired ethernet uplink.
- (Later) an ESP32 driving SK6812 RGBW LEDs for the channel-button wall.

Exact radios are deployment-specific; `server/README.md` documents the reference
build and `wids-add-radio` provisions new capture sticks.

## License

GPLv3 — see [LICENSE](LICENSE).

## Status

Server rig: built and running. LED controller: contract documented, firmware not
yet written. See `led-controller/README.md`.
