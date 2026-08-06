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
led-controller/  Arduino Nano Every firmware + host bridge for the 28-LED
                 channel/signature wall (built).
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
      │        ├──> LED wall    (led-controller/: Nano Every, 28 SK6812)
      │        └──> TV wall     (wids-video: channel-surfing HDMI display)
      ├──> Prometheus  :9924     low-cardinality aggregates
      └──> Redis / SQLite        bounded top-K + hourly rollups

 wids-chanctl ─ parks "tracker" radios on the busiest channels (dynamic 5 GHz)
```

## What it detects

The rig only ever *listens* — it reasons entirely from 802.11 **management and
control frames** in the air (beacons, probe requests/responses, deauth/disassoc,
auth/assoc, and EAPOL handshake frames). Payloads are never touched or stored;
frame bodies are dropped the moment features are extracted. Over sliding time
windows it flags:

| Signature | What it is | Frames it reads |
|---|---|---|
| **Deauth / disassoc flood** | forged frames kicking clients off a network | deauth (0x0C) / disassoc (0x0A) |
| **Beacon flood** | a blast of fake APs (mdk4-style) | beacons with novel BSSIDs |
| **Evil twin** | a network's SSID beaconed by a second, *different-vendor* BSSID | beacons |
| **Karma AP** | one radio answering probes for many different SSIDs | probe responses |
| **Handshake seen** | a WPA 4-way / EAPOL capture happening nearby | EAPOL |
| **Probe watch** | a client probing for a watch-listed SSID (corp/con/target) | probe requests |
| **Auth / assoc flood** | connection-request spam against an AP | auth / assoc requests |
| **Channel occupancy** | how hot each channel's air is (not an alert — the ambient signal) | all frames |

Each detection becomes a small JSON event on `wids/events/<TYPE>` (channel,
severity, source vendor, target, rate, …). Kismet's own WIDS alerts are
normalized onto the same schema. MACs/SSIDs are kept as aggregate top-K, not
per-person logs.

## The TV: channel surfing

The rig drives an HDMI display (a tiny CRT in the reference build) that literally
**changes the channel to wherever the action is.** You drop one video per Wi-Fi
channel into `/var/lib/wids/videos/` (named `36.mp4`, `149.mkv`, …); the rig
tracks the **dominant channel** — the one with the most detections over a rolling
window — and plays its video. When a *different* channel takes over, the TV
switches like flipping channels — and **resumes each video where it left off**,
never restarting from zero, so returning to a channel picks up mid-scene. A
`SCANNING` clip covers quiet moments. (Built on mpv over DRM/KMS, no desktop;
details in [server/README.md](server/README.md) §8b.)

The **LED wall** is the other half of the same signal: 28 SK6812 RGBW on an
Arduino Nano Every, where each Wi-Fi channel and each attack type has a button —
an event flares the channel *and* its signature LED together, coloured by
severity, over a dim glow that tracks how busy each channel is
([led-controller/README.md](led-controller/README.md)).

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
- An Arduino Nano Every driving 28 SK6812 RGBW LEDs for the channel/signature
  wall, and an HDMI display for the channel-surfing video.

Exact radios are deployment-specific; `server/README.md` documents the reference
build and `wids-add-radio` provisions new capture sticks.

## License

GPLv3 — see [LICENSE](LICENSE).

## Status

Server rig: built and running (7 capture radios, dynamic 5 GHz scout/tracker).
Video wall: built — the HDMI/CRT channel-surfs to the dominant Wi-Fi channel,
resuming each clip where it left off (`server/README.md` §8b). LED wall: built —
28 SK6812 RGBW on an Arduino Nano Every; attacks flare the channel button + its
signature LED, driven from the bus by `wids-led-bridge` (`led-controller/README.md`).
