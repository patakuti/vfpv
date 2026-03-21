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
| `H` / `L` | Sharp yaw left / right (2.5x) |
| `j` / `k` | Pitch down / up |
| `J` / `K` | Sharp pitch down / up (3x) |
| `Space` | Boost (consumes fuel, auto-recovers) |
| `p` | Pause / unpause |
| `<digits>g` | Set speed (e.g. `100g` = 100 m/s) |
| `gg` | Set max speed |
| `G` (Shift+g) | Set min speed |
| `.` | Repeat last action for 1 second |
| `:` | Enter command mode |

### Command Mode

| Command | Action |
|---|---|
| `:speed <n>` | Set base speed (20-400) |
| `:reset` | Respawn at start position |
| `:auto` | Toggle auto-avoidance mode |
| `:god` | Toggle god mode (bounce on collision) |
| `:fpv` | Switch to FPV camera |
| `:follow` | Switch to follow camera |
| `:stage terrain` | Switch to natural terrain stage |
| `:stage city` | Switch to urban city stage |
| `:quit` or `:q` | Quit game |
| `Escape` | Cancel and return to normal mode |

## Features

- **Vi-style controls** — Navigate with familiar vim keybindings
- **Stage selection** — `:stage terrain` for natural terrain, `:stage city` for urban flying
- **Procedural terrain** — Infinite Perlin noise terrain with 3 biomes (canyon, mountain, plains)
- **City stage** — Dense urban grid with buildings 15–100m tall, tight 8–15m street gaps
- **Dynamic chunk loading** — Terrain generates/destroys around player position
- **Speed-linked FOV** — Field of view widens with speed (80° - 110°)
- **Motion blur** — Radial blur intensifies with speed
- **Chromatic aberration** — RGB channel split at high speed
- **Low altitude particles** — Parabolic debris particles when flying low and fast
- **Bank** — Camera/drone tilts during turns; deeper bank on sharp turns
- **Crash effects** — Screen flash + camera shake + crash sound on terrain collision
- **Auto mode** — `:auto` toggles automatic obstacle avoidance (raycast-based, last-moment, lateral preferred)
- **God mode** — `:god` toggles invincibility (bounce off terrain instead of crashing)
- **Racing drone model** — X-frame drone with spinning propellers and neon LED accents
- **FPV overlay** — Drone frame silhouette visible in FPV view
- **BGM** — Looping synthwave track with seamless crossfade
- **Pause** — `p` to pause, auto-pause in command mode
- **Boost system** — Temporary 1.5x speed with fuel gauge and engine sound
- **Hyperspeed effects** — Speed lines, drone glow, and music pitch up when boosting over 200 m/s
- **Procedural SFX** — Crash noise and boost engine sweep (generated at runtime)
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
  city_manager.gd      # Urban city stage chunk management
  hud.gd               # HUD display
  auto_pilot.gd        # Raycast-based obstacle auto-avoidance
  post_process.gd      # Shader uniform management, crash FX, hyperspeed effects
  sfx.gd               # Procedural sound effects (crash, boost, wind)
  low_altitude_particles.gd  # Speed/altitude-linked particles
music/
  bgm.ogg              # BGM: "Future Travel" by Zodik (CC-BY 3.0)
shaders/
  motion_blur.gdshader
  chromatic_aberration.gdshader
  speed_lines.gdshader
```

## Credits

- Music: "Future Travel" by Zodik ([CC-BY 3.0](https://creativecommons.org/licenses/by/3.0/)) — https://opengameart.org/content/zodik-future-travel
