#!/usr/bin/env bash
set -Eeuo pipefail

ORIGINAL_ARGS=("$@")
VERSION="1.0.0"

VID="0fe7"
PID="2002"
NODE_RED_CONTAINER="bee-edge-0-iiot-1"
SERIALS_CSV="auto"
SERIALS_AUTO="0"
COMPOSE_FILE=""
COMPOSE_SERVICE="iiot"
PATCH_COMPOSE="auto"
COMPOSE_UP="1"
INSTALL_PALETTE="1"
RESTART_NODE_RED="1"
VERIFY_ONLY="0"
ADD_LEGACY_DEVICES_MAP="0"
AGGREGATOR_ENABLED="1"
VIRTUAL_PORT="/dev/ttyUWave"
AGGREGATOR_FORMAT="json"
CLEAN_LEGACY="1"

INSTALL_DIR="/opt/mitutoyo-uwave"
ENV_FILE="/etc/default/mitutoyo-uwave"
MODULES_LOAD_FILE="/etc/modules-load.d/mitutoyo-uwave.conf"
BIND_SCRIPT="/usr/local/bin/bind-mitutoyo.sh"
SERVICE_FILE="/etc/systemd/system/mitutoyo-uwave-bind.service"
AGGREGATOR_SCRIPT="/usr/local/bin/mitutoyo-uwave-aggregator.py"
AGGREGATOR_SERVICE_FILE="/etc/systemd/system/mitutoyo-uwave-aggregator.service"
UDEV_RULE_FILE="/etc/udev/rules.d/99-mitutoyo-uwave.rules"
FLOW_FILE="${INSTALL_DIR}/node-red-flow.json"

log() {
  printf '[mitutoyo-uwave] %s\n' "$*"
}

warn() {
  printf '[mitutoyo-uwave] WARN: %s\n' "$*" >&2
}

die() {
  printf '[mitutoyo-uwave] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Mitutoyo U-WAVE-R one-shot installer for Raspberry Pi / BEEEDGE + Node-RED Docker.

Usage:
  sudo ./install-mitutoyo-uwave.sh [options]

Default target:
  VID/PID:       0fe7:2002
  container:     bee-edge-0-iiot-1
  Node-RED port: /dev/ttyUWave
  compose svc:   iiot

Options:
  --container NAME          Node-RED Docker container name.
  --serials CSV             Optional receiver serials to verify, or "auto".
  --vid HEX                 USB vendor id. Default: 0fe7.
  --pid HEX                 USB product id. Default: 2002.
  --compose-file PATH       Patch this docker compose file.
  --compose-service NAME    Compose service to patch. Default: iiot.
  --no-compose-patch        Do not patch docker compose.
  --no-compose-up           Patch compose but do not recreate the service.
  --no-palette-install      Do not try to install node-red-node-serialport in the container.
  --no-node-red-restart     Do not restart the Node-RED container from the udev bind script.
  --no-aggregator           Do not create the single /dev/ttyUWave aggregate port.
  --virtual-port PATH       Aggregate PTY symlink. Default: /dev/ttyUWave.
  --message-format FORMAT   Aggregate output format: json or tsv. Default: json.
  --no-cleanup-legacy       Do not remove files from the older manual setup.
  --legacy-devices-map      Also add devices: /dev:/dev to compose. Usually not needed.
  --verify-only             Only print current device/container state.
  -h, --help                Show this help.

Examples:
  sudo ./install-mitutoyo-uwave.sh
  sudo ./install-mitutoyo-uwave.sh --compose-file /opt/bee-edge/docker-compose.yml
  sudo ./install-mitutoyo-uwave.sh --container bee-edge-0-iiot-1
  sudo ./install-mitutoyo-uwave.sh --virtual-port /dev/ttyUWave --message-format json
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      NODE_RED_CONTAINER="${2:-}"
      shift 2
      ;;
    --serials)
      SERIALS_CSV="${2:-}"
      shift 2
      ;;
    --vid)
      VID="${2:-}"
      shift 2
      ;;
    --pid)
      PID="${2:-}"
      shift 2
      ;;
    --compose-file)
      COMPOSE_FILE="${2:-}"
      PATCH_COMPOSE="yes"
      shift 2
      ;;
    --compose-service)
      COMPOSE_SERVICE="${2:-}"
      shift 2
      ;;
    --no-compose-patch)
      PATCH_COMPOSE="no"
      shift
      ;;
    --no-compose-up)
      COMPOSE_UP="0"
      shift
      ;;
    --no-palette-install)
      INSTALL_PALETTE="0"
      shift
      ;;
    --no-node-red-restart)
      RESTART_NODE_RED="0"
      shift
      ;;
    --no-aggregator)
      AGGREGATOR_ENABLED="0"
      shift
      ;;
    --virtual-port)
      VIRTUAL_PORT="${2:-}"
      shift 2
      ;;
    --message-format)
      AGGREGATOR_FORMAT="${2:-}"
      shift 2
      ;;
    --no-cleanup-legacy)
      CLEAN_LEGACY="0"
      shift
      ;;
    --legacy-devices-map)
      ADD_LEGACY_DEVICES_MAP="1"
      shift
      ;;
    --verify-only)
      VERIFY_ONLY="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$VID" =~ ^[0-9A-Fa-f]{4}$ ]] || die "--vid must be a four-character hex id"
