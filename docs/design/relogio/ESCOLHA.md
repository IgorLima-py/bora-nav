# Choice of the watch's new screen

**In use since v1.1.5 (2026-10-18): v4 "Warning sign"** (`style: plate` in `tokens.json`). The maneuver
on a two-line street sign, petrol with a white frame and amber with black ink at 60 m from the turn; the time and
the arrival in black cutouts (sheet 6, option 12, chosen by Igor on 2026-10-17: "a 12 msm"). The map underneath
is Maps on black, tilted (sheet 8, option 25, 2026-10-18: "Vai a 25, Maps no preto"). The decisions and the
measurements are in `docs/DECISIONS.md` §2026-10-18.

## The first choice (C4)

**Chosen by Igor on 2026-09-28: V2 "Cards"** (`style: cards` in `tokens.json`).
Input to C4.

- Map on the whole glass; two rounded black cards, **borderless**, on top: at the top the time, the arrow,
  the distance and the street name; at the bottom the time remaining and the distance remaining.
- Sizes and positions are V1's (arrow 38 half-height = 55 px, distance 56 px, unit 44 px, street and
  time 22 px, remaining time 28 px); only the style changes.
- **No speed** (Igor looks at the bike's speedometer) and **no ETA** (arrival time).
- Time remaining in the format `22 min` / `1 h 34 min`.
- Route ahead in **purple** `#B388FF` (token `rota_frente`, deliberately easy to swap); the route
  already ridden is `rota_atras` `#4A3F66`. Card in pure black (AMOLED).
- Visible map in the mockup: 60–75%, against ~74% of the current screen.
- Pending for C4: `Hud.mc` starts formatting the remaining time; the route color moves from
  `MapRenderer.mc` (today white `0xFFFFFF`) to `DesignTokens.mc`; and the line in `01-PRODUCT-SPEC.md`
  (route ahead white, base with ETA and speed) needs to be updated along with it.

## C15b (2026-10-14): v3 "Dark Waze"

The `escolhida` of `tokens.json` became **v3** (`style: cards`, the same layout): slate cards `#1B2128`,
Nunito, cyan route with border, wide dark street bands, large arrival time at the bottom. What it decides and what
was measured is in `docs/DECISIONS.md` §C15b; the analysis is in `docs/UI-REFERENCIAS.md`.
