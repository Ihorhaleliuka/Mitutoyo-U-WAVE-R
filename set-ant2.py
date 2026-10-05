"""Select CM4 external antenna while preserving boot configuration and a backup."""
from pathlib import Path
import shutil
import time

path = Path('/boot/firmware/config.txt')
lines = path.read_text().splitlines(keepends=True)
indices = [i for i, line in enumerate(lines) if line.strip() == '[all]']
assert indices, 'No [all] section found'
index = indices[-1]
assert not any(line.strip().startswith('[') for line in lines[index+1:]), 'Final section is not [all]'
active = [line.strip() for line in lines[index+1:] if not line.lstrip().startswith('#')]
if 'dtparam=ant2' not in active:
    backup = path.with_name('config.txt.uwave-' + time.strftime('%Y%m%d-%H%M%S') + '.bak')
    shutil.copy2(path, backup)
    lines.insert(index+1, 'dtparam=ant2\n')
    path.write_text(''.join(lines))
    print('BACKUP=' + str(backup))
print('ant2 configured under final [all]; reboot required')
