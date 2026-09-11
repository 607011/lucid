# Lucid

A macOS menu bar app that prevents system sleep while immediately turning
off all connected displays. Built for sustained-load computations (e.g.
[PrimeGrid](https://www.primegrid.com/)/BOINC), where the CPU should run
at full performance without the monitors drawing unnecessary power.

## How it works

Clicking "Prevent Sleep" in the menu – or pressing the global shortcut
**⌃⌥⌘L**, which works from any app – does two things:

1. **`IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoIdleSleep`**
   (equivalent to `caffeinate -i`) – prevents macOS from going into system
   sleep due to inactivity. Running computations (BOINC/PrimeGrid) keep
   running at full speed.
2. Applies the selected **mode** (see below) to every connected display.

Keyboard or mouse activity then turns the displays back on normally –
macOS handles that itself, no custom code required (the machine never
actually went to sleep, only the displays did).

The moment the displays wake up, the app automatically turns "Prevent
Sleep" back off again (via `NSWorkspace.screensDidWakeNotification`) and
releases the assertion. That way a single click always both re-arms and
triggers it – no need to first uncheck a still-checked item before you
can put the displays back to sleep. (This only applies to "Turn Display
Off" mode below – "Dim Display" never actually sleeps the display, so
there's no wake event to catch; turn it off again the same way you
turned it on.)

### Modes

Two mutually exclusive modes, picked via the checkmarks under "Prevent
Sleep" in the menu:

- **Turn Display Off** (default) – `pmset displaysleepnow`, turns off all
  connected displays immediately instead of waiting for the configured
  display-sleep timer. Maximum power saving. **Caveat:** macOS/the SoC
  appears to drop into a measurably lower CPU performance state when no
  display is actively signaling at all – the same effect documented for
  running a Mac mini fully headless. For CPU-bound background work like
  PrimeGrid, this can noticeably cut into throughput. The standard
  workaround (unrelated to Lucid) is a cheap HDMI/DisplayPort dummy plug
  that keeps macOS convinced a display is attached.
- **Dim Display** – dims every display to near-minimum brightness instead
  of sleeping it (`DisplayDimController`). Keeps the display logically
  "on", which should avoid the reduced-performance state above, at the
  cost of a faint residual glow instead of a fully black screen. Uses
  **undocumented, private macOS APIs** (see below) – less certain to work
  on any given machine than "Turn Display Off", and restoring brightness
  needs a manual click/⌃⌥⌘L again (see previous paragraph).

Dimming the built-in display uses the private `DisplayServices`
framework (same mechanism as the `brightness` CLI tool and Control
Center) – reliable, and verified against real hardware while building
this. Dimming external displays uses DDC/CI (VESA MCCS) over the private
`IOAVService` I2C transport – the same undocumented mechanism
[MonitorControl](https://github.com/MonitorControl/MonitorControl) and
Lunar use. DDC support varies a lot by monitor/cable/hub, and this path
could not be tested against real external hardware while building it (see
[`Sources/Lucid/ExternalDisplayBrightness.swift`](Sources/Lucid/ExternalDisplayBrightness.swift)).
Every call fails silently, so a display that doesn't support it is simply
left alone rather than causing a crash or error dialog.

Hardware brightness alone doesn't get every display equally dark – the
Studio Display's minimum is visibly brighter than a MacBook's built-in
panel at its minimum, for instance. On top of whatever hardware
brightness it manages to set, "Dim Display" therefore also caps every
display's gamma output near-black (`GammaDimmer`,
`CGSetDisplayTransferByFormula`) – a public, if long-deprecated, Quartz
API that scales down what's actually rendered rather than the backlight,
so it closes that gap regardless of a given display's hardware floor.
Restoring uses `CGDisplayRestoreColorSyncSettings()`, which resets gamma
system-wide (there's no public per-display restore) – fine here since
Lucid only ever dims/restores "all displays" together, but worth knowing
if something else (Night Shift's manual slider, f.lux, ...) had also
adjusted gamma at the time.

The app deliberately starts **inactive** – even with "Start at Login"
enabled – so the displays don't unexpectedly turn off right after login.

On the very first launch, the app automatically registers itself as a
login item (`SMAppService`, checkmark next to "Start at Login" in the
menu). This only happens once – if you remove the entry again via the
menu afterwards, it won't be re-added on the next launch.

The global shortcut is registered via the classic Carbon hot key API
(`RegisterEventHotKey`, see
[`Sources/Lucid/HotKeyManager.swift`](Sources/Lucid/HotKeyManager.swift)).
Unlike an `NSEvent` global monitor, this works without the user having to
grant Accessibility/Input Monitoring permission. To change the key
combination, edit `hotKeyCode`/`hotKeyModifiers` in
[`AppDelegate.swift`](Sources/Lucid/AppDelegate.swift).

## Building

Requirement: Xcode command line tools (`swift --version` should work).

```bash
./Scripts/build_app.sh
```

The script builds a release build and packages it into `build/Lucid.app`
(including Info.plist, app icon, and an ad-hoc signature).

The app icon itself lives at [`Resources/AppIcon.icns`](Resources/AppIcon.icns)
and is checked into the repo. It's generated by
[`Scripts/generate_icon.swift`](Scripts/generate_icon.swift) – a coffee-brown
squircle with the same `cup.and.saucer.fill` glyph used in the menu bar. To
regenerate it after changing the design:

```bash
./Scripts/generate_iconset.sh
```

## Releases

Pushing a version tag like `v1.0.0` triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds **two** `.dmg`s – one native `arm64` build, one native `x86_64`
build (via `Scripts/build_dmg.sh`, stamping the tag as
`CFBundleShortVersionString`) – and publishes them as a GitHub Release
with both DMGs attached, so people download only the smaller,
single-architecture build their Mac actually needs.

```bash
git tag v1.0.0
git push origin v1.0.0
```

To build the same DMGs locally:

```bash
./Scripts/build_dmg.sh 1.0.0 arm64    # build/Lucid-1.0.0-arm64.dmg
./Scripts/build_dmg.sh 1.0.0 x86_64   # build/Lucid-1.0.0-x86_64.dmg
```

Each is a disk image containing `Lucid.app` and an `Applications` symlink
for drag-and-drop installation. Omit the architecture (or pass
`universal`) to build a single, larger DMG with both architectures in
one binary instead – `./Scripts/build_dmg.sh 1.0.0` →
`build/Lucid-1.0.0.dmg`.

## Installing

```bash
cp -R build/Lucid.app /Applications/
```

Then open `/Applications/Lucid.app`. On first launch it registers itself
as a login item; you can toggle that at any time from the menu (uses
`SMAppService`, which only works from an installed `.app` bundle, not
from `swift run`).

## Uninstalling

Menu → "Quit", then:

```bash
rm -rf /Applications/Lucid.app
```

If "Start at Login" was enabled, disable it in the app first (or remove
it in System Settings → General → Login Items).

## Notes

- **Apple Silicon + Intel:** `build_app.sh` can target either or both
  (`swift build --arch ...`; see `APP_ARCHS` in the script) – Releases
  ship separate native `arm64`/`x86_64` DMGs rather than one fat binary,
  see "Releases" above. Requires macOS 13 (Ventura) or later on both
  architectures – Ventura itself already needs a roughly 2017-or-newer
  Mac (model-dependent), so this only rules out fairly old Intel
  machines; a 2019/2020 27" iMac is well within that.
- `pmset displaysleepnow` turns off **all** connected displays, not just
  the main one.
- The app only prevents *system* sleep, not manual sleep (e.g. via the
  Apple menu's "Sleep" or closing a notebook lid).
- No sandboxing/notarization – the ad-hoc signature from `build_app.sh`
  is sufficient for personal use. Because of that, macOS Gatekeeper will
  flag a downloaded DMG build as being from an unidentified developer;
  right-click → Open (or remove the quarantine flag with
  `xattr -d com.apple.quarantine /Applications/Lucid.app`) to run it
  anyway.

## License

MIT — see [LICENSE](LICENSE).
