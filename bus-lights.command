#!/bin/bash
# =============================================================================
#  bus-lights.command  —  offline central control for the Cabin sleeper-bus
# =============================================================================
#  Double-click in Finder, or run from Terminal:  ./bus-lights.command
#
#  WHAT THIS IS
#    A self-contained replacement for the old "hub" web interface. It SSHes
#    directly into each cabin's Raspberry Pi and drives the light GPIO pins,
#    bypassing the hub / socket.io / Redux stack entirely. No hub, no internet,
#    no Anthropic, no extra software required — just this script + the SSH key.
#
#  REQUIREMENTS (all built into macOS already)
#    - ssh                      (login)
#    - Bonjour / mDNS           (resolves CabinPi-xxxx.local automatically)
#    - the recovered key at ~/.ssh/cabin_key   (this script will copy it from
#      the dump on ~/Desktop/bus-hub-files if it is missing)
#
#  HOW TO USE IT
#    1. Plug your Mac into the bus's wired Ethernet (CradlePoint LAN, 10.101.1.x).
#    2. Run:  ./bus-lights.command            -> interactive menu
#       or use the command line, e.g.:
#         ./bus-lights.command on all
#         ./bus-lights.command off 2B
#         ./bus-lights.command dim all 25
#         ./bus-lights.command scene all departure
#         ./bus-lights.command light 1A backpack 100
#         ./bus-lights.command rgb all 255 0 0
#         ./bus-lights.command discover
#         ./bus-lights.command restore all      (hand control back to the hub system)
#
#  NOTE ON SCENES: the original factory brightness tables live compiled inside
#  the cabin-javascript-library and were not byte-for-byte extractable. The
#  scene presets below reproduce the *intent* of each original scene using the
#  real light channels. Tune the numbers to taste at the top of scene_cmds().
# =============================================================================

# ---- config -----------------------------------------------------------------
BUS_USER="${BUS_USER:-pi}"
KEY="${BUS_KEY:-$HOME/.ssh/cabin_key}"
DUMP_KEY="${BUS_DUMP_KEY:-$HOME/Desktop/bus-hub-files/home/pi/.ssh/id_rsa}"
# Interface to reach Pis on: "eth" (wired, default) or "wifi"
BUS_IFACE="${BUS_IFACE:-eth}"
# mDNS suffix appended to bare hostnames/labels:
SUFFIX="${BUS_SUFFIX:-.local}"

SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# ---- cabin inventory: label -> Pi hostname (from the dump's .ssh/config) -----
ALL_CABINS="1A 1B 1C 1D 2A 2B 2C 2D 3C 3D 4A 4B 4C 4D 5A 5B 5C 5D 6A 6B 6C 6D"

label2host() {
  case "$1" in
    1A) echo CabinPi-00000000782f1a1b;; 1B) echo CabinPi-00000000afd27059;;
    1C) echo CabinPi-0000000024b80351;; 1D) echo CabinPi-0000000015124b46;;
    2A) echo CabinPi-00000000e42c0320;; 2B) echo CabinPi-000000004afb8635;;
    2C) echo CabinPi-000000001c6caf7b;; 2D) echo CabinPi-00000000b4b65716;;
    3C) echo CabinPi-00000000f845c885;; 3D) echo CabinPi-0000000014e5a30a;;
    4A) echo CabinPi-00000000de34fdd0;; 4B) echo CabinPi-00000000da027787;;
    4C) echo CabinPi-00000000e0b3c39f;; 4D) echo CabinPi-0000000035a148e7;;
    5A) echo CabinPi-0000000074fc3071;; 5B) echo CabinPi-000000008cf778aa;;
    5C) echo CabinPi-000000008c47d590;; 5D) echo CabinPi-00000000b046a887;;
    6A) echo CabinPi-00000000b58ba1e8;; 6B) echo CabinPi-0000000045364ece;;
    6C) echo CabinPi-000000000ad5fbf1;; 6D) echo CabinPi-000000001b4607aa;;
    *)  echo "";;
  esac
}

