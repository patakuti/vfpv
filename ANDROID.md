# vfpv — Android

Drone-controller-style FPV flight: steer and set speed by tilting your device, change altitude by dragging on the screen.

This document covers the Android version. For the project overview and the PC / Web version (vi-style keyboard controls), see [README.md](README.md).

## Requirements

- Android 10+ (API 30+)
- Accelerometer (required for tilt control)
- arm64-v8a or x86_64 device / emulator
- Network access for the real-world stages (Fuji / Miyajima / Golden Gate / Tower Bridge)

## Download & Install

1. Open the [Releases](../../releases) page and download `vfpv-android.apk` from the latest release.
2. Open the downloaded APK on your device. If prompted, allow installing apps from this source (browser or file manager) in the Android settings.
3. Launch **vfpv** from the app drawer.

To install from a PC instead, connect the device with USB debugging enabled and run `adb install -r vfpv-android.apk`.

## PC version vs Android version

The PC version (vi-like keys, RC-airplane feel) is aimed at getting a thrill from keyboard operation alone. The Android version is redesigned to be intuitive, like a drone controller. See ["PC vs Android" in README.md](README.md#pc-vs-android) for a comparison.

## Controls

| Input | Action |
|---|---|
| Tilt forward | Increase speed |
| Tilt back | Decrease speed |
| Tilt left / right | Yaw left / right |
| Touch right half of screen and drag up / down | Ascend / descend (rate proportional to the drag distance from the touch point; holds while the finger is kept still) |
| Pause button (top-left) | Open pause menu |

The speed range is fixed on Android (5–300 m/s; neutral position = min, tilt forward from it = max). On the Miyajima stage the altitude rate is halved (max ±30 m/s instead of ±60 m/s) for finer control.

## Pause Menu

Tap the **| |** button in the top-left corner to pause.

| Button | Action |
|---|---|
| Resume | Unpause and continue flying |
| Calibrate | Set the current device orientation as the neutral (reference) position — see [Notes](#notes) |
| Settings | Open settings screen |
| Quit | Exit the app |

## Settings Screen

Accessible from the pause menu.

| Setting | Description |
|---|---|
| Stage | Select terrain type: Terrain / City / Canyon / Tube / Fuji / Miyajima / Golden Gate / Tower Bridge (the last four are real-world terrain stages and require network access) |
| Quality | Rendering quality: Low / Mid / High / Auto |
| God Mode | Bounce off terrain instead of crashing |
| Camera | Toggle between FPV (first-person) and Follow camera |

Settings are saved and restored on next launch.

## Notes

- **Tilt calibration** — Hold the device in your preferred neutral position, typically tilted about 45° rather than flat, then tap "Calibrate" in the pause menu. The current accelerometer reading is saved as the reference: speed and steering are measured relative to it.
- **Emulator** — The emulator does not have a real accelerometer. Use the debug keys (↑↓←→ / W / S) to simulate tilt and altitude in debug builds.
- **Audio** — Same as desktop; BGM auto-starts and the crash sound is generated at runtime. There is no boost on Android.

## Building from source (optional)

Only needed if you want to build the APK yourself. Requires Godot Engine 4.4+ with Android export templates, the Android SDK, and a keystore configured in Godot's export settings.

```bash
godot --headless --export-debug "Android" vfpv.apk
adb install -r vfpv.apk
```
