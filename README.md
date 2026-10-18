# flatbed-scan

One hotkey: scan → auto-trim to the object → PNG in `~/Scans`.

Quick-and-dirty prototype (a zsh script around [scanline](https://github.com/klep/scanline) and ImageMagick) before a proper Swift menu bar app. Tested with an **Epson ES-60W** (sheet-fed, single-sided, black backing). Flatbed scanners are supported via the `SOURCE`/`BACKGROUND` knobs, but haven't been tested yet.

## Install

```bash
brew install imagemagick
```

scanline has no Homebrew formula. Build it from source (no sudo; installs to `~/.local/bin`):

```bash
git clone --depth 1 --branch v2.3 https://github.com/klep/scanline.git /tmp/scanline
xcodebuild build -project /tmp/scanline/scanline.xcodeproj -scheme scanline -configuration Release -derivedDataPath /tmp/scanline/dd CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
cp /tmp/scanline/dd/Build/Products/Release/scanline ~/.local/bin/
```

(Alternatively, the repo ships a signed, notarized `scanline-2.3.pkg` that installs to `/usr/local/bin`.)

Check that the scanner shows up:

```bash
scanline -list
```

## Usage

```bash
./scan.sh                 # scan, trim, save ~/Scans/scan-YYYYMMDD-HHMMSS.png, reveal in Finder
./scan.sh old-scan.png    # re-trim an existing image (no scanning), for tuning the knobs
```

On failure it prints the reason, shows a macOS notification, and exits 1.

### One-key scanning (macOS Shortcuts)

1. Open **Shortcuts** and create a new shortcut called "Scan".
2. Add a **Run Shell Script** action. Set the shell to `zsh` and the script to the absolute path of `scan.sh`, e.g. `~/Documents/Collections/00_Projects/flatbed-scan/scan.sh`.
3. Open the shortcut's **Details** (ⓘ) and choose **Add Keyboard Shortcut**, e.g. ⌃⌥⌘S.
4. Run it once from Shortcuts and approve the permission prompts.

### The scanner's own button (ScanButton.app)

`ScanButton/` is a tiny background app that turns the ES-60W's hardware button into a `scan.sh` run.

```bash
./ScanButton/build.sh     # builds ~/Applications/ScanButton.app and (re)installs it as a LaunchAgent
```

It runs as the LaunchAgent `local.scanbutton` (`~/Library/LaunchAgents/local.scanbutton.plist`), so it starts at login and launchd restarts it if it crashes. Rerun `build.sh` after changing `main.swift`.

Watch what it's doing:

```bash
log stream --predicate 'subsystem == "local.scanbutton"'
```

Uninstall:

```bash
launchctl bootout gui/$(id -u)/local.scanbutton; rm ~/Library/LaunchAgents/local.scanbutton.plist; rm -rf ~/Applications/ScanButton.app
```

How it works:

- **Holding the scanner open.** The Epson driver (`EPSON Scanner 2`) only runs while some app holds an ImageCaptureCore session, so ScanButton keeps one open. For each scan it closes the session, runs `scan.sh`, then reopens it.
- **Catching the press.** The driver catches the press and sends an Apple Event (`'EPsc'/'OPtw'`) to bundle ID `com.epson.EventManager`. ScanButton claims that bundle ID, but macOS privacy controls (TCC) block delivery: only apps signed by Epson's team can receive it without a prompt, and the driver isn't allowed to prompt. Instead, ScanButton watches the unified log for the driver *creating* that event, which happens before TCC steps in. It's a hack, but it needs no permissions.
- **No fighting with the hotkey.** While ScanButton is running, `scan.sh` (e.g. from the hotkey) sends it `SIGUSR1` and exits, so ScanButton runs the scan. Otherwise both would compete for the device and one would fail with "device busy".
- **Debounce.** Presses within 3 s of each other, or during a scan, are ignored.

Caveat: ScanButton takes over the `com.epson.EventManager` bundle ID. If you ever install Epson's real Event Manager, uninstall ScanButton first.

## How the trim works

1. Strip the pure-white padding the feeder driver adds to make short pages Letter size (`-define trim:edges=south`, zero fuzz).
2. Build a mask: greyscale → blur (hides dust and streaks on the backing) → threshold.
3. Take the mask's bounding box and crop the original to it.
4. Apply a tone curve (`-level BLACK_POINT,100%,GAMMA`).

Plain `-fuzz … -trim` doesn't work on the ES-60W: its black backing has specks up to ~70% grey, which no fuzz value ignores.

### Why tone is fixed in post

The ES-60W driver has no brightness, contrast or gamma setting. Through ImageCaptureCore it only exposes unsharp mask, descreening, auto size detection, skip blank pages, punch-hole removal, background removal / colour dropout, and auto rotation. It also hard-clips paper to pure white (~96% of the pixels on a drawing), so the paper already acts as the white reference. The scanner's lighting is constant, so one fixed curve fits every scan, and you don't need a grey card.

## Tuning knobs (top of `scan.sh`)

| Knob | Default | What it does |
|---|---|---|
| `DPI` | `600` | Scan resolution. |
| `THRESHOLD` | `50%` | Brightness cut between background and object. Paper is ~100% and the ES-60W backing ~12%, so there's plenty of room. Lower it for dark or coloured paper. |
| `BLUR` | `4` | Blur radius before thresholding. Raise it if dust specks enlarge the crop. |
| `BACKGROUND` | `black` | `black` for the ES-60W backing, `white` for a flatbed lid. A white object on a white lid won't trim; use a dark backing sheet. |
| `SHAVE` | `0` | Pixels shaved off every edge before trimming (scanner-edge artefacts). |
| `PAD` | `0` | White padding added back around the result. |
| `BLACK_POINT` | `0%` | Greys at or below this become black. The driver's output never gets darker than ~13%, so raise it (e.g. `30%`) for punchier lines. |
| `GAMMA` | `0.7` | Below 1 darkens midtones such as pencil. `1` turns it off. Set `BLACK_POINT=0%` and `GAMMA=1` for untouched output. |
| `SOURCE` | `feeder` | `feeder` or `flatbed`. |
| `SCANNER` | empty | Exact scanner name from `scanline -list`. Empty means the first one found. |
| `OUT_DIR` | `~/Scans` | Where PNGs land. |
| `REVEAL` | `1` | Reveal the result in Finder. |

## Known limitations

- **Single-sided.** The ES-60W only scans the side facing the sensor, so feed the drawing side the right way up.
- **No deskew.** Slightly skewed paper leaves a hairline of backing on one edge. Use `SHAVE` for now; Vision-based deskew is planned for the Swift app.
- **The button relies on log scraping.** ImageCaptureCore never calls `didReceiveButtonPress` for the ES-60W, and the driver's Apple Event is blocked by TCC, so ScanButton watches the system log instead. A macOS or driver update that changes that log line will break it; the hotkey still works if that happens.
- **"Device busy" (imagecapture error -47).** Another app (Image Capture, Epson software) has the scanner open. Quit it and retry.