# ---- light channel map (BCM GPIO pins, from lightd/daemon/LightMap.js) -------
# White (dimmable) channels:
BACKPACK="5"            # reading / backpack light
HALL_FLOOR="11"
HALL_CEIL="9"
HALL="11 9"
STEP="10"              # footwell / step light
VAL_TOP="13 16"        # valence, upper
VAL_BOTTOM="6 19"      # valence, lower
VALENCE="6 19 13 16"
ALLWHITE="5 11 9 10 6 19 13 16"
# RGB "sign" light: R=21 G=20 B=26  (driven by rgb_cmds)

# Resolve a friendly light NAME to its pins
light2pins() {
  case "$1" in
    backpack|reading) echo "$BACKPACK";;
    step|foot)        echo "$STEP";;
    hall)             echo "$HALL";;
    hall_floor|floor) echo "$HALL_FLOOR";;
    hall_ceiling|ceiling) echo "$HALL_CEIL";;
    valence)          echo "$VALENCE";;
    valence_top|top)  echo "$VAL_TOP";;
    valence_bottom|bottom) echo "$VAL_BOTTOM";;
    all|white)        echo "$ALLWHITE";;
    pin:*)            echo "${1#pin:}";;
    *)                echo "";;
  esac
}

# ---- helpers -----------------------------------------------------------------
ensure_key() {
  if [ ! -f "$KEY" ]; then
    if [ -f "$DUMP_KEY" ]; then
      mkdir -p "$(dirname "$KEY")"; cp -f "$DUMP_KEY" "$KEY"; chmod 600 "$KEY"
      echo "(copied SSH key from dump -> $KEY)"
    else
      echo "ERROR: SSH key not found at $KEY and dump key missing ($DUMP_KEY)." >&2
      echo "       Copy the Pi's private key to $KEY (chmod 600) and retry." >&2
      exit 1
    fi
  fi
  if [ ! -r "$KEY" ]; then
    echo "ERROR: $KEY exists but is not readable by you ($(whoami))." >&2
    echo "       Most likely it is owned by another user. Fix with:" >&2
    echo "         sudo chown \"\$(whoami)\" \"$KEY\" && chmod 600 \"$KEY\"" >&2
    exit 1
  fi
}

# label/host/ip -> address ssh can reach
target_addr() {
  local t="$1" h sfx=""
  [ "$BUS_IFACE" = "wifi" ] && sfx="-WiFi"
  case "$t" in
    *.*)  echo "$t";;                              # already an IP or FQDN
    CabinPi-*|sleepypi-*) echo "${t}${sfx}${SUFFIX}";;
    *)    h=$(label2host "$t")
          if [ -n "$h" ]; then echo "${h}${sfx}${SUFFIX}"; else echo "${t}${SUFFIX}"; fi;;
  esac
}

# percent (0-100) -> raw pigpio value, matching the daemon's exp brightness curve
# prints -1 for "full off (digital 0)", 256 for "full on (digital 1)", else 0..255
raw_for_pct() {
  awk -v p="$1" 'BEGIN{
    if (p<=0)       print -1;
    else if (p>=100) print 256;
    else            printf "%d", exp(log(255)*p/100)+0.5;
  }'
}

# emit pigs commands to set the given white pins to a percent
white_cmds() {
  local pct="$1"; shift
  local raw; raw=$(raw_for_pct "$pct")
  local p out=""
  for p in "$@"; do
    if   [ "$raw" -le -1 ]; then out="${out}pigs w $p 0; "
    elif [ "$raw" -ge 256 ]; then out="${out}pigs w $p 1; "
    else                          out="${out}pigs p $p $raw; "
    fi
  done
  printf '%s' "$out"
}

