# WiFi capture / WIDS rig — phase 1

Passive multi-radio 802.11 monitoring rig. Listens to management/control
frames, flags attack signatures, streams detections onto MQTT, and keeps
aggregate metrics. Built on Ubuntu 26.04 (`resolute`), host `<hostname>`
(`<BOX_LAN_IP>`).

**Passive by construction.** Nothing here injects, deauths, or associates from
a monitoring radio. Packet payloads are never written to disk — only frame
headers and management-frame contents are parsed, and frame bodies are dropped
after feature extraction.

---

## 1. Interfaces and roles

| Interface | PHY | Driver / chipset | Bands | Monitor | Role |
|---|---|---|---|---|---|
| `enp1s0` | — | `r8169` Realtek PCIe | — | n/a | LAN uplink (<BOX_LAN_IP>) |
| `wlp2s0` | phy0 | `ath10k_pci` QCA6174 (built-in PCIe) | 2.4 + 5 GHz | capable, **never used** | Management AP (10.42.0.1) |
| `mon2` | phy… | `ath9k_htc` AR9271 (USB) | 2.4 GHz only | yes | Capture — pinned ch 1 |
| `mon3` | phy… | `ath9k_htc` AR9271 (USB) | 2.4 GHz only | yes | Capture — pinned ch 6 |
| `mon4` | phy… | `ath9k_htc` AR9271 (USB) | 2.4 GHz only | yes | Capture — pinned ch 11 |
| `mon0` | phy… | `mt76x2u` MT7612U (USB) | 2.4 + 5 GHz | yes | Capture — hop UNII-1 (36–48) |
| `mon1` | phy… | `mt76x2u` MT7612U (USB) | 2.4 + 5 GHz | yes | Capture — hop UNII-3 (149–165) |
| `mon5` | phy… | `mt76x2u` MT7612U (USB) | 2.4 + 5 GHz | yes | Capture — **scout**, sweeps DFS |
| `mon6` | phy… | `mt76x2u` MT7612U (USB) | 2.4 + 5 GHz | yes | Capture — **tracker** (wids-chanctl) |

`wlp2s0` was confirmed as the built-in radio via `lspci` (PCIe QCA6174) before
anything was configured. It is excluded from every monitor-mode path, by name,
in `wids-monitor-setup` and in the Kismet source list.

**Channel plan rationale (7 capture radios).** The three 2.4 GHz-only AR9271s
pin the non-overlapping channels 1/6/11, so that band is never unwatched. The
four MT7612Us cover 5 GHz: **mon0/mon1 hop the non-DFS blocks** (UNII-1 and
UNII-3, where APs actually live); **mon5 is a scout** that sweeps the DFS range
(52–64 + 100–144, including the TDWR band 120–128 that matters near an airport);
**mon6 is a tracker** that `wids-chanctl` dynamically parks on whichever DFS
channel is hottest. Edit `/etc/wids/radios.conf` to change roles. See the
scout/tracker section under Operating.

### AR9271 firmware — read this before re-imaging

Ubuntu 26.04 does **not** ship `ath9k_htc/htc_9271-1.4.0.fw`; it is absent from
`linux-firmware-qualcomm-wireless`. Without it the three AR9271 dongles
enumerate on USB but never create a network interface (`dmesg` shows
`Direct firmware load ... failed with error -2`).

The firmware was retrieved from the upstream kernel.org `linux-firmware` repo
(where it still exists at HEAD) and installed to `/lib/firmware/ath9k_htc/`.
Plain files, no service depends on them, and they survive reboots — but a
**fresh OS install will need this step repeated**:

```bash
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git /tmp/lfw
sudo mkdir -p /lib/firmware/ath9k_htc
sudo cp /tmp/lfw/ath9k_htc/htc_9271-1.4.0.fw /tmp/lfw/ath9k_htc/htc_7010-1.4.0.fw /lib/firmware/ath9k_htc/
sudo modprobe -r ath9k_htc && sudo modprobe ath9k_htc
```

