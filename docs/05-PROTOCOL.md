# 05 — Phone ↔ Watch Protocol (CONTRACT)

This file is the contract between `companion/proto/ProtocolPacker.kt` and `watch/source/comm/MessageAssembler.mc` (and `watch/source/Config.mc`, for CONFIG). Any change here = change both sides + regenerate the test vectors (`tools/packer.py`). `PROTO_VERSION = 2` (C16.5: maneuver types 14..30, §TURNS; RECENTS and the `kind` of NAV_START_REQ).

## Transport

- Phone→watch: `ConnectIQ.sendMessage`; 1 message in flight, gated by status. Default chunk **4096 B** (recalibrate in F1; the final value becomes the constant `CHUNK_SIZE` on both sides).
- Watch→phone: `Communications.transmit` (API 6.0).
- **Both directions carry the frame in Base64 inside a String.** A raw `byte[]`/`ByteArray` does not
  get through: in the P→W direction the watch receives something Monkey C cannot read, and in the W→P direction the Android SDK
  answers `FAILURE_INVALID_FORMAT` and discards it. This is a **transport** layer: the frame below, the
  fixtures and `packer.py` are identical. Cost +33% of bytes on the air (measured in `DECISIONS.md`).
- Big-endian integers. No compression (payloads are already delta-encoded; zlib does not exist in CIQ).

## Framing (every message)

```
offset  size  field
0       1     protoVersion (=2)
1       1     msgType
2       2     routeId        (uint16; increments with every new route; 0 = no route)
4       1     seq            (chunk index, 0-based)
5       1     total          (total chunks of this block)
6       2     payloadLen     (uint16)
8       N     payload
```

Reassembly on the watch: buffer per (msgType, routeId); complete when all the `seq` values have arrived → validate → apply → send `ACK`. Incomplete block timeout: 30 s with no new chunk → `ACK` with the bitmap of what arrived (the companion resends only what is missing).

**The block survives a partial ACK** (C13b). The watch keeps the chunks that arrived for another
30 s, counted from the partial ACK: without that, the resent remainder would open an empty buffer and the block
would never close. A new chunk resets the count. A second deadline in a row with no new chunk → the block is dropped
(`bloco 0xNN abandonado` in the log), with no other ACK.

**Link drop in the middle of a block** (companion, `BlockRounds`). A failing `sendMessage` ends the
**round**, not the transfer: the companion waits for the ACK for the same 8 s (the chunk may have arrived
before the send failed, or the watch may send the bitmap) and opens another round with what is not
confirmed. A round with a drop does not count toward the 3 rounds per block nor the 2 silent rounds, which protect
against a deaf watch. The ceiling is time: **60 s** since the last delivered chunk (the watch's two
deadlines), then `Watch out of reach`. In the log: `block 0xNN round k: drop at chunk i/n` and, when
it closes, `block 0xNN complete after N rounds`.

## Message types

| msgType | Name | Direction | Content |
|---------|------|-----------|---------|
| 0x01 | ROUTE_META | P→W | route meta (1 chunk) |
| 0x02 | ROUTE_POLY | P→W | route polyline (chunks) |
| 0x03 | TURNS | P→W | maneuvers (chunks) |
| 0x04 | CORRIDOR | P→W | surrounding streets (chunks, per LOD) |
| 0x05 | FAVORITES | P→W | list of favorites |
| 0x06 | ROUTE_UPDATE | P→W | light ETA/traffic update (1 chunk) |
| 0x07 | CANCEL_NAV | P→W | companion cancelled |
| 0x08 | RADARS | P→W | speed cameras along the route (1 chunk, per route; see §RADARS) |
| 0x09 | CONFIG | P→W | fine tuning without a cable (1 chunk, `routeId` 0; see §CONFIG) |
| 0x0A | PHONE_FIX | P→W | phone GPS position, while the watch asks for it (1 chunk, `routeId` 0, **no ACK**; see §PHONE_FIX) |
| 0x0B | RECENTS | P→W | the latest destinations, for the "Recentes" screen (1 chunk, `routeId` 0; see §RECENTS) |
| 0x81 | ACK | W→P | confirms a block: {msgType, routeId, receivedBitmap} |
| 0x82 | REROUTE_REQ | W→P | {lat, lon (int32 1e-5), heading (uint16 degrees), distAlongRoute (uint32 m)} |
| 0x83 | NAV_START_REQ | W→P | {favId (uint8), kind (uint8, only for a recent)} |
| 0x84 | NAV_ENDED | W→P | {reason: 0=arrived, 1=cancelled, 2=error} |
| 0x85 | LOG | W→P | UTF-8 text of the watch log (see §Diagnostic messages) |
| 0x86 | FIX_REQ | W→P | {liga (uint8): 1 = send `PHONE_FIX`, 0 = stop} |

