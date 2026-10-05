"""Fresh dedicated Node-RED deployment; credentials are supplied on the target."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess

source = Path(__file__).resolve().parent
root = Path('/opt/mitutoyo-uwave')
data = root / 'nodered-data'
assert not data.exists(), 'Existing data directory: use an upgrade, not fresh deployment'
credentials = json.loads((source / 'broker-credentials.json').read_text())
assert credentials.get('user') and credentials.get('password')
data.mkdir(parents=True, mode=0o750)

def write(path, text, mode=0o644):
    path = Path(path)
    path.write_text(text)
    path.chmod(mode)

for src, dst in [('uwave_info.py', 'uwave_info.py'),
                 ('uwave_aggregator.py', 'mitutoyo-uwave-aggregator.py'),
                 ('bind-mitutoyo-readonly.sh', 'bind-mitutoyo.sh')]:
    path = Path('/usr/local/bin') / dst
    shutil.copyfile(source / src, path)
    path.chmod(0o755)
write('/etc/modules-load.d/mitutoyo-uwave.conf', 'ftdi_sio\n')
write('/etc/udev/rules.d/99-mitutoyo-bind.rules',
      'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0fe7", ATTR{idProduct}=="2002", '
      'RUN+="/usr/bin/systemctl --no-block start mitutoyo-uwave-bind.service"\n')
write('/etc/udev/rules.d/99-mitutoyo-tty.rules',
      'SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="0fe7", ENV{ID_MODEL_ID}=="2002", '
      'ENV{ID_SERIAL_SHORT}!="", SYMLINK+="ttyUWave_$env{ID_SERIAL_SHORT}", MODE="0660", GROUP="dialout"\n')
write('/etc/systemd/system/mitutoyo-uwave-bind.service', '''[Unit]
Description=Bind Mitutoyo U-WAVE to FTDI
[Service]
Type=oneshot
ExecStart=/usr/local/bin/bind-mitutoyo.sh
''')
write('/etc/systemd/system/mitutoyo-uwave-aggregator.service', '''[Unit]
Description=U-WAVE aggregate and read-only inventory
After=mitutoyo-uwave-bind.service
Wants=mitutoyo-uwave-bind.service
[Service]
ExecStart=/usr/local/bin/mitutoyo-uwave-aggregator.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
''')
broker = 'uwave_mqtt_broker'
flow = [
    dict(id='uwave_tab', type='tab', label='Mitutoyo U-WAVE'),
    dict(id='uwave_serial', type='serial-port', serialport='/dev/ttyUWave',
         serialbaud='57600', databits=8, parity='none', stopbits=1,
         waitfor='', dtr='none', rts='none', cts='none', dsr='none',
         newline='\\r', bin='false', out='char', addchar=''),
    dict(id='uwave_in', type='serial in', z='uwave_tab', name='U-WAVE',
         serial='uwave_serial', x=140, y=100, wires=[['uwave_parse']]),
    dict(id='uwave_parse', type='function', z='uwave_tab', name='U-WAVE JSON',
         outputs=1, x=360, y=100, wires=[['uwave_mqtt_out']], func='''let data;
try { data = JSON.parse(String(msg.payload).trim()); }
catch (e) { node.warn("Invalid U-WAVE JSON"); return null; }
if (!data.receiver || !/^[A-Za-z0-9_-]+$/.test(data.receiver) ||
    !/^[A-Za-z0-9_-]+$/.test(data.type || 'raw')) return null;
const deviceId = String(data.receiverDeviceId || '');
msg.topic = /^\\d{10}$/.test(deviceId) && deviceId !== '0000000000'
    ? `mitutoyo/uwave/${deviceId}/${data.type || 'raw'}`
    : `mitutoyo/uwave/unidentified/${data.receiver}/${data.type || 'raw'}`;
msg.payload = Object.assign({port:null, raw:null, channel:null, value:null, unit:null,
    receiverDeviceId:null, transmitterDeviceId:null}, data);
msg.qos = '1';
msg.retain = false;
return msg;'''),
    dict(id=broker, type='mqtt-broker', name='BEEDIGIT MQTT',
         broker='mqtt-v1.beedigit.com', port='1883',
         clientid='uwave-' + socket.gethostname(), autoConnect=True, usetls=False,
         protocolVersion='4', keepalive='60', cleansession=True, autoUnsubscribe=True),
    dict(id='uwave_mqtt_out', type='mqtt out', z='uwave_tab', name='U-WAVE to MQTT',
         topic='', qos='1', retain='false', broker=broker, x=600, y=100, wires=[])
]
for name, obj in [('flows.json', flow), ('flows_cred.json', {broker: credentials}),
                  ('package.json', {'name':'uwave-nodered', 'private':True})]:
    write(data / name, json.dumps(obj, indent=2), 0o600)
    os.chown(data / name, 1000, 1000)
os.chown(data, 1000, 1000)

def run(*args):
    subprocess.run(args, check=True)

run('systemctl', 'daemon-reload')
run('udevadm', 'control', '--reload-rules')
run('systemctl', 'start', 'mitutoyo-uwave-bind')
run('udevadm', 'trigger', '--subsystem-match=tty', '--action=add')
run('udevadm', 'settle', '--timeout=10')
run('systemctl', 'enable', '--now', 'mitutoyo-uwave-aggregator', 'docker')
run('docker', 'run', '--rm', '--user', '1000:1000', '-v', str(data)+':/data',
    '--entrypoint', 'npm', 'nodered/node-red:4.1.0', 'install', '--prefix', '/data',
    '--omit=dev', '--no-audit', '--no-fund', 'node-red-node-serialport')
run('docker', 'run', '-d', '--name', 'uwave-nodered', '--restart', 'unless-stopped',
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
    '--device-cgroup-rule', 'c 136:* rwm', '-p', '127.0.0.1:1880:1880',
    '-v', '/dev:/dev', '-v', '/dev/pts:/dev/pts', '-v', str(data)+':/data',
    '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3', 'nodered/node-red:4.1.0')
print('DEPLOYED: ' + socket.gethostname() + '; verify broker inventory and measurement')