If the dongles were already plugged in when the driver first failed, they need
a USB re-enumerate (unplug/replug, or unbind/bind in `/sys/bus/usb/drivers/usb`).

---

## 2. Management AP

Out-of-band access so the rig is reachable even with no LAN.

- SSID: `example wids ssid`
- WPA2-PSK, random 43-character passphrase (`secrets.token_urlsafe(32)`) set 2026-08-01
- `10.42.0.1/24` static, dnsmasq leases `10.42.0.10–200`
- `sshd` listens on all interfaces, so `ssh 10.42.0.1` works once associated
- Management-only by default: **no NAT**, no route to the LAN

> **The original SSID did not fit.** `openai agent looking for huggingface` is
> 36 bytes and 802.11 caps SSIDs at 32. It was shortened to
> `example wids ssid` (exactly 32). Change it in
> `/etc/hostapd/hostapd.conf` — anything longer will make hostapd refuse to start.

Read the current PSK (to join a device to the AP):

```bash
sudo grep '^wpa_passphrase=' /etc/hostapd/hostapd.conf
```

Rotate it:

```bash
sudo sed -i "s|^wpa_passphrase=.*|wpa_passphrase=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')|" /etc/hostapd/hostapd.conf
sudo systemctl restart hostapd
```

`sed -i` on this file leaves no backup by design — a `.bak` would keep the old
passphrase readable on disk.

To optionally NAT the AP out to the LAN (off by default):

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft add table nat
sudo nft 'add chain nat postrouting { type nat hook postrouting priority 100 ; }'
sudo nft add rule nat postrouting oifname enp1s0 masquerade
```

---

## 3. Architecture

```
radios (mon0-4, monitor mode, pinned/hopping)
    |
    v
Kismet  ── owns radios, hopping, per-source state
    |          logging to disk DISABLED (enable_logging=false)
    |
    ├── live pcapng stream  (HTTP, in memory, never to disk)
    └── its own WIDS alert engine (DEAUTHFLOOD, APSPOOF, KARMAOUI, ...)
    |
    v
wids-detect  ── sliding-window signature detection, config-driven thresholds
    |
    ├──> MQTT  (Mosquitto)      -> LED bridge, TV display  [SEAMS, unbuilt]
    ├──> Prometheus :9924       -> Grafana                 [SEAM, unbuilt]
    ├──> Redis sorted sets      -> bounded top-K
    └──> SQLite hourly rollups  -> cross-con history
