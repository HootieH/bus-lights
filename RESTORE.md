# Redeploy / Restore Guide

How to stand up bus light control on a new machine (or the permanent on-bus
controller). **This file contains no secrets** — the credentials live in the
**TE Notion** (team secure notes), page: *"Bus Light Control — Secrets"*.

## What you need
1. **This repo** — `git clone https://github.com/HootieH/bus-lights`
2. **The SSH key + WiFi/access info** — copy from the **TE Notion** secrets page.
3. **A machine on the bus LAN** — wired Ethernet into the CradlePoint (10.101.1.x).

## Steps
```bash
# 1. Get the code
git clone https://github.com/HootieH/bus-lights
cd bus-lights

# 2. Install the master key (paste the PRIVATE KEY block from TE Notion)
mkdir -p ~/.ssh
pbpaste > ~/.ssh/cabin_key        # or paste into the file with an editor
chmod 600 ~/.ssh/cabin_key

# 3. Plug into the bus wired Ethernet, then verify reachability
./bus-lights.command discover     # should list cabins as "up"

# 4. Drive the lights
./bus-lights.command rows all     # power-up state (full + per-row color)
./bus-lights.command tunnel start all
./bus-lights.command restore all  # hand control back to the cabins' daemon
```

## If `discover` shows cabins unreachable
- **All fail / "could not resolve hostname":** you're not on the bus LAN. Check
  the Ethernet link and that you have a 10.101.1.x address.
- **"Permission denied (publickey)":** the key file isn't readable or isn't the
  right key. Check `ls -l ~/.ssh/cabin_key` (must be `600`, owned by you) and that
  you pasted the full key including the BEGIN/END lines.
- **Some cabins fail, others work:** those Pis may have been re-imaged. Re-add the
  key (see Anti-lockout below) or address them by IP (`nmap -p22 --open 10.101.1.0/24`,
  match MACs from `bus.html`).

## Anti-lockout (do this while you HAVE access)
Provision a second, independent key so no single loss locks you out:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/bus_controller -C bus-controller -N ""
./bus-lights.command run all "echo '$(cat ~/.ssh/bus_controller.pub)' >> ~/.ssh/authorized_keys"
./bus-lights.command run all "cat ~/.ssh/authorized_keys" > cabin-authkeys-backup.txt  # keep out of git
```
Store the new key in TE Notion alongside the master key.

## Full technical reference
Architecture, GPIO/light map, scene vocabulary, cabin↔hostname↔MAC table, and
caveats are all in [`bus.html`](bus.html) — open it in a browser.