rgb_one() { # pin value(0-255)
  if   [ "$2" -le 0 ];   then printf 'pigs w %s 0; ' "$1"
  elif [ "$2" -ge 255 ]; then printf 'pigs w %s 1; ' "$1"
  else                        printf 'pigs p %s %s; ' "$1" "$2"
  fi
}
rgb_cmds() { printf '%s%s%s' "$(rgb_one 21 "$1")" "$(rgb_one 20 "$2")" "$(rgb_one 26 "$3")"; }

# the prep run before any light change: take GPIO away from the daemon
# NOTE: pigpiod must have its fds detached from the SSH channel (</dev/null + redirects),
# otherwise the daemon keeps the SSH session open and the command appears to "hang".
PREP='sudo systemctl stop cabin.all-lights.timer cabin.lightd 2>/dev/null; sudo pigpiod </dev/null >/dev/null 2>&1 || true; sleep 0.4; '

# scene presets — reproduce the intent of the original vehicle/guest scenes
scene_cmds() {
  case "$1" in
    checkin)    printf '%s%s%s%s%s%s' "$(white_cmds 0 $ALLWHITE)" "$(white_cmds 70 $VAL_TOP)" \
                       "$(white_cmds 40 $VAL_BOTTOM)" "$(white_cmds 50 $HALL)" "$(white_cmds 100 $STEP)" "$(rgb_cmds 0 0 90)";;
    departure)  printf '%s%s%s%s' "$(white_cmds 0 $ALLWHITE)" "$(white_cmds 12 $VAL_BOTTOM)" "$(white_cmds 18 $STEP)" "$(rgb_cmds 0 0 0)";;
    checkout)   printf '%s%s' "$(white_cmds 70 $ALLWHITE)" "$(rgb_cmds 0 0 0)";;
    final)      printf '%s%s' "$(white_cmds 100 $ALLWHITE)" "$(rgb_cmds 0 0 0)";;
    night)      printf '%s%s%s%s' "$(white_cmds 0 $ALLWHITE)" "$(white_cmds 8 $VAL_BOTTOM)" "$(white_cmds 8 $STEP)" "$(rgb_cmds 0 0 0)";;
    reading)    printf '%s%s%s%s' "$(white_cmds 0 $ALLWHITE)" "$(white_cmds 100 $BACKPACK)" "$(white_cmds 40 $VAL_TOP)" "$(rgb_cmds 0 0 0)";;
    dim)        printf '%s%s' "$(white_cmds 20 $ALLWHITE)" "$(rgb_cmds 0 0 0)";;
    relax)      printf '%s%s%s' "$(white_cmds 0 $ALLWHITE)" "$(white_cmds 30 $VALENCE)" "$(rgb_cmds 0 120 120)";;
    off|alloff) printf '%s%s' "$(white_cmds 0 $ALLWHITE)" "$(rgb_cmds 0 0 0)";;
    emergency)  printf '%s%s' "$(white_cmds 100 $ALLWHITE)" "$(rgb_cmds 255 0 0)";;
    *)          echo "" ;;
  esac
}
SCENE_NAMES="checkin departure checkout final night reading dim relax off emergency"

# ---- on-Pi animation loop (runs locally on each cabin; args: phase period) ---
# Cycles the RGB sign smoothly around the color wheel. 'phase' (0..1) offsets the
# starting hue per cabin so the whole bus shows a rotating rainbow. Detached with
# setsid so it keeps running after the SSH session closes.
read -r -d '' ANIM_SCRIPT <<'ANIM'
#!/bin/bash
phase="${1:-0}"; period="${2:-12}"; step=0.12
trap 'pigs p 21 0 p 20 0 p 26 0 2>/dev/null; exit 0' TERM INT
i=0
while true; do
  set -- $(awk -v p="$phase" -v i="$i" -v step="$step" -v per="$period" 'BEGIN{
    H=(p+(i*step)/per); H=H-int(H); H6=H*6.0; seg=int(H6); if(seg>5)seg=5;
    m2=H6-int(H6/2)*2; d=m2-1; if(d<0)d=-d; x=int(255*(1-d)+0.5); c=255;
    if(seg==0){r=c;g=x;b=0} else if(seg==1){r=x;g=c;b=0}
    else if(seg==2){r=0;g=c;b=x} else if(seg==3){r=0;g=x;b=c}
    else if(seg==4){r=x;g=0;b=c} else {r=c;g=0;b=x}
    printf "%d %d %d", r, g, b }')
  pigs p 21 $1 p 20 $2 p 26 $3
  i=$((i+1)); sleep $step
