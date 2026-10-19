# OOOI (iOS)

A native iPhone front end for the **OOOI Flight Logger** Home Assistant add-on. It is a direct copy of the
add-on's web app (same screens, colors, fonts and math), but it opens instantly: the Log screen is ready to
type into, and the Scan button goes straight to the camera.

Home Assistant still holds everything: flights, settings, the MyFlightbook CSVs, Drive uploads and the
Gemini scan all stay on the add-on. The app talks to the add-on's own port (8199) over Tailscale and keeps
a copy of everything on the phone:

- Opens from the copy on the phone, then updates from Home Assistant (and every minute while open)
- Saving, editing or deleting a flight with no connection works; changes wait in a queue and upload
  in order the next time the app reaches Home Assistant (the header shows how many are waiting)
- Stats and Map use a cached copy of your imported MyFlightbook history, re-downloaded only when it changes
- The airport list is built in, and replaced by Home Assistant's copy after you update it there
- The photo scan needs a connection (Gemini runs on the add-on, so the key never reaches the phone)

## Download (no Mac needed)

Every push to `main` builds an unsigned `OOOI.ipa` on GitHub Actions and puts it on the "latest" release:

**https://github.com/eblatner-arch/oooi-swift-flight-logger/releases/latest/download/OOOI.ipa**

Install it with SideStore (or AltStore): My Apps → **+** → pick `OOOI.ipa`. SideStore signs it with your Apple ID.

## Build and install from a Mac

You need Xcode (App Store) and Homebrew. In Terminal:

```sh
# one time: the tool that makes the Xcode project from project.yml
brew install xcodegen

# get the code and make the project
git clone https://github.com/eblatner-arch/oooi-swift-flight-logger.git
cd oooi-swift-flight-logger
xcodegen generate
open OOOILogger.xcodeproj
```

Then in Xcode:

1. Click **OOOILogger** at the top of the file list → target **OOOILogger** → **Signing & Capabilities** →
   **Team**: pick your Apple ID (Xcode → Settings → Accounts → + if it isn't listed).
   If Xcode says the bundle ID is taken, change `com.ericsflights.oooilogger` to something of yours.
2. Plug in the iPhone, tap **Trust**, and turn on Developer Mode
   (iPhone Settings → Privacy & Security → Developer Mode, then restart).
3. Pick the iPhone at the top of the Xcode window and press **Run** (⌘R).
4. First time only, on the iPhone: Settings → General → VPN & Device Management → your Apple ID → Trust.

Later, to get the newest version:

```sh
cd oooi-swift-flight-logger
git pull
xcodegen generate
open OOOILogger.xcodeproj    # then Run again
```

With a free Apple ID the app has to be re-installed every 7 days (Run from Xcode again, or use SideStore);
with a paid developer account it lasts a year.

## First run

Settings → **Home Assistant**:

- **Address**: the add-on's direct port over Tailscale, for example `http://homeassistant:8199` or
  `http://100.x.y.z:8199` (your Home Assistant's Tailscale name or address)
- **App password**: `app_password` from the add-on's Configuration tab, if you set one

Tap **Connect**. The header's dot turns green once Drive has synced.

## Checking builds

- **Build** (every push): compiles on a Mac; errors show as annotations on the run
- **IPA** (push to main): builds `OOOI.ipa` and updates the "latest" release
- **Screenshots** (push to main): runs the app in the simulator against a copy of the add-on server
  (`tools/addon`, made-up flights from `tools/seed.py`) and pushes screenshots to the `screens` branch

Fonts: Barlow, Barlow Semi Condensed and IBM Plex Mono (SIL Open Font License, see `OOOILogger/Resources/Fonts`).