### Diagnostic messages

`LOG (0x85)` exists because the watch has no logcat: the payload is the UTF-8 text of the new lines of the
`Diag` buffer, separated by `\n`, `routeId = 0`, ceiling of 1200 B per send. The watch sends at the end of
a transfer and when a block hits the timeout; the companion writes each line to `motonav.log`
prefixed with `WATCH|`, so both sides of the same transfer end up in the same file.

**The send cuts on whole lines** (C3b): up to 1,000 characters per message (≤ ~1,100 B, `·` takes 2 B),
the diagnostics with up to 800 of them and the track with the rest (the watch sends every 15 s). What does not fit stays pending for the next
send; nothing is cut in the middle or silently discarded. If the `Diag` ring of 24 lines overflowed before
the send, the first line of the message is `log perdeu N linhas`.

**Recorded track** (C3b): the lines `trk <t s> <lat E5> <lon E5> <speed dm/s> <heading degrees | -1>` are
one fix every 5 s, from the watch's own buffer (`TrackBuffer`), sent along with the log without taking up
the diagnostics' space. A fix of the virtual bike ("Simular trajeto") goes out as `trs ...`, in the same format, so a simulation never
becomes a real track. A fix overwritten before being sent (phone silent for more than 20 min) becomes the line
`trk perdi N` in the next send. `tools/trilha.py extrair` turns those lines of `motonav.log`
into a track that `sim.py ride --track` replays. It does not change the frame format: it is text in the same `LOG`.

It is a debug-phase tool, not v1: it goes away (or becomes optional) when F1/F2 close.

## Payloads (P→W)

### ROUTE_META (0x01)
```
lat0, lon0            int32 ×2   # origin of the local projection (1e-5 degree) — all the points of ALL the blocks of this routeId are relative to this
distanceM             uint32
durationS             uint32     # with traffic, from the API, times the rider's pace (C16, below)
destName              UTF-8, len-prefixed uint8, max 40 bytes
polyPointCount        uint16
turnCount             uint8
corridorLodCount      uint8      # 0 if there will be no corridor
flags                 uint8      # bit0: hasSpeedLimits(v2), bit1: hasCongestion(v2)
```
- **The rider's pace (C16).** Mapbox only has a car profile. Since C16 the phone multiplies the
  provider's duration by the fraction of it that Igor takes on the bike, learned from the stored trips
  (`trips/PersonalPace.kt`; 1.0 until there are 5 trips that qualify), here and in `ROUTE_UPDATE`. The format
  did not change and the watch does not know about the factor: it shows the number that arrives. `packer.py` plays the part of a
  phone with no trips (factor 1.0), and the fixtures stay the same.

### ROUTE_POLY (0x02)
Delta-encoded points relative to (lat0,lon0), unit 1e-5 degree (~1.1 m):
```
p0: dlat,dlon int32 ×2 (relative to lat0/lon0)
p1..n: dlat,dlon — int16 if it fits in ±32767, otherwise an escape pair: 0x7FFF,0x7FFF followed by int32 ×2
```
The watch converts 1x to local meters on receipt (ADR-6) and keeps int arrays.
Density: the companion does NOT simplify the route below ε=2 m (map-matching needs fidelity). Ceiling: 4,000 points (larger routes: simplify until it fits, starting with the straight highway stretches).

### TURNS (0x03), repeated `turnCount` times
```
pointIdx    uint16   # index in the polyline where the maneuver happens
type        uint8    # see table
streetName  UTF-8 len-prefixed uint8, max 28 bytes (companion truncates)
```
Record: `pointIdx uint16, type uint8, [exitNum uint8 if type is a roundabout: 9 or 21..28], streetName`.

Types (map from the Mapbox maneuvers; each one's glyph is an icon from Google's Navigation SDK, `tools/glifos.py`):

