# led-controller (seam — not yet built)

The LED wall: a row of **per-channel buttons** (SK6812 RGBW) that light when the
rig detects activity on the matching Wi-Fi channel. An ESP32 drives the LEDs
over FastLED; a small host-side bridge subscribes to the MQTT bus and feeds the
ESP32 over USB serial.

This directory is a **documented seam**. The contract below is stable; the
firmware and the bridge are not written yet.

## Encoding (the design)

Three independent perceptual axes carry three things at once — no need to choose:

| Axis | Encodes | How |
|---|---|---|
| **Position** (which button) | Wi-Fi channel | one LED per monitored channel |
| **Brightness / flare** | activity + recency | events flare the button, then decay; a sustained flood pins it lit |
| **Hue** | severity | short, legible ramp — **not** a rainbow |

Severity ramp (colourblind-robust — avoids red/green):

```
calm white/blue  ──►  amber  ──►  red
 low sev (1-3)       mid (4-6)    attack (7-10)
```

The SK6812's dedicated **white** die is used for the idle "armed" glow and for
brightness, leaving RGB for the severity hue. Idle = soft white breathing, so a
button reads as alive-and-watching rather than dead-black.

Detection **type** is deliberately *not* mapped to hue (too many types, too few
distinguishable colours). If wanted later, type maps to **motion** — a fourth
axis that doesn't fight severity: deauth-flood strobes, beacon-flood shimmers,
karma slow-pulses.

## Which buttons exist

Only channels the rig actually monitors get a button. The reference build shows
**~12 non-DFS buttons** (2.4 GHz `1/6/11` + 5 GHz UNII-1 `36/40/44/48` + UNII-3
`149/153/157/161/165`); DFS channels are optional. See `server/config/radios.conf`
for the live channel set. The button→LED-index mapping lives in the firmware so
the physical layout stays a firmware concern.

## Data contract — MQTT (in)

Subscribe to the same bus the rest of the rig uses (default `10.42.0.1:1883` on
the management AP subnet, or `127.0.0.1:1883` on the box):

- `wids/events/<TYPE>` — one JSON detection per message. Relevant fields:
  `channel` (int), `severity` (1–10), `type` (string). Full schema in
  `server/README.md` §5.
- `wids/occupancy/<channel>` — retained gauge, `{channel, frames_per_s,
  mgmt_frames_per_s}`. Drives the ambient baseline glow per button.

## Serial contract — host bridge → ESP32

Newline-delimited JSON, 115200 baud, so the firmware never parses MQTT:

```
{"cmd":"flare","ch":6,"type":"DEAUTH_FLOOD","sev":8,"ms":400}\n
{"cmd":"ambient","ch":36,"level":0.42}\n
{"cmd":"clear"}\n
```

- `flare` — momentary bright pulse on channel `ch`, hue from `sev`, duration `ms`.
- `ambient` — set the baseline glow for channel `ch` (`level` 0.0–1.0), driven by
  occupancy.
- `clear` — all LEDs to idle.

## To build later

- `bridge/` — a `paho-mqtt` subscriber that maps events/occupancy → the serial
  lines above (`pyserial`). Runs on the rig box or any bus subscriber.
- `firmware/` — ESP32 + FastLED sketch: read serial lines, keep a per-channel
  state (idle glow + decaying flares), map channel → LED index.

Nothing here depends on the server internals — it's a hot-swappable bus consumer.
Adding it requires **no** change to the server code.
