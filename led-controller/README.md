# led-controller — the channel-button wall (built)

28 SK6812 RGBW LEDs driven by an **Arduino Nano Every**, fed by a host bridge on
the rig box that turns live WIDS detections into light: when an attack fires, the
**channel button** and the **matching signature LED** flare together, coloured by
severity; per-channel occupancy sets a dim "this channel is busy" glow.

```
MQTT (wids/events/#, wids/occupancy/#)
   └─ wids-led-bridge (rig box, Python) ── USB serial ──► Nano Every ──► 28x SK6812
        maps channel/type→LED, severity→colour, '>'-gated so nothing drops
```

## Wiring (chain index 0 = closest to the board)

- **#0–7 signatures:** auth-flood, probe-watch, karma, handshake, evil-twin,
  beacon-flood, deauth(-hit), deauth-flood
- **#8–27 channels:** 165, 161, 157, 153, 104, 108, 112, 149, 100, 64, 60, 56,
  40, 44, 48, 52, 36, 11, 6, 1

Data: Nano **D6 → 470 Ω → strip DIN**. Power: external 5 V **≥3 A to the strip
only** (head + tail if needed) — never to the Nano's 5 V pin; Nano is USB-powered;
grounds common. The map lives in the **bridge** (`TYPE_LED` / `CHAN_LED`), so a
rewire is a one-line Python edit, not a reflash.

## Firmware (`firmware/wids_led/`)

A dumb renderer: each LED = ambient white glow + a decaying coloured flare. Line
protocol over USB serial @115200:

```
F <i> <r> <g> <b> <w> <ms>   flare LED i to RGBW, fade over <ms>
A <i> <level>                idle white glow for LED i (0-255)
C                            clear all
```

After every refresh the firmware emits a **`>` ready-prompt**. The refresh
disables interrupts for ~1 ms (NeoPixel requirement) and would drop a serial byte
arriving then — so the host only sends in the gap right after a `>`. That
handshake is what makes it lossless.

**Flash it** (from a machine with the toolchain — see below):
```bash
arduino-cli upload -p /dev/ttyACM0 --fqbn arduino:megaavr:nona4809 firmware/wids_led
```
`firmware/bringup` (walking-dot + RGBW test, standalone) and `firmware/dimtest`
are diagnostics for bring-up.

## Bridge (`bridge/wids-led-bridge`)

Runs on the rig box. Subscribes to the bus and drives the wall.

```bash
wids-led-bridge              # live: MQTT → serial LED wall
wids-led-bridge --dry-run    # live MQTT, but PRINT commands (no serial) — great for testing
wids-led-bridge --demo       # synthetic events → serial (no MQTT), to exercise the wall
```

Config under `led:` in `wids.yaml` (serial port, `flare_ms`, occupancy scaling,
`cmds_per_frame`). Severity → colour: red (sev ≥7), amber (4–6), calm blue-white
(≤3, using the white die).

## Deploying to the rig box

The Nano Every plugs into the **rig box** (an inch away — USB, not WiFi). Then:

```bash
# on the rig box:
#  - /etc/udev/rules.d/71-wids-led.rules  -> stable /dev/wids-led symlink
#  - /usr/local/sbin/wids-led-bridge      -> the bridge
#  - /etc/systemd/system/wids-led-bridge.service
sudo systemctl enable --now wids-led-bridge
```

The service **waits** for `/dev/wids-led`, so you can enable it before the board
is attached — it connects the moment you plug the Nano Every in. `wids-healthcheck`
reports it.

## Toolchain (flashing station)

`arduino-cli` + the `arduino:megaavr` core + Adafruit NeoPixel:
```bash
arduino-cli core install arduino:megaavr
arduino-cli lib install "Adafruit NeoPixel"
```

## Hard-won notes

- **Board:** started on an OSOYOO LGT-Nano (LGT8F328P) — abandoned it: hopeless to
  reflash (sync failures, false "successes", needs a power-cycle per flash) and its
  marginal signal was likely the dim strip tail. The Nano Every (genuine Arduino)
  flashes reliably; its onboard debugger occasionally wants one retry — normal.
- **Charge-only USB cables** cost hours: the board powers (LED on) but never
  enumerates. Use a known **data** cable.
- **Never** tie the PSU +5 V to the Nano's 5 V pin (drags strip current through the
  Nano and fights USB power).
- Far-end **red/dim on white** = voltage droop → feed 5 V at the tail too.

## Extensibility

`wids/stats/dominant` is already published (by `wids-video`) — a future
7-segment "hottest channel" display can read it with no server changes. More LEDs
(a volume bar) append to the same chain; the firmware is index-agnostic.