| type | maneuver | Mapbox (`maneuver.type` / `modifier`) |
|---|---|---|
| 0 | depart | `depart` |
| 1 | straight / continue | `continue`·`straight`, `fork` with no side, whatever does not match |
| 2 | slight right | `turn`/`end of road`… + `slight right` |
| 3 | right | … + `right` |
| 4 | sharp right | … + `sharp right` |
| 5 | U-turn | … + `uturn` |
| 6 | sharp left | … + `sharp left` |
| 7 | left | … + `left` |
| 8 | slight left | … + `slight left` |
| 9 | roundabout without the exit angle (+`exitNum`) | `roundabout`/`rotary`/`roundabout turn` without `degrees`, or `driving_side = left` |
| 10 | enter the expressway, from the right | `on ramp` without `left` |
| 11 | exit the expressway, to the right | `off ramp` without `left` |
| 12 | arrive | `arrive` with no side |
| 13 | continues onto (name change) | `new name` |
| 14 | fork, take the left one | `fork` + `left`/`slight left`/`sharp left` |
| 15 | fork, take the right one | `fork` + `right`/`slight right`/`sharp right` |
| 16 | merge | `merge` with no side |
| 17 | merge from the left | `merge` + `…left` |
| 18 | merge from the right | `merge` + `…right` |
| 19 | arrive, destination on the left | `arrive` + `…left` |
| 20 | arrive, destination on the right | `arrive` + `…right` |
| 21..28 | roundabout with the exit at the angle (+`exitNum`) | roundabout with `degrees` (below) |
| 29 | enter the expressway, from the left | `on ramp` + `…left` |
| 30 | exit the expressway, to the left | `off ramp` + `…left` |

