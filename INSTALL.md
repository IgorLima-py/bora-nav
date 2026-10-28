# Installing Bora?

Bora? has two parts: an Android app on your phone and a Connect IQ app on your Garmin watch. You need
both. Nothing is on a store: you install them yourself, in about 15 minutes.

## What you need

- A **Garmin Venu 4 (45 mm)**. It is the only watch the app is built for.
- An **Android phone, Android 8.0 or newer**, with the **Garmin Connect** app installed, signed in and
  paired with the watch. Bora? talks to the watch through Garmin Connect.
- A **USB cable** for the watch and a computer (Windows, macOS or Linux) to copy one file to it.
- A free **Mapbox account**, for the routes (step 3).

## 1. Download the files

Open the [latest release](https://github.com/IgorLima-py/bora-nav/releases/latest) and download:

| File | Goes to | What it is |
|------|---------|------------|
| `Bora-<version>.apk` | the phone | the Android app |
| `Bora-<version>.prg` | the watch | the watch app, ready to copy over USB |
| `Bora-<version>.iq` | nobody, usually | the same watch app as a Connect IQ package, the format the Connect IQ store takes; you don't need it to sideload |
| `SHA256SUMS.txt` | | checksums, if you want to check the downloads |

## 2. The watch

1. Plug the watch into the computer with the USB cable.
2. Open the watch's storage:
   - **Windows:** it shows up in File Explorer as a device (Venu 4). Open *Internal Storage*.
   - **macOS:** the watch uses MTP, which Finder doesn't read. Use an MTP app such as
     [OpenMTP](https://openmtp.ganeshrvel.com/).
   - **Linux:** most file managers open MTP devices directly (gvfs, kio).
3. Copy `Bora-<version>.prg` into the `GARMIN/APPS/` folder.
4. Unplug the watch. **Bora?** appears in the watch's app list.

Notes:

- After the first run the file disappears from `GARMIN/APPS/`. That is normal: the watch moves it to its
  internal memory.
- To update, copy the new `.prg` the same way. Keep only one Bora? `.prg` in `GARMIN/APPS/` at a time.
- A sideloaded app has no settings in Garmin Connect. Everything is set on the phone, in Bora?'s
  **Watch** tab, and sent to the watch.
- The watch app follows the watch's language: English, or Portuguese when the watch is in Portuguese.

## 3. The Mapbox token

Bora? computes routes with Mapbox, and each person uses their own token, so nobody shares a quota.

1. Create a free account at [mapbox.com](https://account.mapbox.com/auth/signup/).
2. On your account page, copy the **Default public token**. It starts with `pk.`.
3. Keep it at hand for step 5. The token stays on your phone, encrypted; Bora? sends it only to Mapbox.

Mapbox has a free tier; check [its pricing](https://www.mapbox.com/pricing) and set a usage limit on
your account if you want to be sure. You are responsible for following the
[Mapbox Terms of Service](https://www.mapbox.com/legal/tos).

## 4. The phone

1. Copy `Bora-<version>.apk` to the phone, or download it there directly.
2. Open it. Android asks to allow installs from that source (your browser or file manager): allow it,
   go back, and tap **Install**.
3. Android may warn that the app is from an unknown developer. That is because it is not on the Play
   Store. Tap *More details* → *Install anyway*.

## 5. The first-time setup

The first time you open Bora? on the phone it walks you through four steps:

1. **The Mapbox token.** Paste the `pk.` token from step 3.
2. **Permissions.** Location (so the route starts where you are), notifications (the ongoing notice
   while Bora? talks to the watch) and unrestricted battery (so the watch can start a route with the
   phone in your pocket).
3. **The watch.** Open Bora? on the watch, then tap **Test the connection**. The phone sends your
   favorites and waits for the watch to answer.
4. **All set.** It lists anything still missing; you can fix it later in the **Watch** tab, where
   *Run the first-time setup again* also lives.

The phone app follows the phone's language: English, or Portuguese on a phone in Portuguese.

## 6. Your first route

1. Open **Bora?** on the watch.
2. On the phone, search for a place on Bora?'s Home screen, or share a place from **Google Maps** or
   **Waze** and pick **Bora?** in the share menu.
3. The route reaches the watch in a few seconds, with the streets around it. Ride.

Favorites saved on the phone also show up on the watch, so you can start a route from your wrist with
the phone in your pocket.

## Troubleshooting

- **"The watch didn't answer."** Open Bora? on the watch first, keep it near the phone, and check that
  the watch is connected in Garmin Connect.
- **The app is not on the watch after copying.** Check that the `.prg` went into `GARMIN/APPS/` (not the
  root) and that the watch is a Venu 4 45 mm.
- **No route.** Check the token in the **Watch** tab, and that the phone has internet and a GPS fix.
- **The watch app closes by itself.** The watch writes a crash log to `GARMIN/APPS/LOGS/CIQ_LOG.YML`.
  `python tools/decode_ciq_log.py` turns it into file and line if you build from source.

## Building from source

See the [Build section of the README](README.md#build). To build release files like the ones above,
`tools/package.py` makes the `.prg`, the `.iq` and a signed APK in `dist/`, with your own developer key
and keystore.