```

### Why Kismet, and what changed

Kismet is the capture engine as specified. It is **not** in the Ubuntu 26.04
archive, so it is installed from Kismet's official APT repo pinned to `plucky`
(25.04 — the newest they publish). Two guardrails on that:

- The repo's signing key is scoped with `Signed-By` to that source only.
- `/etc/apt/preferences.d/99-kismet` pins the origin to priority 100, so it can
  supply packages Ubuntu lacks but can **never** override an Ubuntu package.

Dependencies resolve cleanly against 26.04. Only WiFi capture packages are
installed, not the full SDR/Zigbee/Ubertooth metapackage.

---

## 4. Configuration

| Path | What |
|---|---|
| `/etc/wids/wids.yaml` | **All detection config** — thresholds, windows, watchlist, ignore list |
| `/etc/wids/radios.conf` | Radio → channel plan (pin vs hop) |
| `/etc/wids/kismet.creds` | Kismet REST credential, mode 0600, generated on-box |
| `/etc/kismet/kismet_site.conf` | Kismet sources + logging disabled |
| `/etc/hostapd/hostapd.conf` | AP SSID/PSK |
| `/etc/dnsmasq.d/wlp2s0-ap.conf` | AP DHCP scope |
| `/etc/mosquitto/conf.d/wids.conf` | Bus listeners |
| `/etc/udev/rules.d/70-wids-monitor-names.rules` | MAC → stable `monN` names |
| `/var/lib/wids/rollups.db` | Hourly aggregates |

The Kismet credential is generated at install with `secrets.token_urlsafe(32)`,
stored 0600, and never logged. Rotate it by editing `/etc/wids/kismet.creds`
and `/root/.kismet/kismet_httpd.conf`, then restarting both services.

---

## 5. Event schema

One JSON object per detection, published to `wids/events/<TYPE>`:

```json
{
  "ts": "2026-08-01T09:41:48.320230+00:00",
  "type": "DEAUTH_HIT",
  "severity": 3,
  "channel": 1,
  "src_mac": "8c:8b:5b:5b:0b:ca",
  "src_oui": "8C:8B:5B",
  "vendor": "",
  "target_mac": "dc:72:23:78:91:af",
  "count": 5,
  "rate": 0.5,
  "window_s": 10,
  "frame_category": "deauth",
  "broadcast": false
}
```

`frame_category` is the 802.11 action that produced the event (`deauth`,
`disassoc`, `beacon`, `probe_req`, `probe_resp`, `auth`, `assoc_req`, `eapol`,
`alert`). Optional fields appear per type: `ssid`, `bssids`, `distinct_ouis`,
`ssids`, `matched`, `detail`, `origin`, `kismet_alert`.

### Detection types

| Type | Fires when | Default |
|---|---|---|
| `DEAUTH_HIT` | A single targeted deauth/disassoc | severity 3 |
| `DEAUTH_FLOOD` | ≥20 deauths/target/sec sustained | severity 8 |
| `BEACON_FLOOD` | ≥30 novel BSSIDs on one channel in 30s | severity 7 |
| `EVIL_TWIN` | One SSID on ≥3 BSSIDs **from ≥2 vendors** | severity 6 |
| `KARMA_AP` | One BSSID probe-responding for ≥5 SSIDs | severity 7 |
| `AUTH_FLOOD` | ≥30 auth/assoc requests at one BSSID in 10s | severity 6 |
| `HANDSHAKE_SEEN` | EAPOL / 4-way handshake observed | severity 2 |
| `PROBE_WATCH` | Probe request matching the operator watchlist | severity 4 |
| `KISMET_*` | Kismet alerts with no direct mapping | severity 5 |

> **On `EVIL_TWIN`:** BSSID count alone false-positives constantly — dual-band
> APs, mesh kits and enterprise deployments all legitimately put one SSID on
> many BSSIDs. The detector additionally requires hardware from *different
> vendors* (distinct OUIs). Both behaviours are covered by the self-test.

Kismet's own alerts are normalized onto the same schema with `"origin":
"kismet"`. Its `SYSTEM`-class alerts (Kismet talking about itself) are dropped.

### Topics

| Topic | Retained | Payload |
|---|---|---|
| `wids/events/<TYPE>` | no | One detection, schema above |
| `wids/occupancy/<channel>` | yes | `{ts, channel, frames_per_s, mgmt_frames_per_s, window_s}` |
| `wids/stats/rollup` | yes | `{ts, events_by_type, top_macs, top_ssids, top_probed_ssids, top_attacked_bssids}` |

Bus listeners: `127.0.0.1:1883` and `10.42.0.1:1883` (AP subnet). Deliberately
**not** exposed on the LAN uplink.

---

## 6. Metrics

Prometheus exporter on `:9924`.

| Metric | Labels | Meaning |
|---|---|---|
| `wids_events_total` | `type`, `channel` | Detections emitted |
| `wids_frames_total` | `type` | **Every** frame by category, alert or not |
| `wids_events_by_hour_total` | `type`, `hour` | Hour-of-day breakdown (0–23) |
| `wids_channel_occupancy` | `channel` | Frames/sec — "how hot is the air" |
| `wids_channel_mgmt_rate` | `channel` | Mgmt frames/sec |
| `wids_capture_stream_up` | — | 1 = frame stream connected |
| `wids_kismet_alertbus_up` | — | 1 = Kismet alerts reachable |

Per-MAC and per-SSID detail is deliberately **not** a Prometheus label
(unbounded cardinality). It lives in Redis sorted sets, trimmed to `topk_size`:

```
wids:topk:macs             most-seen source MACs
wids:topk:ssids            most-advertised SSIDs
wids:topk:probed_ssids     most-probed SSIDs
wids:topk:attacked_bssids  most-targeted BSSIDs
```

The rig's own AP MAC is auto-excluded (it beacons on a monitored channel and
would otherwise win every chart). Add more via `ignore_macs` in `wids.yaml`.

SQLite hourly rollups at `/var/lib/wids/rollups.db` — tables `hourly`
(type counts) and `hourly_topk`. Aggregates only, never rows of raw
observations.

---

## 7. Operating

```bash
sudo wids-healthcheck        # green/red across the whole stack, exit 0 = all good
sudo wids-selftest           # 28 synthetic-frame checks of the detection logic
wids-watch                   # live, readable event stream
sudo wids-replay foo.pcap    # run captured frames through the detectors
sudo wids-reset              # wipe accumulated state for a clean slate
sudo wids-add-radio          # provision a newly plugged capture stick
journalctl -u wids-chanctl -f  # watch dynamic channel decisions
curl -s localhost:9924/metrics | grep wids_
journalctl -u wids-detect -f
```

### Clean slate on arrival at a venue

`wids-reset` wipes everything the rig has accumulated, so data from home (or the
last con) doesn't clutter this venue's numbers. Run it once you arrive:

```bash
sudo wids-reset            # prompts, then clears everything below
sudo wids-reset --yes      # no prompt
sudo wids-reset --purge    # delete the SQLite rollups instead of archiving
sudo wids-reset --kismet   # also restart Kismet, dropping its device list
```

What it resets, in order (daemon is stopped first so nothing races the clears):

| Store | Action |
|---|---|
| Redis top-K (`wids:*`) | Cleared. Only the rig's own namespace is touched — never a blanket flush. |
| SQLite hourly rollups | **Archived** to `rollups.db.archived-<timestamp>` by default (your home baseline is preserved but out of the active data); deleted with `--purge`. |
| Retained MQTT gauges | `wids/occupancy/*` and `wids/stats/*` retained values cleared. |
| Prometheus counters + sliding windows | Reset by restarting `wids-detect`. |
| Kismet device list | Only with `--kismet` (in-memory; a restart drops it). |

Fresh data starts accumulating the moment the daemon comes back — so at the
venue, top-K and counters immediately begin filling with con traffic from zero.

### Dynamic channel control (scout / tracker)

Radios have a **role** in `/etc/wids/radios.conf` (column 4):

| Role | Behaviour |
|---|---|
| `pin` | Fixed channel, held by setup + watchdog; Kismet source is non-hopping. |
| `hop` | Kismet hops the listed channels. |
| `scout` | Same as hop, but its sweep is the ranking signal for trackers. |
| `tracker` | Channel owned by **`wids-chanctl`** — parked on the busiest channel in its pool. Setup/watchdog leave it alone; its Kismet source is non-hopping. |

`wids-chanctl` reads per-channel occupancy off the bus and moves each tracker to
where the action is, with anti-flap hysteresis (`min_dwell_s`, `move_margin`) and
a `quiet_floor` that releases a channel that's gone dead. All knobs live under
`chanctl:` in `wids.yaml`.

It **ships in `dry_run: true`** — it logs the moves it *would* make but touches
nothing, and with no `tracker` radios present it just idles. So it's inert on the
current 5-radio rig. Watch its reasoning:

```bash
journalctl -u wids-chanctl -f
```

Why this design (from the build):
- **Actuation is `iw`, not Kismet's REST** — Kismet's `set_channel` 500s on the
  mt76 driver; `iw` retunes DFS and non-DFS fine, and Kismet does not fight the
  channel of a non-hopping source (verified: a manually-moved pinned source held
  its channel until *our own watchdog* reset it — which is why tracker radios are
  exempt from watchdog channel-pinning).

### Adding more capture radios

The reference build runs 7 capture radios (see §1) with `mon5`/`mon6` as the
scout + DFS tracker, and `wids-chanctl` live (`dry_run: false`). To add another
5 GHz stick to a running rig, plug in **one** at a time, then:

```bash
sudo wids-add-radio            # detects the new interface, prompts role + pool
```

It assigns the next `monN` name, writes the udev rule, `radios.conf`, and the
Kismet source, then reloads and restarts the capture stack. Repeat for the second
stick. The exact target roles/pools are in the commented block at the bottom of
`radios.conf`. Then activate tracking:

```bash
sudo sed -i 's/dry_run: true/dry_run: false/' /etc/wids/wids.yaml
sudo systemctl restart wids-chanctl
sudo wids-healthcheck
```

`wids-add-radio --pretend ...` shows what it would do without changing anything.

### Watching the stream

```bash
wids-watch                        # all events, colourised by severity
wids-watch --type DEAUTH_FLOOD    # one type (repeatable)
wids-watch --min-severity 6       # only the loud stuff
wids-watch --occupancy            # include per-channel gauges
wids-watch --rollup               # include rollup snapshots
wids-watch --raw | jq .           # raw JSON for piping
```

Raw equivalent, no tooling: `mosquitto_sub -h 127.0.0.1 -t 'wids/#' -v`.
Remote consumers use `-h 10.42.0.1` from the AP subnet.

### Testing against different packets

```bash
sudo wids-replay capture.pcap             # replay a file, show what fires
sudo wids-replay capture.pcapng --speed 1 # honour original inter-frame timing
sudo wids-replay --from-air 30            # tap 30s of the live Kismet stream
sudo wids-replay capture.pcap --publish   # also push results onto the real bus
```

`wids-replay` runs frames through the exact same `Detectors` class the daemon
uses, so a result here is a real result. It transmits nothing and touches no
radio. Point it at a lab capture, a public sample, or something you recorded
against your own kit.

> **Timing caveat:** detectors use sliding *wall-clock* windows. Replaying
> faster than real time compresses frames into one window, so rate thresholds
> (`DEAUTH_FLOOD`, `AUTH_FLOOD`, `BEACON_FLOOD`) trip more readily than they
> would live. Use `--speed 1` when you care about faithful rates.

`wids-selftest` is the other half: it synthesises frames for every signature
and asserts correct attribution, including that `EVIL_TWIN` does *not* fire on
single-vendor multi-BSSID APs.

To generate genuinely hostile traffic you need a **separate** transmitting
radio aimed at **your own** AP and clients — this rig stays passive and has no
injection path, deliberately.

### Service order

```
wids-monitor.service      (oneshot, waits up to 60s for USB radios)
   -> kismet.service      (Requires=wids-monitor)
      -> wids-detect.service
         -> wids-chanctl.service   (dynamic channel control; idle until trackers exist)
hostapd + dnsmasq         (independent, first)
mosquitto, redis-server   (independent)
```

`wids-monitor-watchdog.timer` re-asserts monitor mode every 60s, recovering any
radio that drops out or re-enumerates. Verified by forcing a radio back to
managed mode and watching it get restored.

> **Boot-order gotcha, already fixed:** USB radios enumerate several seconds
> after systemd starts, and `ath9k_htc` loads firmware first. The original
> oneshot ran before any radio existed and silently configured nothing. It now
> polls up to 60s (`--wait 60`). Verified across three cold reboots.

---

## 8. Verification performed

- Cold reboot ×3, untouched: all radios return in monitor on assigned channels, AP up, full stack green
- Watchdog: radio forced to managed mode, restored automatically
- AP beacon captured by one of the rig's own monitor radios (end-to-end proof)
- `wids-selftest`: 28/28 detector checks, including evil-twin false-positive suppression
- Live detection with correct attribution against real ambient traffic
- No `.pcap`/`.pcapng`/`.kismet` capture files anywhere on disk
- AP re-verified after the PSK was set: own beacon re-captured on `mon3`, `PRIVACY` bit still set

---

## 9. Seams for phase 2 — documented, deliberately unbuilt

### 9.1 LED bridge (ESP32 over USB serial)

An independent MQTT subscriber. Nothing in this rig needs to change to add it.

**Subscribe:** `wids/events/#` and `wids/occupancy/#`

**Suggested mapping:**

| Input | Visual |
|---|---|
| `channel` | Which pixel/region flares |
| `type` | Hue (e.g. deauth = red, karma = violet, handshake = amber) |
| `severity` (1–10) | Brightness / flare intensity |
| `wids/occupancy/<ch>` `frames_per_s` | Ambient baseline glow per channel |

**Proposed serial contract** — newline-delimited JSON at 115200 baud, host →
ESP32, so the firmware never parses MQTT:

```
{"cmd":"flare","ch":6,"type":"DEAUTH_FLOOD","sev":8,"ms":400}\n
{"cmd":"ambient","ch":36,"level":0.42}\n
{"cmd":"clear"}\n
```

Sketch: `paho-mqtt` subscriber → `pyserial` → FastLED. Map channel → LED index
with a lookup table so the physical layout stays a firmware concern. **No
hardware wired, no firmware written.**

### 9.2 TV / wall display

A second independent subscriber. Two data paths, both already live:

- **MQTT** `wids/#` for the real-time feed (`wids/stats/rollup` is retained, so
  a display that joins late gets state immediately)
- **Prometheus** `:9924` for time series → Grafana; **Redis** `wids:topk:*` for
  the leaderboards

Suggested panels: per-channel occupancy heatmap, events-by-type over time,
hour-of-day activity, top-N most-probed SSIDs and most-attacked BSSIDs, live
event ticker. Grafana is **not installed**; no datasource is provisioned and no
frontend is built.

### 9.3 BLE (fast-pair / AirTag popup spam)

Needs a Bluetooth radio, not these WiFi ones. `hci0` exists on this box and
`kismet-capture-linux-bluetooth` is installed as a Kismet dependency, but
**nothing is configured**. Adding it means a new Kismet source, new detector
methods in `wids_detect.py`, and new event types. Left as a TODO seam.

---

## 10. Known gaps

- AP client association was verified at the protocol level (beacons captured,
  `sshd` answering on `10.42.0.1`) but **no physical client has associated** —
  that needs a phone/laptop at the venue.
- Thresholds in `wids.yaml` are starting points calibrated against a quiet
  residential RF environment. A con floor is far noisier; expect to raise
  `beacon_flood.novel_bssid_threshold` and `deauth.flood_rate`.
- DFS 5 GHz channels are in the hop list. They work passively, but some
  regulatory domains may refuse them — check the hop coverage at the venue.
- `wids-detect` parses frames in Python. Fine at observed rates; a very hot
  channel could drop frames. `wids_capture_stream_up` will stay 1 — watch
  `wids_frames_total` rate for plateaus if you suspect saturation. The two
  costs per frame are scapy dissection (dominant) and a Redis `ZINCRBY` for the
  most-seen-MAC top-K; if a con floor ever saturates it, batching the top-K
  writes is the first lever. Detector state is guarded by a single lock so the
  frame thread and the occupancy/sweep thread can't corrupt the sliding
  windows — verified, but it does mean a slow Redis call briefly stalls the
  occupancy publish (harmless).