**The roundabout exit (21..28)** comes from Mapbox's `degrees`: the arc travelled on the ring, counterclockwise,
with 180 = straight ahead (Mapbox doc: "The degrees at which you will be exiting a roundabout, assuming 180
indicates going straight through the roundabout"). It is in the `bannerInstructions` of the **previous step**
(the banner of step i describes the maneuver of step i+1); the first banner with `degrees` counts. 45° bands
centered on each exit: `< 67.5` → 21 sharp right; `< 112.5` → 22 right; `< 157.5` → 23 slight
right; `< 202.5` → 24 straight; `< 247.5` → 25 slight left; `< 292.5` → 26 left; `< 337.5` → 27
sharp left; the rest → 28 U-turn. Without `degrees`, or with `driving_side = left` (the ring would turn
clockwise and the counterclockwise drawing would lie), it stays 9.

`protoVersion = 2` since C16.5 (2026-10-17): types 14..30 and the `exitNum` of 21..28 changed the
record, and a version 1 watch would read the `exitNum` of 21 as the name length. With the new version, a
mixed pair fails openly (`lastError = "protoVersion …"`) instead of scrambling the maneuvers.

### CORRIDOR (0x04)
Block header: `lod uint8` (0=expressways,1=arterials,2=collectors,3=local). Then a sequence of ways:
```
way: pointCount uint8, then delta-encoded points (same scheme as ROUTE_POLY, p0 relative to lat0/lon0)
```
One CORRIDOR block per LOD (each with its chunks). Send order: LOD 0→3, and within the LOD, ways closest to the start of the route first.

### RADARS (0x08)
The route's speed cameras (C16.6). The phone fetches them from OSM (`highway=speed_camera`, Overpass),
keeps those within 60 m of the POLY that apply in the route's direction, and sends the list it already has in the
cache **before** the corridor and the new search **after** it (`06-APIS-DATA.md` §Radares, C16.7). Each
RADARS replaces the whole list; the watch accepts whichever arrives with the route live or being prepared. `routeId` is
the route's, like CORRIDOR.
```
count             uint16
repeats count times (14 B each):
  distAlong       uint32     # meters along the sent POLY, from the first point to the projected camera
  dLat, dLon      int32 ×2   # 1e-5 degree, relative to the META's lat0/lon0
  limit           uint8      # km/h; 0 = unknown (camera with no `maxspeed` in OSM)
  flags           uint8      # bit0 = the camera's direction is known and matches the route; the other bits go 0
```
- **In `distAlong` order, ascending.** Out of order refuses the whole message.
- **`count = 0` is a route with no cameras** and erases the ones the watch had.
- **At most 200** (`MAX_RADARS`, 2,802 B, one chunk). The phone cuts at the ceiling keeping the first ones on the route; a
  watch that receives more reads the first 200 and logs (robustness rule 3).
- **Refused whole**, with the log `radars refused: <reason>`: payload that is not `2 + 14 × count`
  bytes, `distAlong` out of order, more than one chunk. The cameras that were already there stay. The ACK always goes out
  (it is transport), like CORRIDOR's.
- **`distAlong` is the phone's math** over the same POLY points, with the flat projection of
  `LocalPlane` (the same as `Projection.mc`), and the watch compares it directly with the matcher's traveled distance.
  `dLat`/`dLon` are only for the marker on the map.
- **New route (robustness rule 2):** RADARS for the route being prepared is stored, with an ACK, and applied right
  after the swap, like CORRIDOR. A new META, a route swap and the end of navigation erase the cameras.
- **Repeated block or new list** → full ACK, and the watch **reads again and replaces** the route's list. RADARS is outside rule 5: the phone sends the cached list on Overpass's 1st failure and then the fresh one, and the two may have the same number of cameras (same payload size) with different cameras. Rereading a repeated one gives the same list.
- **When the watch warns** (draft of 2026-10-22, chosen in C16.6): the camera shows up at
  `v × (10 s + 0.5 s per km/h above the limit)`, with a floor of 250 m and a ceiling of 1000 m; with an unknown
  limit, just the 10 s (`RadarDraft.showM`). It vibrates once per camera when entering that distance, if `CONFIG` 22
  `radar_vibe` is on.
- A watch older than v1.2.9 does not know the type: full ACK with `msgType 8 not handled` in the log.
- Fixture: `tools/fixtures/radars_00.bin`, from `RADARS_SAMPLE` in `packer.py`.

### FAVORITES (0x05)
`count uint8` + per item: `favId uint8, lat/lon int32 1e-5, name UTF-8 len-prefixed max 20 B, icon uint8`.

Always **1 chunk** and `routeId = 0`, and it stays **outside the route/META check**, like CONFIG (it applies with
or without a route on the watch and does not touch the route or the transfer statistics).

- **The whole list replaces the previous one**; `count = 0` empties it. The phone sends the list on every change
  and on every connection, so the watch never needs a "patch".
- **At most 6 items** (`01 §Telas`). More than 6, a repeated `favId`, a name over 20 B, UTF-8 that
  does not close or a payload that does not fit in `count` refuse the whole message, with the log
  `favorites refused: <reason>`; the list that was already on the watch stays. The ACK always goes out (it is transport).
- **`favId` belongs to the phone**, stable across edits (it is not the index); the watch only returns it in
  `NAV_START_REQ`. The phone never sends a favorite without coordinates (seed not yet filled in).
- The watch keeps the list in `Storage` (key `favorites`) and restores it on open
  (`favorites restored from Storage: N`): the Favorites screen works before the phone speaks.
- `icon` is opaque to the watch in v1 (stored, not drawn).
- Fixture: `tools/fixtures/favorites_00.bin`, from `FAVORITES_SAMPLE` in `packer.py` (public places;
  `python tools/packer.py --favorites`).

### RECENTS (0x0B)
The latest destinations (C16.5): Igor asked for one button on the watch's home screen for favorites
and another for "the routes". **The same format as FAVORITES**, with the same rules (1 chunk,
`routeId` 0, outside the route check; the whole list replaces the previous one; whatever does not close is
refused whole, with the log `recents refused: <reason>`), and these differences:

- **At most 5 items.** Six refuse the message.
- The id of each item is **the position in the phone's list** (0 = the newest), and it only comes back in
  `NAV_START_REQ` with `kind` 1. The phone builds the list from its trips (`TripRecorder.recents`):
  newest first, one item per place (destinations within 0.0005° count once).
- The phone sends the list on every watch connection (after FAVORITES) and at the end of each
  trip, with the link free; never at the start, when it would share the radio with the route.
- The watch keeps it in `Storage` (key `recents`) and restores it on open
  (`recents restored from Storage: N`). `icon` goes 0 and is opaque, as in FAVORITES.
- Fixture: `tools/fixtures/recents_00.bin`, from `RECENTS_SAMPLE` in `packer.py` (public places;
  `python tools/packer.py --favorites`).

### ROUTE_UPDATE (0x06)
The phone redid the route's time calculation and sends the new duration (C13a). Always **1 chunk**, 4 bytes:
```
durationS         uint32     # seconds, 1..0x7FFFFFFF
```
- **The header's `routeId` is the route the duration speaks of**: the watch's active route, or the one
  being prepared (robustness rule 2; the phone counts the route as delivered before the watch swaps).
- **`durationS` is what the provider says now for the same route request** (origin, heading, stops,
  destination), not the remaining time: the watch keeps scaling by `remaining / total`
  (`NavEngine.remainingSeconds`). If the provider picks another path, the number is that path's.
  Since C16 it goes times the rider's pace, like the META's (§ROUTE_META).
- **The ACK here is an answer, not just transport.** Full bitmap = applied. **Empty bitmap = refused**:
  the `routeId` is neither the active route's nor the one being prepared, there is no route, navigation is not active
  (arrived or ended), `durationS` is 0 or has the high bit, the payload is not 4 bytes, or the message
  came in more than one chunk. The watch logs `eta route N: A -> B s` or `eta refused route N: <reason>`.
- **No resend rounds.** The phone sends one at a time, every 10 min (`07 §F4`), and the next one is the
  retry. A refusal is how it finds out that navigation ended when `NAV_ENDED` got lost.
- Outside the transfer statistics, and the watch does not change screens because of it.
- Fixture: `tools/fixtures/route_update_00.bin`, from `ROUTE_UPDATE_SAMPLE` in `packer.py`.

### CONFIG (0x09)
Fine tuning without a cable (C5): vibration, zoom, brightness and HUD size change from the phone, without sideload.
Always **1 chunk** and `routeId = 0`, and it stays **outside the route/META check** (it applies with or without a route on the
watch, and does not count in the transfer statistics).
```
count       uint8
repeats count times:
  key       uint8
  value     uint16
```

| key | name | unit | range accepted by the watch | default |
|-----|------|------|-----------------------------|---------|
| 1 | `lead_s` | s | 4..15 | 8 |
| 2 | `lead_min_m` | m | 30..200 | 80 |
| 3 | `near_m` | m | 10..60, and **less than** `lead_min_m` | 25 |
| 4 | `pulse_ms` | ms | 100..500 | 200 |
| 5 | `zoom` | index (0.6 / 1.2 / 2.5 / 5 m/px) | 0..3 | 1 |
| 6 | `corridor_pct` | % of the corridor grays | 50..160 | 100 |
| 7 | `hud_pct` | % of all the HUD sizes (multiplies each group's %, 10..13) | `DesignTokens.HUD_SCALE_MIN_PCT..MAX_PCT` (today 63..112 on both sides: watch v1.1.5, phone 1.1.2; the ceiling already discounts the orbit) | 100 |
| 8 | `orbit_px` | px of amplitude of the HUD anti burn-in orbit (C10); 0 turns it off | `0..DesignTokens.ORBIT_MAX_PX` (today 0..6) | `ORBIT_MAX_PX` (6) |
| 9 | `orbit_s` | s the HUD stays at each of the ring's 8 points (C10) | 10..60 | 60 |
| 10 | `dist_pct` | % of the distance group: maneuver number, unit, arrival number (C16.5) | `HUD_SCALE_MIN_PCT..MAX_PCT` | 100 |
| 11 | `eta_pct` | % of the time group: the arrival time in the bottom cutout (C16.5; v1.1.5) | `HUD_SCALE_MIN_PCT..MAX_PCT` | 100 |
| 12 | `text_pct` | % of the text group: time, street, arrival, remaining, "then", pill (C16.5) | `HUD_SCALE_MIN_PCT..MAX_PCT` | 100 |
| 13 | `arrow_pct` | % of the arrow group: maneuver arrow, return arrow, arrival check (C16.5; v1.1.5) | `HUD_SCALE_MIN_PCT..MAX_PCT` | 100 |
| 14 | `plate_w_pct` | % of the sign's side breathing room: 100 is the usual gap from text to edge, 0 puts the text 2 px from the frame (v1.1.5) | 0..100 | 100 |
| 15 | `plate_h_pct` | % of the sign's top and bottom breathing room: 0 puts the arrow, the number and the name 2 px from the frame and the rule, 100 is the tall sign (v1.1.5) | 0..100 | 0 |
| 16 | `gps_drill_min` | min after departure at which the watch fakes 90 s without GPS, once per trip (C16 drill); 0 turns it off | 0..30 | 0 |
| 17 | `street_img` | "Ruas em imagem" switch (`StreetCache`); 0 draws street by street on every frame (C16) | 0..1 | 1 |
| 18 | `map_tilt` | "Mapa deitado" switch (C16) | 0..1 | 1 |
| 19 | `street_16bit` | the street image at 16 bits (1) or at the SDK's default depth (0) (C16) | 0..1 | 1 |
| 20 | `street_diag` | street-image diagnostic lever: 0 normal, 1 street by street (control), 2 and 3 single image of 454 and 480 px, 4 to 7 the probes (1, 2, 3 and 4 images of 480 px held and pasted together), 8 to 10 the tile grids (2×2 of 480, 3×3 of 320, 4×4 of 240 px) (C16, v1.2.5; the meanings changed in v1.2.6, v1.2.8 and v1.2.9) | 0..10 | 0 |
| 21 | `vibe_on` | wrist vibration: turn warnings, arrival and leaving the route; 0 turns it off; a watch older than v1.2.7 ignores the key (C16) | 0..1 | 0 |
| 22 | `radar_vibe` | vibration of the camera warning, independent of 21; 0 turns it off; a watch older than v1.2.9 ignores the key (C16.6) | 0..1 | 1 |

- **The watch is the authority on the ranges.** The phone only packs.
- **Partial message:** an absent key keeps the current value.
- **`count = 0` resets everything to the default** and erases `Storage`.
- **A repeated key, a value out of range or `near_m ≥ lead_min_m` refuse the whole message.** Half of a
  setting is never applied. The watch logs `config refused <key>=<v> outside <a>..<b>`.
- **An unknown key is ignored**, with the log `config key N ignored`, and the rest applies. The two
  sides go up in version each at its own pace.
- **The ACK always goes out**, because it is transport. The result, `config ... applied` or
  `config refused ...`, goes right after in the `LOG`, and ends up in `motonav.log` as `WATCH|...`.
- **HUD scale (C16.5):** a group's effective % is `(hud_pct × group_pct + 50) / 100`, clamped to
  `HUD_SCALE_MIN_PCT..MAX_PCT`, and each size in the group becomes `px' = (px × pct + 50) / 100` (integer),
  the same math in `tools/design_tokens.py` and in `Config.groupPx`. The floor is the smallest % at which no
  text falls below 13 px (the smallest text of the watchface the author uses every day); the ceiling is the largest % at
  which the 3 states fit in the glass with ≥ 60% of map and the orbit. Both are computed by the generator,
  never chosen, and apply to each group and to all together. **RNF-05 (55 px and 20 px) holds at
  100%**; below that it is the rider's choice (`DECISIONS.md` §2026-10-16). Until C16 the range was 99..115,
  with 9 keys.
- **Sign breathing room (v1.1.5):** keys 14 and 15 only tighten, they never change the font. At 100% the top
  line has the height of the tallest glyph of the 31 maneuvers and the sign does not jump in size; below that each
  line shrinks toward what it actually has (this arrow, the digits, the name body), so the
  height starts to vary with the maneuver. The default is the sign snug in height (`plate_h_pct` 0) and with the usual gap
  on the sides (`plate_w_pct` 100). There is no above 100%: the 100% sign is the one the generator proves
  in the glass at the scale ceiling, and it is the largest the rider can ask for. A watch older than v1.1.5
  ignores both keys.
- **GPS drill (C16):** with `gps_drill_min` N > 0, N minutes after the route of a new destination
  appears the watch treats its own GPS as weak for 90 s (`GpsDrill`), the same path as a tunnel:
  it asks for `PHONE_FIX`, moves with it and dismisses the phone when the GPS comes back. A reroute does not re-arm. The
  log has `gps drill: the watch fakes no gps for 90s` and `gps drill: end, the watch gps is back`.
  It is a bench tool for the C16 rides, not a riding setting.
- **Map switches (C16):** keys 17 to 19 are the test settings that the watch also has
  in its own menu ("Ruas em imagem", "Mapa deitado"), brought to the phone so Igor can compare on the wrist
  without ending the route (2026-10-19: the streets did not show up on the first ride with the image). When one
  of them arrives, the watch writes the same `Storage` preference that the menu writes and applies it to the map right
  away; whichever touched it last wins, the phone or the menu. A watch older than v1.2.2 ignores the three.
- The watch keeps the setting in `Storage` (key `config`) and restores it on open
  (`config ... restaurado do Storage`).
- **Orbit (C10):** `orbit_px` shifts the HUD (time, arrow, cards) across 8 points of a ring, one every
  `orbit_s`, and the layout reserves that margin; the map does not shift. `orbit_s` has a ceiling of 60 s so two
  minutes in a row never repeat the pixel. The `orbit_px` ceiling comes from `design_tokens.py` (`orbita_max`).
- **Street-image diagnostics (C16, v1.2.5):** key 20 chooses a way to assemble or paste the
  street image, one hypothesis per value; only one applies at a time. With a value other than 0, the watch uses the
  image even with `street_img` 0 (except at 1), redoes the image right away and writes `D` and the number on the map.
  **Since v1.2.6:** 0 normal, 1 street-by-street control (no image), 2 screen-size image (454),
  3 the image steps inside `onUpdate`, 4 one `getDc()` per image, 5 a 100 px control bitmap
  painted and pasted in the same `onUpdate`, 6 2, 3 and 4 together, 7 a magenta square in the middle
  of the image. In v1.2.5 they were 1 point filter, 2 `drawBitmap` without rotation, 3 `drawBitmap2` without
  transformation, 4 rotation through the API, 5 through the `BufferedBitmapReference`, 6 the square, 7 without antialiasing.
  **Since v1.2.9** (C16.6; v1.2.8 gave on the wrist: 454 and 480 px show up, 512 and up do not): 0 normal,
  1 street by street, 2 and 3 the single image of 454 and 480 px, 4 to 7 the **probes**, which hold 1, 2, 3 and 4 images
  of 480 px at the same time, each with an X of its own color, and paste them all (how many Xs show up tells whether the
  ceiling is per image or from the pool), and 8 to 10 the **grids** of world-locked tiles: 2×2 of 480, 3×3 of
  320 and 4×4 of 240 px.
  It is not a riding setting: it stays at 0 outside the bench. A watch older than v1.2.5 ignores the key.
- Fixture: `tools/fixtures/config_00.bin`, with the 22 keys of `CONFIG_SAMPLE` in `packer.py`.

### PHONE_FIX (0x0A)
The phone's GPS as a backup for the watch's GPS (C13b). The phone only sends while the watch asks
(`FIX_REQ`). **1 chunk, 16 bytes**, `routeId = 0`:
```
lat, lon          int32 ×2   # 1e-5 degree
speed             uint16     # dm/s (the unit of the `trk` line), saturates at 0xFFFF
heading           uint16     # heading in degrees, 0..359; ≥ 360 = unknown (the phone sends 0xFFFF)
accuracyM         uint16     # accuracy radius in meters, saturates at 0xFFFF
ageMs             uint16     # age of the fix at send time, in ms, saturates at 0xFFFF
```
- **It has no ACK.** It is the first P→W message like that: one goes out per second, the next one is the retry,
  and an ACK for each would double the link traffic. The phone knows the watch still wants it from the
  `FIX_REQ` renewal, not from a confirmation.
- **Outside the route check and the transfer statistics**, like `CONFIG`, and without the `blk`
  line in the watch log: at 1 Hz it would push the diagnostics out of the 24-line ring in 24 s.
- **Refused with no ACK and no effect**: payload that is not 16 bytes, more than one chunk, latitude outside
  ±90° or longitude outside ±180°. The watch logs `rej fix` on the first refusal and then one in every 30.
- **The watch decides what to do with the fix**, not the phone: it ignores it while it has a recent fix of its own and
  treats one with accuracy worse than 40 m as a weak fix (`03 §GPS`). `ageMs` goes to the log; there is no cutoff
  by age until C16 measures one.
- One message in flight at a time (§Transport): with a corridor block on the air, the fix waits for the chunk
  to finish, and the phone sends **the newest**, not the queue of those that waited.
- Fixture: `tools/fixtures/phone_fix_00.bin`, from `PHONE_FIX_SAMPLE` in `packer.py` (MASP).

## Payloads (W→P)

### REROUTE_REQ (0x82)
The watch left the route and asks for another (ADR-4, C11). Always **1 chunk**, 14 bytes:
```
lat, lon          int32 ×2   # current position, 1e-5 degree
heading           uint16     # heading in degrees, 0..359; ≥ 360 = unknown (the watch sends 0xFFFF)
distAlongRoute    uint32     # meters along the route, at the last fix in which the watch was on it
```
- **The header's `routeId` is the route the `distAlongRoute` refers to.** The phone discards a request
  about any route other than the one it just sent: the distance would mean nothing.
- **`distAlongRoute` is from the last fix on the route, not the current fix.** Far from the route, map-matching may
  match a stretch ahead, and the phone, which uses this number to know which stops are already
  behind, would discard a stop nobody visited. 0 if the watch was never on the route.
- **`heading` unknown** while the watch has not moved above 1 m/s on this route: the phone does not
  send `bearings` to the route provider.
- The watch sends at most one request every 20 s while off the route (ADR-4). The answer is
  a new route, with a new `routeId`, by robustness rule 2.
- Fixture: `tools/fixtures/reroute_req_00.bin`, from `REROUTE_REQ_SAMPLE` in `packer.py`.

### NAV_START_REQ (0x83)
Igor picked a favorite on the watch (RF-02, C12) or a recent destination (C16.5). **1 chunk**,
`routeId = 0` (it belongs to no route); 1 byte for a favorite, 2 for a recent:
```
favId             uint8      # the item's id in the list the phone sent (FAVORITES or RECENTS)
kind              uint8      # only for a recent: 1 = RECENTS. Without the byte, it is a favorite (the C12 frame)
```
- `kind` 0 with 2 bytes is also a favorite; any other value refuses the whole request (log
  `NAV_START_REQ malformado`). The watch always sends the favorite with 1 byte, as in C12.
- A recent is looked up **in the phone's trips**, by position in the current list; the list only
  changes at the end of a trip, and then goes to the watch again.
- The phone looks up the `favId` **in its own storage**, never in a coordinate coming from the watch. An unknown
  `favId` (Igor deleted the favorite just now) is ignored, with the log `NAV_START_REQ favId N
  desconhecido`.
- The answer is a new route, with a new `routeId`, by robustness rule 2 and through the same path as
  sharing: the phone's current position (fix under 60 s old, otherwise a new fix) → Mapbox → META,
  POLY, TURNS, and the corridor after. There is no ACK of its own: the ACK is the route arriving.
- A `NAV_START_REQ` with a route already being sent restarts it (the last favorite wins), like a second
  share (`ShareReceiverActivity.onNewIntent`).
- Fixtures: `tools/fixtures/nav_start_req_00.bin` (favorite), from `NAV_START_REQ_SAMPLE` in
  `packer.py`, and `nav_start_req_01.bin` (recent, with `kind`), from `NAV_START_REQ_RECENT_SAMPLE`.

### FIX_REQ (0x86)
The watch is navigating without a fix of its own and asks for the phone's GPS (C13b). **1 chunk, 1 byte**,
`routeId = 0`:
```
liga              uint8      # 1 = send PHONE_FIX; 0 = stop
```
- **The watch decides.** It asks after 5 s without a fix of its own during navigation and sends `0` after
  5 s in a row with its own fix back. The phone never transmits on its own: the radio and battery cost
  would be permanent (`DECISIONS` §2026-07-31).
- **The request is valid for 50 s and the watch renews it every 20 s.** Without renewal the phone stops by itself:
  that is what protects the battery when `FIX_REQ 0` gets lost or the watch is turned off. One lost request
  fits in the deadline (the next arrives at 41 s or a bit more: the watch decides on a 1 s tick); two
  lost in a row take the backup down.
- Any byte other than 0 or 1 is ignored, with a log.
- The phone only answers with a navigation in progress and able to read the location (permission, and a
  foreground service of type `location`). Otherwise it logs `PHONE_FIX unavailable: <reason>` and sends nothing:
  there is no refusal answer, the watch keeps asking and stays without a backup.
- It has no ACK of its own: the answer is the `PHONE_FIX` arriving.
- Fixture: `tools/fixtures/fix_req_00.bin`, from `FIX_REQ_SAMPLE` in `packer.py` (the request that turns it on).

## Robustness rules

1. routeId different from the active one in POLY/TURNS/CORRIDOR with no previous META → discard + empty ACK (the companion resends from the META).
2. New route (META with a routeId **different** from the active one; the id wraps around at 0xFFFF, so "greater" does not work) during navigation → keep the old route rendering until the new POLY+TURNS pair validates; then swap atomically and clear the old corridor (the new corridor arrives later). A CORRIDOR block of the new route that arrives before the swap is stored, with an ACK, and applied right after it.
3. Payload that exceeds the ceilings (points/segments/bytes) → the watch cuts at the ceiling and logs; never crash.
4. Everything that comes from BLE is untrusted: validate lens, bounds and UTF-8 before using.
5. Repeated CORRIDOR block on the same route (same LOD, same payload size: the full ACK got lost and the companion resent) → full ACK, without reading again (C13b). The same LOD with another size is a correction and replaces the previous one.

## Test vectors

`tools/packer.py` (Python, mirror of the Kotlin packer) generates binary fixtures from a sample route JSON (`tools/fixtures/route_sample.json` — create it with a real Mapbox response for a route in SP). Tests:
- Kotlin: unit test of the packer against the fixtures (byte by byte).
- Monkey C: unit test of the assembler (via `Toybox.Test`) reading the same fixtures as resources.
A pack/unpack bug between two languages is the project's most likely defect — invest here first (F1).
