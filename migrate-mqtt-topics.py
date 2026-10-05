"""Change only U-WAVE topic routing, with backup and rollback."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROUTING = '''// U-WAVE receiver device ID routing v1
const uwaveId = String(data.receiverDeviceId || '');
const uwaveType = String(data.type || 'raw');
const uwaveUsb = String(data.receiverUsbSerial || data.receiver || 'unknown');
if (!/^[A-Za-z0-9_-]+$/.test(uwaveType) || !/^[A-Za-z0-9_-]+$/.test(uwaveUsb)) return null;
msg.topic = /^\\d{10}$/.test(uwaveId) && uwaveId !== '0000000000'
    ? `mitutoyo/uwave/${uwaveId}/${uwaveType}`
    : `mitutoyo/uwave/unidentified/${uwaveUsb}/${uwaveType}`;
'''

parser = argparse.ArgumentParser()
parser.add_argument('--container', required=True)
parser.add_argument('--function-id', required=True)
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()
meta = json.loads(subprocess.check_output(['docker', 'inspect', args.container]))[0]
mount = next(m for m in meta['Mounts'] if m['Destination'] == '/data')
path = Path(mount['Source']) / 'flows.json'

def updated():
    flow = json.loads(path.read_text())
    node = next(n for n in flow if n['id'] == args.function_id)
    assert node['type'] == 'function' and 'mitutoyo/uwave/' in node['func']
    assert node['func'].count('return msg;') == 1
    if '// U-WAVE receiver device ID routing v1' in node['func']:
        return None
    node['func'] = node['func'].replace('return msg;', ROUTING + '\nreturn msg;')
    return flow

flow = updated()
if flow is None:
    print('ALREADY_MIGRATED')
elif args.dry_run:
    print('READY: ' + str(path) + '; function=' + args.function_id)
else:
    subprocess.run(['docker', 'stop', args.container], check=True)
    backup = path.with_name('flows.json.device-id-' + time.strftime('%Y%m%d-%H%M%S') + '.bak')
    temp = path.with_name('flows.json.device-id.new')
    try:
        flow = updated()
        assert flow is not None
        original = path.read_bytes()
        stat = path.stat()
        backup.write_bytes(original)
        backup.chmod(0o600)
        os.chown(backup, stat.st_uid, stat.st_gid)
        temp.write_text(json.dumps(flow, indent=2))
        temp.chmod(stat.st_mode & 0o777)
        os.chown(temp, stat.st_uid, stat.st_gid)
        temp.replace(path)
        subprocess.run(['docker', 'start', args.container], check=True)
    except Exception:
        if backup.exists():
            path.write_bytes(backup.read_bytes())
        subprocess.run(['docker', 'start', args.container])
        raise
    print('BACKUP=' + str(backup))
    print('MIGRATED: mitutoyo/uwave/<receiverDeviceId>/<type>')