done
ANIM

# ---- on-Pi "tunnel" chase loop (args: row nrows period width) ----------------
# A brightness pulse sweeps along the bus by row (1->6, looping) to feel like
# motion. Drives floor + cabin ambient channels. Uses the shared wall clock so
# every cabin in a row pulses together and the wave stays coherent bus-wide.
read -r -d '' TUNNEL_SCRIPT <<'TUN'
#!/bin/bash
row="${1:-1}"; nr="${2:-6}"; period="${3:-3}"; width="${4:-1.4}"
white="11 9 6 19 13 16 10"        # hall floor+ceiling, valence x4, step
allpins="$white 21 20 26"
trap 'for p in $allpins; do pigs p $p 0; done 2>/dev/null; exit 0' TERM INT
lastcyc=-1; CR=0; CG=0; CB=0
while true; do
  now=$(date +%s.%N)
  cyc=$(awk -v now="$now" -v per="$period" 'BEGIN{print int(now/per)}')
  if [ "$cyc" != "$lastcyc" ]; then           # new sweep -> new random color (full sat/val)
    h=$(( RANDOM % 360 ))
    set -- $(awk -v h="$h" 'BEGIN{
      H6=h/60.0; seg=int(H6); if(seg>5)seg=5;
      m2=H6-int(H6/2)*2; d=m2-1; if(d<0)d=-d; x=int(255*(1-d)+0.5); c=255;
      if(seg==0){r=c;g=x;b=0}else if(seg==1){r=x;g=c;b=0}
      else if(seg==2){r=0;g=c;b=x}else if(seg==3){r=0;g=x;b=c}
      else if(seg==4){r=x;g=0;b=c}else{r=c;g=0;b=x}
      printf "%d %d %d", r, g, b }')
    CR=$1; CG=$2; CB=$3; lastcyc=$cyc
  fi
  raw=$(awk -v now="$now" -v row="$row" -v nr="$nr" -v per="$period" -v w="$width" 'BEGIN{
    ph=now/per; ph=ph-int(ph); pos=ph*nr; rr=row-1;
    d=pos-rr; if(d<0)d=-d; if((nr-d)<d)d=nr-d;      # circular distance (loops)
    b=1-(d/w); if(b<0)b=0;                           # triangular pulse
    if(b<=0){print 0}else{print int(exp(log(255)*b)+0.5)} }')   # exp brightness curve
  cmd=""; for p in $white; do cmd="$cmd p $p $raw"; done
  cmd="$cmd p 21 $CR p 20 $CG p 26 $CB"   # RGB always on at this cycle's random color
  pigs $cmd
  sleep 0.07
done
TUN

# ---- target fan-out ----------------------------------------------------------
TARGETS=""
set_targets() {
  case "$1" in
    ""|all|ALL) TARGETS="$ALL_CABINS";;
    *)          TARGETS="$1";;
  esac
}

# run a remote bash snippet on every target (in parallel) and print per-cabin result
do_targets() {
  local script="$1" t addr tmpd
  tmpd=$(mktemp -d)
  for t in $TARGETS; do
    addr=$(target_addr "$t")
    {
      out=$(printf '%s' "$script" | $SSH "$BUS_USER@$addr" 'bash -s' 2>&1)
      if [ $? -eq 0 ]; then printf '  [%-3s] OK    %s\n' "$t" "$(echo "$out" | tr '\n' ' ')"
      else                  printf '  [%-3s] FAIL  %s\n' "$t" "$(echo "$out" | tr '\n' ' ' | cut -c1-80)"
      fi
    } > "$tmpd/$t" &
  done
  wait
  for t in $TARGETS; do cat "$tmpd/$t"; done
  rm -rf "$tmpd"
}

