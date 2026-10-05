"""Linux PTY end-to-end test. No real devices or MQTT needed."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import tty
import unittest


@unittest.skipUnless(sys.platform == 'linux', 'Linux PTY integration')
class IntegrationTest(unittest.TestCase):
    def test_inventory_measurement_and_unplug(self):
        root = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as tmp:
            master, slave = pty.openpty()
            tty.setraw(slave)
            os.set_blocking(master, False)
            alias = Path(tmp) / 'ttyUWave_TEST'
            alias.symlink_to(os.ttyname(slave))
            virtual = Path(tmp) / 'aggregate'
            proc = subprocess.Popen([sys.executable, str(root/'uwave_aggregator.py'),
                                     '--glob', str(Path(tmp)/'ttyUWave_*'),
                                     '--virtual-port', str(virtual)], stdout=subprocess.DEVNULL)
            reader = None
            try:
                deadline = time.monotonic() + 12
                commands, rx, messages = b'', b'', []
                got_measurement = False
                while time.monotonic() < deadline:
                    if reader is None and virtual.exists():
                        reader = os.open(virtual, os.O_RDONLY | os.O_NONBLOCK)
                    fds = [master] + ([reader] if reader is not None else [])
                    ready, _, _ = select.select(fds, [], [], .05)
                    if master in ready:
                        commands += os.read(master, 4096)
                        while b'\r' in commands:
                            cmd, commands = commands.split(b'\r', 1)
                            if cmd == b'IR1000000':
                                answer = 'RI10010000613582390' + '255'*16
                            elif cmd == b'IR1100001':
                                answer = 'TI1205000123456789230'
                            elif cmd == b'IR1106001':
                                answer = 'ST10006FFFFFFFFFF51\rDT10005+00000020.06M'
                            else:
                                self.fail('Unexpected or non-read-only command: ' + repr(cmd))
                            os.write(master, (answer+'\r').encode())
                    if reader in ready:
                        rx += os.read(reader, 65536)
                        while b'\r' in rx:
                            line, rx = rx.split(b'\r', 1)
                            messages.append(json.loads(line))
                    if not got_measurement and any(m['type'] == 'measurement' for m in messages):
                        got_measurement = True
                        alias.unlink()
                    if any(m['type'] == 'health' and not m['usbConnected'] for m in messages):
                        break
                measurements = [m for m in messages if m['type'] == 'measurement']
                self.assertEqual(len(measurements), 1)
                self.assertEqual(measurements[0]['receiverDeviceId'], '1000061358')
                self.assertEqual(measurements[0]['transmitterDeviceId'], '0123456789')
                self.assertTrue(any(m['type'] == 'inventory' and m['complete'] for m in messages))
                self.assertTrue(any(m['type'] == 'health' and not m['usbConnected'] for m in messages))
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                if reader is not None:
                    os.close(reader)
                os.close(master)
                os.close(slave)
