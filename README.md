# 🚌 Bus Lights — Cabin Sleeper-Bus Light Control

Offline control system for the cabin sleeper-bus lighting. Drives all 22 cabin
Raspberry Pis directly over SSH — **replaces the original hub** (no hub, no
internet, no cloud required).

> **Full technical writeup + diagrams:** open [`bus.html`](bus.html) in a browser.

## ⚠️ Security note — read this
This repo is intentionally **secret-free**. The thing that actually grants
control is an **SSH private key** that has passwordless `sudo` (root) on all 22
cabin Pis. That key — and the bus WiFi passwords — are **NOT in this repo** and
must never be committed here. They live in the team password manager / encrypted
USB. Without the key, this code can't touch anything unless you're already on the
bus LAN with credentials.

Anyone redeploying must obtain the key out-of-band and place it at
`~/.ssh/cabin_key` (`chmod 600`).

## Quick start
```bash
# 1. Get the key out-of-band -> ~/.ssh/cabin_key (chmod 600)
# 2. Plug the controlling machine into the bus's wired Ethernet (10.101.1.x LAN)
# 3. Run it:
./bus-lights.command                 # interactive menu
./bus-lights.command discover        # which cabins are reachable right now
./bus-lights.command on all          # all white lights, full
./bus-lights.command off all
./bus-lights.command rows all        # power-up state: full + each row its own color
./bus-lights.command restore all     # hand control back to each cabin's own daemon
```

## Command reference
| Command | Effect |
|---------|--------|
| `on / off [target]` | all white lights full / off |
| `dim [target] <0-100>` | set white brightness |
| `light <target> <name> <%>` | one named light (backpack, step, hall, valence, …) |
| `rgb [target] <r> <g> <b>` | set the RGB "sign" light |
| `scene [target] <name>` | preset scene (checkin, departure, night, reading, …) |
| `rows [target]` | full brightness + each row a unique color (power-up state) |
| `rainbow [target]` | each cabin a different color of the wheel |
| `anim start\|stop [target] [period]` | slow color-cycle, rainbow rotates down the bus |
| `tunnel start\|stop [target] [period] [width]` | motion pulse sweeps row 1→6, signs hold random color |
| `emergency [target]` | all full + red sign |
| `restore [target]` | return GPIO to the cabin's original light daemon |
| `discover` / `list` | reachability check / inventory |
| `run <target> '<cmd>'` | run an arbitrary command on cabins |

`target` = `all` (default), a cabin label like `3D`, a hostname, or an IP.
Use `BUS_IFACE=wifi` to reach cabins over their `-WiFi` names instead of wired.

## How it works (one paragraph)
Each cabin Pi runs light fixtures on GPIO pins driven by PWM (`pigpio`). The
script SSHes into each cabin, momentarily stops that cabin's `cabin.lightd`
daemon so it can take the GPIO, and sets the pins with `pigs`. Animations are
pushed as tiny loops that run *locally on each Pi* (detached), so they keep
running even if the controlling machine disconnects. See `bus.html` for the
full architecture, the GPIO/light map, the scene vocabulary, and caveats.

## Roadmap
- [ ] Permanent on-bus controller Pi at the driver console
- [ ] Redundant access keys provisioned to all cabins (anti-lockout)
- [ ] Physical buttons (On / Off / Tunnel / Rainbow / Emergency)
- [ ] Optional web UI on the controller
- [ ] Boot-persistent default state (`rows`) + auto-start services
