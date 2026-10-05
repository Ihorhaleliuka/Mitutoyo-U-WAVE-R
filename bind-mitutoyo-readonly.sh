#!/usr/bin/env bash
set -euo pipefail
modprobe ftdi_sio
printf '0fe7 2002\n' > /sys/bus/usb-serial/drivers/ftdi_sio/new_id 2>/dev/null || true
udevadm settle --timeout=8 || true
logger -t mitutoyo-uwave 'FTDI binding ready; information polling owned by aggregator; no INIT or container restart'