apply_lights() { # $1 = remote pigs command string ; uses TARGETS
  do_targets "${PREP}$1 echo applied on \$(hostname)"
}

# ---- command verbs -----------------------------------------------------------
cmd_on()    { set_targets "$1"; echo "Lights ON (full) -> ${TARGETS}";  apply_lights "$(white_cmds 100 $ALLWHITE)"; }
cmd_off()   { set_targets "$1"; echo "Lights OFF -> ${TARGETS}";        apply_lights "$(white_cmds 0 $ALLWHITE)$(rgb_cmds 0 0 0)"; }
cmd_dim()   { set_targets "$1"; echo "Dim to ${2}% -> ${TARGETS}";      apply_lights "$(white_cmds "${2:-30}" $ALLWHITE)"; }
cmd_rgb()   { set_targets "$1"; echo "Sign RGB ${2}/${3}/${4} -> ${TARGETS}"; apply_lights "$(rgb_cmds "${2:-0}" "${3:-0}" "${4:-0}")"; }

cmd_light() { # target name pct
  set_targets "$1"
  local pins; pins=$(light2pins "$2")
  if [ -z "$pins" ]; then echo "Unknown light '$2'. Try: backpack step hall hall_floor hall_ceiling valence valence_top valence_bottom all  (or pin:N)"; return 1; fi
  echo "Light '$2' (pins $pins) -> ${3:-100}% on ${TARGETS}"
  apply_lights "$(white_cmds "${3:-100}" $pins)"
}

cmd_scene() { # target scene
  set_targets "$1"
  local s; s=$(scene_cmds "$2")
  if [ -z "$s" ]; then echo "Unknown scene '$2'. Available: $SCENE_NAMES"; return 1; fi
  echo "Scene '$2' -> ${TARGETS}"
  apply_lights "$s"
}

cmd_emergency() { set_targets "${1:-all}"; echo "*** EMERGENCY: all lights full + red sign -> ${TARGETS} ***"; apply_lights "$(scene_cmds emergency)"; }

# power-up / default state: every white light full + each ROW its own unique color
# (rows 1-6 -> red, yellow, green, cyan, blue, magenta on the RGB sign)
cmd_rows() {
  set_targets "${1:-all}"
  echo "Full brightness + per-row color -> ${TARGETS}"
  local tmpd; tmpd=$(mktemp -d); local t
  for t in $TARGETS; do
    local row addr rgb cmds
    row="${t:0:1}"
    rgb=$(awk -v r="$row" 'BEGIN{
      h=((r-1)%6)*60; H6=h/60.0; seg=int(H6); if(seg>5)seg=5;
      m2=H6-int(H6/2)*2; d=m2-1; if(d<0)d=-d; x=int(255*(1-d)+0.5); c=255;
      if(seg==0){r=c;g=x;b=0}else if(seg==1){r=x;g=c;b=0}
      else if(seg==2){r=0;g=c;b=x}else if(seg==3){r=0;g=x;b=c}
      else if(seg==4){r=x;g=0;b=c}else{r=c;g=0;b=x}
      printf "%d %d %d", r, g, b }')
    addr=$(target_addr "$t")
    # all white channels full-on, RGB sign = row color
    cmds="$(white_cmds 100 $ALLWHITE)$(rgb_cmds $rgb)"
    { out=$(printf '%s' "${PREP}${cmds} echo applied on \$(hostname)" | $SSH "$BUS_USER@$addr" 'bash -s' 2>&1)
      if [ $? -eq 0 ]; then printf '  [%-3s] OK    row %s rgb(%s)\n' "$t" "$row" "$(echo "$rgb" | tr ' ' ',')"
      else printf '  [%-3s] FAIL  %s\n' "$t" "$(echo "$out" | tr '\n' ' ' | cut -c1-70)"; fi
    } > "$tmpd/$t" &
  done
  wait; for t in $TARGETS; do cat "$tmpd/$t"; done; rm -rf "$tmpd"
  echo "Done. (This is the intended power-up state.)"
}

