# vfpv

Keyboard-only drone FPV low-altitude high-speed flight experience built with Godot Engine 4.

## Requirements

- Godot Engine 4.4+
- Linux (Ubuntu)

## How to Run

```bash
godot --path /path/to/vfpv
```

## Controls

### Normal Mode

| Key | Action |
|---|---|
| `h` / `l` | Yaw left / right |
| `j` / `k` | Pitch down / up |
| `Space` | Boost (consumes fuel, auto-recovers) |
| `p` | Pause / unpause |
| `g<digits>` | Set speed (e.g. `g100` = 100 m/s) |
| `gg` | Set max speed |
| `G` (Shift+g) | Set min speed |
| `.` | Repeat last action for 1 second |
| `:` | Enter command mode |

### Command Mode

| Command | Action |
|---|---|
| `:speed <n>` | Set base speed (20-400) |
| `:reset` | Respawn at start position |
| `:god` | Toggle god mode (bounce on collision) |
| `:fpv` | Switch to FPV camera |
| `:follow` | Switch to follow camera |
| `:quit` or `:q` | Quit game |
| `Escape` | Cancel and return to normal mode |

## Features

- **Vi-style controls** — Navigate with familiar vim keybindings
- **Procedural terrain** — Infinite Perlin noise terrain with 3 biomes (canyon, mountain, plains)
- **Dynamic chunk loading** — Terrain generates/destroys around player position
- **Speed-linked FOV** — Field of view widens with speed (80° - 110°)
- **Motion blur** — Radial blur intensifies with speed
- **Chromatic aberration** — RGB channel split at high speed
- **Low altitude particles** — Parabolic debris particles when flying low and fast
- **Crash effects** — Screen flash + camera shake on terrain collision
- **God mode** — `:god` toggles invincibility (bounce off terrain instead of crashing)
- **Racing drone model** — X-frame drone with spinning propellers and neon LED accents
- **FPV overlay** — Drone frame silhouette visible in FPV view
- **Pause** — `p` to pause, auto-pause in command mode
- **Boost system** — Temporary 2x speed with fuel gauge
- **HUD** — Speed, time, boost gauge, command line

## Project Structure

```
project.godot
scenes/
  main.tscn            # Main scene
scripts/
  main.gd              # Scene initialization
  player.gd            # Flight physics, boost, crash/respawn
  vi_input.gd          # Vi-style input handling
  terrain_manager.gd   # Procedural terrain chunk management
  hud.gd               # HUD display
  post_process.gd      # Shader uniform management, crash FX
  low_altitude_particles.gd  # Speed/altitude-linked particles
shaders/
  motion_blur.gdshader
  chromatic_aberration.gdshader
```
