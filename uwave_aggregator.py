#!/usr/bin/env python3
"""Aggregate serial data and poll documented information requests only."""
import argparse
import collections
import errno
import glob
import json
import os
import pty
import select
import signal
import termios
import time
import tty
from uwave_info import Inventory, parse_packet, timestamp

RUNNING = True


def log(message):
    print('[U-WAVE] ' + message, flush=True)


def stop(*_args):
    global RUNNING
    RUNNING = False


class Port:
    def __init__(self, path, now):
        self.path = path
        self.serial = os.path.basename(path).removeprefix('ttyUWave_')
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            attrs = termios.tcgetattr(self.fd)
            attrs[:6] = [termios.IGNBRK, 0, termios.CS8 | termios.CREAD | termios.CLOCAL,
                         0, termios.B57600, termios.B57600]
            attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 1
            termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
            stat = os.fstat(self.fd)
            self.identity = (stat.st_dev, stat.st_ino, stat.st_rdev)
        except Exception:
            os.close(self.fd)
            raise
        self.rx = b''
        self.tx = b''
        self.inventory = Inventory()
        self.inventory.next_at = now + 2
        self.last_received = None
        self.last_measurement = None
        self.last_status = None
        self.next_health = now + 30

    def present(self):
        try:
            s = os.stat(self.path)
            return (s.st_dev, s.st_ino, s.st_rdev) == self.identity
        except OSError:
            return False

    def envelope(self, data):
        return dict(self.inventory.enrich(data), receiver=self.serial,
                    receiverUsbSerial=self.serial, port=self.path, ts=timestamp())

    def health(self, online=True):
        return self.envelope({'type': 'health', 'usbConnected': online,
                              'lastReceivedAt': self.last_received,
                              'lastMeasurementAt': self.last_measurement,
                              'lastStatus': self.last_status,
                              'inventoryComplete': self.inventory.complete,
                              'inventoryError': self.inventory.error})


class Output:
    def __init__(self):
        self.queue = collections.deque()
        self.size = 0

    def add(self, message):
        data = (json.dumps(message, separators=(',', ':')) + '\r').encode()
        if self.size + len(data) > 1024 * 1024:
            log('output queue full; dropped event (no durable spool configured)')
            return
        self.queue.append(data)
        self.size += len(data)

    def flush(self, fd):
        if not self.queue:
            return
        try:
            n = os.write(fd, self.queue[0])
        except BlockingIOError:
            return
        self.size -= n
        remaining = self.queue.popleft()[n:]
        if remaining:
            self.queue.appendleft(remaining)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--glob', default='/dev/ttyUWave_*')
    parser.add_argument('--virtual-port', default='/dev/ttyUWave')
    parser.add_argument('--format', choices=['json'], default='json')
    parser.add_argument('--scan-interval', type=float, default=1)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    master, slave = pty.openpty()
    tty.setraw(slave)
    os.chmod(os.ttyname(slave), 0o666)
    os.set_blocking(master, False)
    if os.path.lexists(args.virtual_port):
        if not os.path.islink(args.virtual_port):
            raise RuntimeError('Refusing to replace non-symlink virtual port')
        os.unlink(args.virtual_port)
    slave_name = os.ttyname(slave)
    os.symlink(slave_name, args.virtual_port)
    log(f'virtual port {args.virtual_port} -> {slave_name}; read-only information polling')
    ports = {}
    output = Output()
    next_scan = 0

    def close(path, reason):
        port = ports.pop(path)
        output.add(port.health(False))
        os.close(port.fd)
        log(f'closed {path}: {reason}')

    try:
        while RUNNING:
            now = time.monotonic()
            if now >= next_scan:
                next_scan = now + args.scan_interval
                for path, port in list(ports.items()):
                    if not port.present():
                        close(path, 'device removed or replaced')
                for path in sorted(glob.glob(args.glob)):
                    if path in ports or not os.path.basename(path).startswith('ttyUWave_'):
                        continue
                    try:
                        ports[path] = Port(path, now)
                        output.add(ports[path].health())
                        log(f'opened {path}; no INIT sent')
                    except OSError as exc:
                        log(f'open {path}: {exc}')
            for port in ports.values():
                revision = port.inventory.revision
                if not port.tx:
                    port.tx = port.inventory.command(now) or b''
                if revision != port.inventory.revision:
                    output.add(port.envelope(port.inventory.snapshot()))
                if now >= port.next_health:
                    output.add(port.health())
                    port.next_health = now + 30
            read_fds = [master] + [p.fd for p in ports.values()]
            write_fds = ([master] if output.queue else []) + [p.fd for p in ports.values() if p.tx]
            readable, writable, _ = select.select(read_fds, write_fds, [], .2)
            if master in writable:
                output.flush(master)
            if master in readable:
                try:
                    if os.read(master, 4096):
                        log('ignored virtual-port command: read-only mode')
                except BlockingIOError:
                    pass
            for path, port in list(ports.items()):
                try:
                    if port.fd in writable:
                        try:
                            port.tx = port.tx[os.write(port.fd, port.tx):]
                        except BlockingIOError:
                            pass
                    if port.fd not in readable:
                        continue
                    try:
                        data = os.read(port.fd, 4096)
                    except BlockingIOError:
                        continue
                    if not data:
                        close(path, 'EOF')
                        continue
                    port.rx += data
                    while b'\r' in port.rx or b'\n' in port.rx:
                        index = min(i for i in (port.rx.find(b'\r'), port.rx.find(b'\n')) if i >= 0)
                        raw = port.rx[:index].decode('ascii', 'replace').strip()
                        port.rx = port.rx[index+1:]
                        if not raw:
                            continue
                        p = parse_packet(raw)
                        port.last_received = timestamp()
                        if p['type'] == 'measurement':
                            port.last_measurement = port.last_received
                        if p['type'] == 'status':
                            port.last_status = dict(p, observedAt=port.last_received)
                        revision = port.inventory.revision
                        port.inventory.accept(p, time.monotonic())
                        output.add(port.envelope(p))
                        if revision != port.inventory.revision:
                            output.add(port.envelope(port.inventory.snapshot()))
                    if len(port.rx) > 8192:
                        log(f'discarded oversized unterminated packet: {path}')
                        port.rx = b''
                except OSError as exc:
                    close(path, str(exc))
    finally:
        for port in ports.values():
            os.close(port.fd)
        if os.path.islink(args.virtual_port) and os.readlink(args.virtual_port) == slave_name:
            os.unlink(args.virtual_port)
        os.close(master)
        os.close(slave)


if __name__ == '__main__':
    main()