# each target gets a distinct hue, spread evenly around the color wheel (RGB sign light)
cmd_rainbow() {
  set_targets "${1:-all}"
  local n=0 t; for t in $TARGETS; do n=$((n+1)); done
  [ "$n" -eq 0 ] && { echo "no targets"; return 1; }
  echo "Rainbow across $n cabins (sets each cabin's RGB sign to a different color)..."
  local tmpd; tmpd=$(mktemp -d); local i=0
  for t in $TARGETS; do
    local rgb addr cmds
    rgb=$(awk -v i="$i" -v n="$n" 'BEGIN{
      H=(i/n)*6.0; seg=int(H); m2=H-int(H/2)*2; d=m2-1; if(d<0)d=-d;
      x=int(255*(1-d)+0.5); c=255;
      if(seg==0){r=c;g=x;b=0} else if(seg==1){r=x;g=c;b=0}
      else if(seg==2){r=0;g=c;b=x} else if(seg==3){r=0;g=x;b=c}
      else if(seg==4){r=x;g=0;b=c} else {r=c;g=0;b=x}
      printf "%d %d %d", r, g, b }')
    addr=$(target_addr "$t"); cmds=$(rgb_cmds $rgb)
    {
      out=$(printf '%s' "${PREP}${cmds} echo applied on \$(hostname)" | $SSH "$BUS_USER@$addr" 'bash -s' 2>&1)
      if [ $? -eq 0 ]; then printf '  [%-3s] OK    rgb(%s)\n' "$t" "$(echo "$rgb" | tr ' ' ',')"
      else printf '  [%-3s] FAIL  %s\n' "$t" "$(echo "$out" | tr '\n' ' ' | cut -c1-70)"; fi
    } > "$tmpd/$t" &
    i=$((i+1))
  done
  wait
  for t in $TARGETS; do cat "$tmpd/$t"; done
  rm -rf "$tmpd"; echo "Rainbow applied 🌈"
}

# start/stop a locally-running color-cycle animation on each cabin
cmd_anim() {
  local sub="${1:-start}"; shift 2>/dev/null
  case "$sub" in
    stop)
      set_targets "${1:-all}"; echo "Stopping animation -> ${TARGETS}"
      do_targets "pkill -f cabin-anim.sh 2>/dev/null; sudo pigpiod </dev/null >/dev/null 2>&1 || true; sleep 0.2; pigs p 21 0 p 20 0 p 26 0; echo stopped \$(hostname)";;
    start|"")
      set_targets "${1:-all}"; local period="${2:-12}"
      local n=0 t; for t in $TARGETS; do n=$((n+1)); done
      [ "$n" -eq 0 ] && { echo "no targets"; return 1; }
      local b64; b64=$(printf '%s' "$ANIM_SCRIPT" | base64 | tr -d '\n')
      echo "Starting color-cycle animation on $n cabins (full cycle ${period}s, rotating rainbow)..."
      local tmpd; tmpd=$(mktemp -d); local i=0
      for t in $TARGETS; do
        local phase addr payload
        phase=$(awk -v i="$i" -v n="$n" 'BEGIN{printf "%.4f", i/n}')
        addr=$(target_addr "$t")
        payload="sudo systemctl stop cabin.all-lights.timer cabin.lightd 2>/dev/null; sudo pigpiod </dev/null >/dev/null 2>&1 || true; pkill -f cabin-anim.sh 2>/dev/null; sleep 0.2; echo $b64 | base64 -d > /tmp/cabin-anim.sh; chmod +x /tmp/cabin-anim.sh; setsid /tmp/cabin-anim.sh $phase $period </dev/null >/dev/null 2>&1 & echo started \$(hostname)"
        { out=$(printf '%s' "$payload" | $SSH "$BUS_USER@$addr" 'bash -s' 2>&1)
          if [ $? -eq 0 ]; then printf '  [%-3s] OK    phase %s\n' "$t" "$phase"
          else printf '  [%-3s] FAIL  %s\n' "$t" "$(echo "$out" | tr '\n' ' ' | cut -c1-70)"; fi
        } > "$tmpd/$t" &
        i=$((i+1))
      done
      wait; for t in $TARGETS; do cat "$tmpd/$t"; done; rm -rf "$tmpd"
      echo "Animation running. Stop with:  ./bus-lights.command anim stop all";;
    *) echo "usage: anim [start|stop] [target] [period_seconds]";;
  esac
}