[[ "$PID" =~ ^[0-9A-Fa-f]{4}$ ]] || die "--pid must be a four-character hex id"
[[ -n "$NODE_RED_CONTAINER" ]] || die "--container cannot be empty"
[[ -n "$SERIALS_CSV" ]] || die "--serials cannot be empty"
[[ "$COMPOSE_SERVICE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--compose-service contains unsupported characters"
[[ "$VIRTUAL_PORT" == /dev/* ]] || die "--virtual-port must be an absolute path under /dev"
[[ "$AGGREGATOR_FORMAT" == "json" || "$AGGREGATOR_FORMAT" == "tsv" ]] || die "--message-format must be json or tsv"

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "${ORIGINAL_ARGS[@]}"
  fi
  die "Run as root, or install sudo."
fi

parse_serials() {
  SERIALS=()
  SERIALS_AUTO="0"

  if [[ "${SERIALS_CSV,,}" == "auto" ]]; then
    SERIALS_AUTO="1"
    return 0
  fi

  local raw serial
  IFS=',' read -r -a raw_serials <<< "$SERIALS_CSV"
  for raw in "${raw_serials[@]}"; do
    serial="${raw//[[:space:]]/}"
    [[ -z "$serial" ]] && continue
    [[ "$serial" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Unsupported USB serial value: $serial"
    SERIALS+=("$serial")
  done
  [[ "${#SERIALS[@]}" -gt 0 ]] || die "No usable serials in --serials"
}

add_serial_once() {
  local candidate="$1"
  local existing
  [[ -n "$candidate" ]] || return 0
  [[ "$candidate" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
  for existing in "${SERIALS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  SERIALS+=("$candidate")
}

resolve_auto_serials() {
  [[ "$SERIALS_AUTO" == "1" ]] || return 0

  SERIALS=()
  local dev base serial props

  shopt -s nullglob
  for dev in /dev/ttyUWave_*; do
    base="$(basename "$dev")"
    serial="${base#ttyUWave_}"
    add_serial_once "$serial"
  done

  if [[ "${#SERIALS[@]}" -eq 0 ]]; then
    for dev in /dev/ttyUSB*; do
      props="$(udevadm info --query=property --name="$dev" 2>/dev/null || true)"
      if grep -q "^ID_VENDOR_ID=${VID}$" <<< "$props" && grep -q "^ID_MODEL_ID=${PID}$" <<< "$props"; then
        serial="$(awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}' <<< "$props")"
        add_serial_once "$serial"
      fi
    done
  fi

  if [[ "${#SERIALS[@]}" -gt 0 ]]; then
    log "Detected receiver serials: ${SERIALS[*]}"
  else
    warn "No receiver serials detected yet. The aggregate service will pick them up when they appear."
  fi
}

require_host_commands() {
  local missing=()
  for cmd in modprobe udevadm systemctl install chmod; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ "$AGGREGATOR_ENABLED" == "1" ]]; then
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
  fi
  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing required host commands: ${missing[*]}"
  fi
}

detect_compose_file() {
  [[ "$PATCH_COMPOSE" == "no" ]] && return 0
  [[ -n "$COMPOSE_FILE" ]] && return 0

  local candidate
  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$candidate" ]]; then
      COMPOSE_FILE="$(pwd)/$candidate"
      log "Auto-detected compose file: $COMPOSE_FILE"
      return 0
    fi
  done
}

cleanup_legacy_install() {
  [[ "$CLEAN_LEGACY" == "1" ]] || return 0

  log "Cleaning legacy Mitutoyo setup before install."
  install -d -m 0755 "$INSTALL_DIR"

  local backup_dir=""
  backup_legacy_file() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ -z "$backup_dir" ]]; then
      backup_dir="${INSTALL_DIR}/legacy-backup-$(date +%Y%m%d-%H%M%S)"
      install -d -m 0755 "$backup_dir"
    fi
    cp -a "$path" "$backup_dir/" 2>/dev/null || true
  }

  systemctl stop mitutoyo-uwave-aggregator.service >/dev/null 2>&1 || true

  local legacy_rule
  for legacy_rule in \
    /etc/udev/rules.d/99-mitutoyo-bind.rules \
    /etc/udev/rules.d/99-mitutoyo-tty.rules
  do
    if [[ -e "$legacy_rule" || -L "$legacy_rule" ]]; then
      backup_legacy_file "$legacy_rule"
      rm -f "$legacy_rule"
      log "Removed legacy udev rule: $legacy_rule"
    fi
  done

  if [[ -e "$BIND_SCRIPT" || -L "$BIND_SCRIPT" ]]; then
    backup_legacy_file "$BIND_SCRIPT"
    rm -f "$BIND_SCRIPT"
    log "Removed old bind script: $BIND_SCRIPT"
  fi

  if [[ -L "$VIRTUAL_PORT" ]]; then
    backup_legacy_file "$VIRTUAL_PORT"
    rm -f "$VIRTUAL_PORT"
    log "Removed stale virtual port symlink: $VIRTUAL_PORT"
  elif [[ -e "$VIRTUAL_PORT" ]]; then
    warn "$VIRTUAL_PORT exists and is not a symlink; leaving it untouched."
  fi

  if [[ -f /etc/modules ]] && grep -Eq '^[[:space:]]*ftdi_sio([[:space:]]*(#.*)?)?$' /etc/modules; then
    backup_legacy_file /etc/modules
    local tmp_modules
    tmp_modules="$(mktemp)"
    grep -Ev '^[[:space:]]*ftdi_sio([[:space:]]*(#.*)?)?$' /etc/modules > "$tmp_modules" || true
    cat "$tmp_modules" > /etc/modules
    rm -f "$tmp_modules"
    log "Removed legacy ftdi_sio line from /etc/modules; using $MODULES_LOAD_FILE instead."
  fi

  if [[ -n "$backup_dir" ]]; then
    log "Legacy backup saved in: $backup_dir"
  fi
}

write_host_files() {
  log "Writing host driver, udev and systemd files."
  install -d -m 0755 "$INSTALL_DIR"

  cat > "$MODULES_LOAD_FILE" <<EOF
ftdi_sio
EOF

  cat > "$ENV_FILE" <<EOF
NODE_RED_CONTAINER="$NODE_RED_CONTAINER"
MITUTOYO_VID="$VID"
MITUTOYO_PID="$PID"
RESTART_NODE_RED="$RESTART_NODE_RED"
VIRTUAL_PORT="$VIRTUAL_PORT"
AGGREGATOR_FORMAT="$AGGREGATOR_FORMAT"
AGGREGATOR_DEVICE_GLOB="/dev/ttyUWave_*"
EOF

  cat > "$BIND_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u

ENV_FILE="/etc/default/mitutoyo-uwave"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

NODE_RED_CONTAINER="${NODE_RED_CONTAINER:-bee-edge-0-iiot-1}"
VID="${1:-${MITUTOYO_VID:-0fe7}}"
PID="${2:-${MITUTOYO_PID:-2002}}"
RESTART_NODE_RED="${RESTART_NODE_RED:-1}"

uwave_log() {
  local msg="[U-WAVE] $*"
  echo "$msg"
  if command -v logger >/dev/null 2>&1; then
    logger -t mitutoyo-uwave "$msg"
  fi
}

uwave_log "Mitutoyo device event detected. VID:${VID} PID:${PID}"

if ! modprobe ftdi_sio 2>/dev/null; then
  uwave_log "WARN: failed to load ftdi_sio"
fi

if [[ -w /sys/bus/usb-serial/drivers/ftdi_sio/new_id ]]; then
  printf '%s %s\n' "$VID" "$PID" > /sys/bus/usb-serial/drivers/ftdi_sio/new_id 2>/dev/null || true
else
  uwave_log "WARN: ftdi_sio new_id is not writable"
fi

udevadm settle --timeout=8 >/dev/null 2>&1 || true
sleep 1

shopt -s nullglob
for port in /dev/ttyUSB*; do
  if udevadm info --query=property --name="$port" 2>/dev/null | grep -q "^ID_VENDOR_ID=${VID}$"; then
    printf '\x02\r' > "$port" 2>/dev/null || true
    uwave_log "INIT sent to $port"
  fi
done

if [[ "$RESTART_NODE_RED" == "1" ]] && command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -qx "$NODE_RED_CONTAINER"; then
    docker restart "$NODE_RED_CONTAINER" >/dev/null 2>&1 \
      && uwave_log "Node-RED container restarted: $NODE_RED_CONTAINER" \
      || uwave_log "WARN: failed to restart Node-RED container: $NODE_RED_CONTAINER"
  else
    uwave_log "Node-RED container not running or not found: $NODE_RED_CONTAINER"
  fi
fi
EOF
  chmod 0755 "$BIND_SCRIPT"

  cat > "$AGGREGATOR_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import errno
import fcntl
import glob
import json
import os
import pty
import re
import select
import signal
import sys
import termios
import time
import tty

BAUD = termios.B57600
INIT_BYTES = b"\x02\r"
RUNNING = True


def log(message):
    print(f"[U-WAVE aggregator] {message}", flush=True)


def stop(_signum, _frame):
    global RUNNING
    RUNNING = False


class SerialPort:
    def __init__(self, alias, fd):
        self.alias = alias
        self.fd = fd
        self.buffer = b""
        self.receiver = os.path.basename(alias).replace("ttyUWave_", "", 1)


def configure_serial(fd):
    attrs = termios.tcgetattr(fd)
    attrs[0] = termios.IGNBRK
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = BAUD
    attrs[5] = BAUD
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def create_virtual_port(path):
    master_fd, slave_fd = pty.openpty()
    slave_name = os.ttyname(slave_fd)
    tty.setraw(slave_fd)
    os.chmod(slave_name, 0o666)
    flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
    fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    if os.path.lexists(path):
        if os.path.islink(path):
            os.unlink(path)
        else:
            raise RuntimeError(f"{path} already exists and is not a symlink")

    os.symlink(slave_name, path)
    log(f"virtual port {path} -> {slave_name}")
    os.close(slave_fd)
    return master_fd, slave_name


def cleanup_virtual_port(path, slave_name):
    try:
        if os.path.islink(path) and os.readlink(path) == slave_name:
            os.unlink(path)
    except OSError:
        pass


def open_serial(alias):
    fd = os.open(alias, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure_serial(fd)
    try:
        os.write(fd, INIT_BYTES)
    except OSError:
        pass
    return SerialPort(alias, fd)


def discover_ports(pattern, known_aliases):
    aliases = []
    for alias in sorted(glob.glob(pattern)):
        base = os.path.basename(alias)
        if not base.startswith("ttyUWave_"):
            continue
        if alias in known_aliases:
            continue
        aliases.append(alias)
    return aliases


def parse_raw(raw):
    if raw.startswith("DT"):
        match = re.match(r"^DT(\d{5})([+-]\d+\.\d+)([A-Za-z])?", raw)
        if match:
            return {
                "type": "measurement",
                "channel": match.group(1),
                "value": float(match.group(2)),
                "unit": match.group(3) or "",
            }
    if raw.startswith("ST"):
        return {"type": "status"}
    return {"type": "raw"}


def emit_line(master_fd, port, raw, output_format):
    if output_format == "tsv":
        payload = f"{port.alias}\t{raw}\r".encode("utf-8", "replace")
    else:
        msg = {
            "port": port.alias,
            "receiver": port.receiver,
            "raw": raw,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }
        msg.update(parse_raw(raw))
        payload = (json.dumps(msg, separators=(",", ":")) + "\r").encode("utf-8")

    try:
        os.write(master_fd, payload)
    except OSError as exc:
        if exc.errno not in (errno.EIO, errno.ENXIO, errno.EAGAIN, errno.EWOULDBLOCK):
            log(f"failed to write virtual port: {exc}")


def consume_port_data(master_fd, port, data, output_format):
    port.buffer += data
    while True:
        positions = [idx for idx in (port.buffer.find(b"\r"), port.buffer.find(b"\n")) if idx >= 0]
        if not positions:
            if len(port.buffer) > 4096:
                raw = port.buffer.decode("ascii", "replace").strip()
                port.buffer = b""
                if raw:
                    emit_line(master_fd, port, raw, output_format)
            return

        idx = min(positions)
        line = port.buffer[:idx]
        port.buffer = port.buffer[idx + 1 :]
        while port.buffer.startswith((b"\r", b"\n")):
            port.buffer = port.buffer[1:]

        raw = line.decode("ascii", "replace").strip()
        if raw:
            emit_line(master_fd, port, raw, output_format)


def close_port(port):
    try:
        os.close(port.fd)
    except OSError:
        pass
    log(f"closed {port.alias}")


def main():
    parser = argparse.ArgumentParser(description="Aggregate Mitutoyo U-WAVE serial ports into one PTY.")
    parser.add_argument("--glob", default="/dev/ttyUWave_*", help="Physical stable alias glob.")
    parser.add_argument("--virtual-port", default="/dev/ttyUWave", help="Virtual aggregate PTY symlink.")
    parser.add_argument("--format", choices=("json", "tsv"), default="json", help="Output line format.")
    parser.add_argument("--scan-interval", type=float, default=1.0, help="Seconds between hotplug scans.")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    master_fd, slave_name = create_virtual_port(args.virtual_port)
    ports = {}
    last_scan = 0.0

    try:
        while RUNNING:
            now = time.monotonic()
            if now - last_scan >= args.scan_interval:
                last_scan = now
                for alias in list(ports):
                    if not os.path.exists(alias):
                        close_port(ports.pop(alias))

                for alias in discover_ports(args.glob, ports):
                    try:
                        ports[alias] = open_serial(alias)
                        log(f"opened {alias}; INIT sent")
                    except OSError as exc:
                        log(f"could not open {alias}: {exc}")

            read_fds = [master_fd] + [port.fd for port in ports.values()]
            try:
                readable, _, _ = select.select(read_fds, [], [], 0.5)
            except OSError as exc:
                log(f"select failed: {exc}")
                time.sleep(0.5)
                continue

            for fd in readable:
                if fd == master_fd:
                    try:
                        data = os.read(master_fd, 4096)
                    except OSError as exc:
                        if exc.errno not in (errno.EIO, errno.ENXIO):
                            log(f"virtual port read failed: {exc}")
                        continue

                    if not data:
                        continue

                    for port in list(ports.values()):
                        try:
                            os.write(port.fd, data)
                        except OSError as exc:
                            log(f"write to {port.alias} failed: {exc}")
                            close_port(ports.pop(port.alias, port))
                    continue

                port = next((candidate for candidate in ports.values() if candidate.fd == fd), None)
                if port is None:
                    continue

                try:
                    data = os.read(port.fd, 4096)
                except OSError as exc:
                    log(f"read from {port.alias} failed: {exc}")
                    close_port(ports.pop(port.alias, port))
                    continue

                if data:
                    consume_port_data(master_fd, port, data, args.format)

    finally:
        for port in list(ports.values()):
            close_port(port)
        cleanup_virtual_port(args.virtual_port, slave_name)
        os.close(master_fd)


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$AGGREGATOR_SCRIPT"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bind Mitutoyo U-WAVE-R to FTDI serial driver
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
EnvironmentFile=-$ENV_FILE
ExecStart=$BIND_SCRIPT
EOF

  cat > "$AGGREGATOR_SERVICE_FILE" <<EOF
[Unit]
Description=Aggregate Mitutoyo U-WAVE-R receivers into one virtual serial port
After=mitutoyo-uwave-bind.service
Wants=mitutoyo-uwave-bind.service

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
ExecStart=$AGGREGATOR_SCRIPT --glob \${AGGREGATOR_DEVICE_GLOB} --virtual-port \${VIRTUAL_PORT} --format \${AGGREGATOR_FORMAT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UDEV_RULE_FILE" <<EOF
# Mitutoyo U-WAVE-R 0fe7:2002 -> FTDI serial driver + stable aliases.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", TAG+="systemd", ENV{SYSTEMD_WANTS}+="mitutoyo-uwave-bind.service"
SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="$VID", ENV{ID_MODEL_ID}=="$PID", ENV{ID_SERIAL_SHORT}!="", SYMLINK+="ttyUWave%n", SYMLINK+="ttyUWave_\$env{ID_SERIAL_SHORT}", MODE="0666", GROUP="dialout"
EOF

  systemctl daemon-reload
}

patch_compose_file() {
  [[ "$PATCH_COMPOSE" == "no" ]] && return 0

  if [[ -z "$COMPOSE_FILE" ]]; then
    warn "No compose file found in current directory. Host install will still work."
    warn "Run again with --compose-file /path/to/docker-compose.yml to patch Docker access automatically."
    return 0
  fi

  [[ -f "$COMPOSE_FILE" ]] || die "Compose file does not exist: $COMPOSE_FILE"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; cannot patch compose safely."
    return 0
  fi

  log "Patching Docker Compose service '$COMPOSE_SERVICE' in $COMPOSE_FILE."
  COMPOSE_FILE="$COMPOSE_FILE" \
  COMPOSE_SERVICE="$COMPOSE_SERVICE" \
  ADD_LEGACY_DEVICES_MAP="$ADD_LEGACY_DEVICES_MAP" \
  python3 - <<'PY'
import os
import re
import shutil
import sys

path = os.environ["COMPOSE_FILE"]
service = os.environ["COMPOSE_SERVICE"]
add_devices = os.environ.get("ADD_LEGACY_DEVICES_MAP") == "1"

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

def indent(line):
    return len(line) - len(line.lstrip(" "))

def is_data(line):
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("#")

def key_regex(key):
    return re.compile(rf"^\s*['\"]?{re.escape(key)}['\"]?\s*:\s*(?:#.*)?$")

services_idx = None
services_indent = 0
for i, line in enumerate(lines):
    if re.match(r"^\s*services\s*:\s*(?:#.*)?$", line):
        services_idx = i
        services_indent = indent(line)
        break

if services_idx is None:
    print(f"ERROR: services: block not found in {path}", file=sys.stderr)
    sys.exit(2)

service_start = None
service_indent = None
service_pat = re.compile(rf"^\s*['\"]?{re.escape(service)}['\"]?\s*:\s*(?:#.*)?$")
for i in range(services_idx + 1, len(lines)):
    line = lines[i]
    if not is_data(line):
        continue
    current_indent = indent(line)
    if current_indent <= services_indent:
        break
    if current_indent > services_indent and service_pat.match(line):
        service_start = i
        service_indent = current_indent
        break

if service_start is None:
    print(f"WARN: service '{service}' not found in {path}; compose was not changed.", file=sys.stderr)
    sys.exit(0)

service_end = len(lines)
for i in range(service_start + 1, len(lines)):
    line = lines[i]
    if not is_data(line):
        continue
    if indent(line) <= service_indent:
        service_end = i
        break

key_indent = service_indent + 2
item_indent = key_indent + 2

def find_key(key):
    pat = re.compile(rf"^\s*['\"]?{re.escape(key)}['\"]?\s*:")
    for i in range(service_start + 1, service_end):
        if is_data(lines[i]) and indent(lines[i]) == key_indent and pat.match(lines[i]):
            return i
    return None

def key_end(key_idx):
    for i in range(key_idx + 1, service_end):
        if is_data(lines[i]) and indent(lines[i]) <= key_indent:
            return i
    return service_end

def line_has_item(line, item):
    text = line.strip().strip("'\"")
    if not text.startswith("-"):
        return False
    value = text[1:].strip().strip("'\"")
    return value == item or value.startswith(item + ":") or item in value

changed = False

def ensure_list_item(key, item, quote=False):
    global lines, service_end, changed
    key_idx = find_key(key)
    item_text = f"{' ' * item_indent}- "
    item_text += f"\"{item}\"" if quote else item
    item_text += "\n"

    if key_idx is None:
        insert = service_end
        block = [f"{' ' * key_indent}{key}:\n", item_text]
        lines[insert:insert] = block
        service_end += len(block)
        changed = True
        return

    end = key_end(key_idx)
    existing_block = lines[key_idx:end]
    if any(line_has_item(line, item) for line in existing_block):
        return

    same_line_value = lines[key_idx].split(":", 1)[1].strip()
    if same_line_value and same_line_value not in ("[]", "{}"):
        print(
            f"WARN: '{key}' uses inline syntax; add '{item}' manually if needed.",
            file=sys.stderr,
        )
        return

    lines[end:end] = [item_text]
    service_end += 1
    changed = True

ensure_list_item("volumes", "/dev:/dev")
ensure_list_item("group_add", "dialout")
ensure_list_item("device_cgroup_rules", "c 188:* rmw", quote=True)
ensure_list_item("device_cgroup_rules", "c 136:* rmw", quote=True)
if add_devices:
    ensure_list_item("devices", "/dev:/dev")

if changed:
    backup = path + ".mitutoyo.bak"
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"Patched compose file. Backup: {backup}")
else:
    print("Compose file already contained required entries, or no safe edit was needed.")
PY

  if [[ "$COMPOSE_UP" == "1" ]] && command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      log "Recreating compose service '$COMPOSE_SERVICE' with docker compose."
      docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$COMPOSE_SERVICE" || warn "docker compose up failed"
    elif command -v docker-compose >/dev/null 2>&1; then
      log "Recreating compose service '$COMPOSE_SERVICE' with docker-compose."
      docker-compose -f "$COMPOSE_FILE" up -d --force-recreate "$COMPOSE_SERVICE" || warn "docker-compose up failed"
    else
      warn "Docker Compose command not found; compose file was patched but service was not recreated."
    fi
  fi
}

ensure_node_red_serial_palette() {
  [[ "$INSTALL_PALETTE" == "1" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  if ! docker ps --format '{{.Names}}' | grep -qx "$NODE_RED_CONTAINER"; then
    warn "Container '$NODE_RED_CONTAINER' is not running; skipping Node-RED palette check."
    return 0
  fi

  log "Checking Node-RED serial palette inside '$NODE_RED_CONTAINER'."
  if docker exec "$NODE_RED_CONTAINER" sh -lc 'test -d /data/node_modules/node-red-node-serialport || test -d /usr/src/node-red/node_modules/node-red-node-serialport' >/dev/null 2>&1; then
    log "node-red-node-serialport is already present."
    return 0
  fi

  if docker exec "$NODE_RED_CONTAINER" sh -lc 'command -v npm >/dev/null 2>&1' >/dev/null 2>&1; then
    log "Installing node-red-node-serialport in /data."
    if docker exec "$NODE_RED_CONTAINER" sh -lc 'cd /data && npm install --unsafe-perm node-red-node-serialport'; then
      docker restart "$NODE_RED_CONTAINER" >/dev/null 2>&1 || warn "failed to restart '$NODE_RED_CONTAINER' after palette install"
    else
      warn "npm install node-red-node-serialport failed. Install it from Node-RED Manage palette if the import complains about missing serial nodes."
    fi
  else
    warn "npm not found in container. Install node-red-node-serialport from Node-RED Manage palette if needed."
  fi
}

generate_node_red_flow() {
  log "Generating Node-RED import flow: $FLOW_FILE"
  install -d -m 0755 "$INSTALL_DIR"

  cat > "$FLOW_FILE" <<EOF
[
  {
    "id": "tab_mitutoyo_uwave",
    "type": "tab",
    "label": "Mitutoyo U-WAVE",
    "disabled": false,
    "info": ""
  },
  {
    "id": "serial_uwave_aggregate",
    "type": "serial-port",
    "name": "U-WAVE aggregate",
    "serialport": "$VIRTUAL_PORT",
    "serialbaud": "57600",
    "databits": "8",
    "parity": "none",
    "stopbits": "1",
    "waitfor": "",
    "dtr": "none",
    "rts": "none",
    "cts": "none",
    "dsr": "none",
    "newline": "\\r",
    "bin": "false",
    "out": "char",
    "addchar": "",
    "responsetimeout": "10000"
  },
  {
    "id": "inject_init_all_uwave",
    "type": "inject",
    "z": "tab_mitutoyo_uwave",
    "name": "INIT all U-WAVE",
    "props": [
      {
        "p": "payload"
      }
    ],
    "repeat": "",
    "crontab": "",
    "once": true,
    "onceDelay": "3",
    "topic": "",
    "payload": "",
    "payloadType": "date",
    "x": 120,
    "y": 100,
    "wires": [
      [
        "fn_init_all_uwave"
      ]
    ]
  },
  {
    "id": "fn_init_all_uwave",
    "type": "function",
    "z": "tab_mitutoyo_uwave",
    "name": "0x02 0x0D",
    "func": "msg.payload = Buffer.from([0x02, 0x0D]);\\nreturn msg;",
    "outputs": 1,
    "timeout": 0,
    "noerr": 0,
    "initialize": "",
    "finalize": "",
    "libs": [],
    "x": 310,
    "y": 100,
    "wires": [
      [
        "serial_out_uwave_aggregate"
      ]
    ]
  },
  {
    "id": "serial_out_uwave_aggregate",
    "type": "serial out",
    "z": "tab_mitutoyo_uwave",
    "name": "TX aggregate",
    "serial": "serial_uwave_aggregate",
    "x": 500,
    "y": 100,
    "wires": []
  },
  {
    "id": "serial_in_uwave_aggregate",
    "type": "serial in",
    "z": "tab_mitutoyo_uwave",
    "name": "RX aggregate",
    "serial": "serial_uwave_aggregate",
    "x": 120,
    "y": 170,
    "wires": [
      [
        "fn_parse_aggregate_uwave"
      ]
    ]
  },
  {
    "id": "fn_parse_aggregate_uwave",
    "type": "function",
    "z": "tab_mitutoyo_uwave",
    "name": "Parse aggregate JSON",
    "func": "const line = String(msg.payload).trim();\ntry {\n    msg.payload = JSON.parse(line);\n    msg.topic = msg.payload.port || msg.payload.receiver || '';\n    return msg;\n} catch (err) {\n    const parts = line.split('\\t');\n    if (parts.length >= 2) {\n        msg.payload = { port: parts[0], receiver: parts[0].replace(/^.*ttyUWave_/, ''), raw: parts.slice(1).join('\\t') };\n        msg.topic = msg.payload.port;\n        return msg;\n    }\n    msg.payload = { type: 'raw', raw: line };\n    return msg;\n}",
    "outputs": 1,
    "timeout": 0,
    "noerr": 0,
    "initialize": "",
    "finalize": "",
    "libs": [],
    "x": 360,
    "y": 170,
    "wires": [
      [
        "debug_aggregate_uwave"
      ]
    ]
  },
  {
    "id": "debug_aggregate_uwave",
    "type": "debug",
    "z": "tab_mitutoyo_uwave",
    "name": "U-WAVE aggregate",
    "active": true,
    "tosidebar": true,
    "console": false,
    "tostatus": false,
    "complete": "payload",
    "targetType": "msg",
    "statusVal": "",
    "statusType": "auto",
    "x": 610,
    "y": 170,
    "wires": []
  }
]
EOF
}

activate_host_rules() {
  log "Loading ftdi_sio and reloading udev."
  modprobe ftdi_sio || warn "modprobe ftdi_sio failed"
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb || true
  udevadm trigger --subsystem-match=tty || true
  udevadm settle --timeout=10 || true

  log "Running initial Mitutoyo bind/INIT pass."
  systemctl start mitutoyo-uwave-bind.service || warn "systemd bind service failed"

  if [[ "$AGGREGATOR_ENABLED" == "1" ]]; then
    log "Enabling and restarting Mitutoyo aggregate port service."
    systemctl enable mitutoyo-uwave-aggregator.service >/dev/null 2>&1 || warn "failed to enable aggregate port service"
    systemctl restart mitutoyo-uwave-aggregator.service || warn "failed to restart aggregate port service"

    if [[ "$RESTART_NODE_RED" == "1" ]] && command -v docker >/dev/null 2>&1; then
      if docker ps --format '{{.Names}}' | grep -qx "$NODE_RED_CONTAINER"; then
        docker restart "$NODE_RED_CONTAINER" >/dev/null 2>&1 || warn "failed to restart '$NODE_RED_CONTAINER' after aggregate port start"
      fi
    fi
  else
    systemctl disable --now mitutoyo-uwave-aggregator.service >/dev/null 2>&1 || true
  fi
}

verify_state() {
  echo
  log "Verification"
  resolve_auto_serials

  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
      log "USB ${VID}:${PID} is present:"
      lsusb -d "${VID}:${PID}" || true
    else
      warn "USB ${VID}:${PID} not currently visible. Plug the U-WAVE-R receivers in, or reboot."
    fi
  else
    warn "lsusb not found; skipping USB presence check."
  fi

  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    log "ttyUSB devices:"
    ls -l /dev/ttyUSB* || true
  else
    warn "No /dev/ttyUSB* devices currently visible."
  fi

  if ls /dev/ttyUWave* >/dev/null 2>&1; then
    log "Mitutoyo aliases:"
    ls -l /dev/ttyUWave* || true
  else
    warn "No /dev/ttyUWave* aliases yet. Replug receivers or reboot if they are already connected."
  fi

  local serial
  for serial in "${SERIALS[@]}"; do
    if [[ -e "/dev/ttyUWave_${serial}" ]]; then
      log "OK: /dev/ttyUWave_${serial}"
    else
      warn "Missing expected alias: /dev/ttyUWave_${serial}"
    fi
  done

  if [[ "$AGGREGATOR_ENABLED" == "1" ]]; then
    if [[ -e "$VIRTUAL_PORT" ]]; then
      log "Aggregate Node-RED port:"
      ls -l "$VIRTUAL_PORT" || true
    else
      warn "Aggregate port is not present yet: $VIRTUAL_PORT"
    fi

    if systemctl is-active --quiet mitutoyo-uwave-aggregator.service; then
      log "Aggregate service is active: mitutoyo-uwave-aggregator.service"
    else
      warn "Aggregate service is not active. Check: journalctl -u mitutoyo-uwave-aggregator.service -b"
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -qx "$NODE_RED_CONTAINER"; then
      log "Container is running: $NODE_RED_CONTAINER"
      docker exec "$NODE_RED_CONTAINER" sh -lc 'ls -l /dev/ttyUWave* 2>/dev/null || true' || true
    else
      warn "Container not running or not found: $NODE_RED_CONTAINER"
    fi
  else
    warn "docker command not found; skipping container check."
  fi

  echo
  log "Node-RED flow import file: $FLOW_FILE"
  log "Import it in Node-RED: menu -> Import -> select file/clipboard -> Deploy."
  log "Node-RED should use one serial port: $VIRTUAL_PORT"
  log "Logs: journalctl -b -t mitutoyo-uwave; journalctl -u mitutoyo-uwave-aggregator.service -b"
}

main() {
  parse_serials
  require_host_commands

  if [[ "$VERIFY_ONLY" == "1" ]]; then
    verify_state
    exit 0
  fi

  detect_compose_file
  cleanup_legacy_install
  write_host_files
  patch_compose_file
  ensure_node_red_serial_palette
  generate_node_red_flow
  activate_host_rules
  verify_state
}

main "$@"