# start/stop the row-by-row "tunnel" motion effect on floor + cabin lights
cmd_tunnel() {
  local sub="${1:-start}"; shift 2>/dev/null
  case "$sub" in
    stop)
      set_targets "${1:-all}"; echo "Stopping tunnel -> ${TARGETS}"
      do_targets "pkill -f cabin-tunnel.sh 2>/dev/null; sudo pigpiod </dev/null >/dev/null 2>&1 || true; sleep 0.2; for p in 11 9 6 19 13 16 10 21 20 26; do pigs p \$p 0; done; echo stopped \$(hostname)";;
    start|"")
      set_targets "${1:-all}"; local period="${2:-3}" width="${3:-1.4}" nr=6
      local b64; b64=$(printf '%s' "$TUNNEL_SCRIPT" | base64 | tr -d '\n')
      echo "Tunnel/chase motion on ${TARGETS} (sweep ${period}s, pulse width ${width} rows)..."
      local tmpd; tmpd=$(mktemp -d); local t
      for t in $TARGETS; do
        local row addr payload
        row="${t:0:1}"
        addr=$(target_addr "$t")
        payload="sudo systemctl stop cabin.all-lights.timer cabin.lightd 2>/dev/null; sudo pigpiod </dev/null >/dev/null 2>&1 || true; pkill -f cabin-tunnel.sh 2>/dev/null; sleep 0.2; echo $b64 | base64 -d > /tmp/cabin-tunnel.sh; chmod +x /tmp/cabin-tunnel.sh; setsid /tmp/cabin-tunnel.sh $row $nr $period $width </dev/null >/dev/null 2>&1 & echo started \$(hostname)"
        { out=$(printf '%s' "$payload" | $SSH "$BUS_USER@$addr" 'bash -s' 2>&1)
          if [ $? -eq 0 ]; then printf '  [%-3s] OK    row %s\n' "$t" "$row"
          else printf '  [%-3s] FAIL  %s\n' "$t" "$(echo "$out" | tr '\n' ' ' | cut -c1-70)"; fi
        } > "$tmpd/$t" &
      done
      wait; for t in $TARGETS; do cat "$tmpd/$t"; done; rm -rf "$tmpd"
      echo "Tunnel running. Stop with:  ./bus-lights.command tunnel stop all";;
    *) echo "usage: tunnel [start|stop] [target] [period_seconds] [width_rows]";;
  esac
}

cmd_run() { # target 'command'
  set_targets "$1"; echo "Running on ${TARGETS}: $2"; do_targets "$2"
}

cmd_reboot() { set_targets "$1"; echo "Rebooting ${TARGETS} ..."; do_targets "sudo reboot; echo rebooting \$(hostname)"; }

# hand GPIO + control back to the original daemon/hub system
cmd_restore() {
  set_targets "$1"; echo "Restoring auto/hub control -> ${TARGETS}"
  do_targets "sudo killall pigpiod 2>/dev/null; sudo systemctl start cabin.lightd 2>/dev/null; sudo systemctl start cabin.all-lights.timer 2>/dev/null; echo restored \$(hostname)"
}

cmd_status() {
  set_targets "${1:-all}"; echo "Status -> ${TARGETS}"
  do_targets "printf 'lightd=%s pigpiod=%s' \"\$(systemctl is-active cabin.lightd 2>/dev/null)\" \"\$(pgrep -x pigpiod >/dev/null && echo running || echo stopped)\""
}

cmd_discover() {
  echo "Scanning for reachable cabins (this can take a few seconds)..."
  set_targets all
  do_targets "echo up \$(hostname)"
}

cmd_list() {
  echo "Cabin inventory (label -> hostname):"
  local t
  for t in $ALL_CABINS; do printf '   %-3s  %s%s\n' "$t" "$(label2host "$t")" "$SUFFIX"; done
  echo
  echo "Reach over: $BUS_IFACE  (set BUS_IFACE=wifi to use the -WiFi names)"
}

# ---- interactive menu --------------------------------------------------------
pause(){ printf '\n(press Return)'; read -r _; }
menu() {
  while true; do
    cat <<'MENU'

============================================================
      BUS CENTRAL CONTROL  (offline)        type a number
============================================================
  1) Discover reachable cabins
  2) ALL lights ON  (full)
  3) ALL lights OFF
  4) Set ALL brightness  (0-100%)
  5) Run a SCENE on all cabins
  6) Control ONE cabin
  7) EMERGENCY  (all full + red)
  8) Restore auto/hub control (give GPIO back to daemon)
  9) Reboot a cabin / all
 10) List cabins / settings
  0) Quit
------------------------------------------------------------
MENU
    printf 'choice> '; read -r c
    case "$c" in
      1) cmd_discover; pause;;
      2) cmd_on all; pause;;
      3) cmd_off all; pause;;
      4) printf 'brightness %% (0-100)> '; read -r p; cmd_dim all "$p"; pause;;
      5) printf 'scene [%s]> ' "$SCENE_NAMES"; read -r s; cmd_scene all "$s"; pause;;
      6) printf 'cabin label (e.g. 2B)> '; read -r cab
         printf 'action [on/off/dim/scene/light/rgb]> '; read -r a
         case "$a" in
           on) cmd_on "$cab";;
           off) cmd_off "$cab";;
           dim) printf '%%> '; read -r p; cmd_dim "$cab" "$p";;
           scene) printf 'scene [%s]> ' "$SCENE_NAMES"; read -r s; cmd_scene "$cab" "$s";;
           light) printf 'light name> '; read -r n; printf '%%> '; read -r p; cmd_light "$cab" "$n" "$p";;
           rgb) printf 'R G B> '; read -r r g b; cmd_rgb "$cab" "$r" "$g" "$b";;
           *) echo "unknown action";;
         esac; pause;;
      7) cmd_emergency all; pause;;
      8) cmd_restore all; pause;;
      9) printf 'cabin or "all"> '; read -r cab; cmd_reboot "$cab"; pause;;
      10) cmd_list; pause;;
      0|q|quit) echo "bye"; exit 0;;
      *) echo "?";;
    esac
  done
}

# ---- dispatch ----------------------------------------------------------------
ensure_key
verb="$1"; shift 2>/dev/null
case "$verb" in
  ""|menu)   menu;;
  on)        cmd_on "$@";;
  off)       cmd_off "$@";;
  dim)       cmd_dim "$@";;
  light)     cmd_light "$@";;
  rgb)       cmd_rgb "$@";;
  scene)     cmd_scene "$@";;
  emergency) cmd_emergency "$@";;
  rainbow)   cmd_rainbow "$@";;
  rows)      cmd_rows "$@";;
  anim)      cmd_anim "$@";;
  tunnel)    cmd_tunnel "$@";;
  restore)   cmd_restore "$@";;
  reboot)    cmd_reboot "$@";;
  status)    cmd_status "$@";;
  run)       cmd_run "$@";;
  discover)  cmd_discover;;
  list)      cmd_list;;
  help|-h|--help)
    sed -n '2,48p' "$0";;
  *) echo "Unknown command '$verb'. Run with no arguments for the menu, or 'help'.";;
esac
