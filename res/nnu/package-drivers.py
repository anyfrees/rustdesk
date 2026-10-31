from pathlib import Path, PurePosixPath
import argparse
import hashlib
import re
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--tools', type=Path, required=True)
parser.add_argument('--dist', type=Path, required=True)
args = parser.parse_args()
sums = (args.tools / 'driver-sha256sums').read_text()
for name in ('rustdesk_printer_driver_v4-1.4.zip', 'printer_driver_adapter.zip'):
    match = re.search(r'^([a-fA-F0-9]{64}) \*?' + re.escape(name) + r'$', sums, re.M)
    if not match or hashlib.sha256((args.tools / name).read_bytes()).hexdigest() != match[1].lower():
        raise ValueError(f'Driver checksum failed: {name}')

for name in ('usbmmidd_v2.zip', 'rustdesk_printer_driver_v4-1.4.zip', 'printer_driver_adapter.zip'):
    with zipfile.ZipFile(args.tools / name) as archive:
        for entry in archive.infolist():
            relative = PurePosixPath(entry.filename)
            if entry.is_dir():
                continue
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe driver archive entry')
            if name == 'usbmmidd_v2.zip':
                if 'Win32' in relative.parts or relative.name in ('deviceinstaller.exe', 'deviceinstaller64.exe', 'usbmmidd.bat'):
                    continue
            elif name == 'rustdesk_printer_driver_v4-1.4.zip':
                relative = PurePosixPath('drivers', 'RustDeskPrinterDriver', *relative.parts[1:])
            target = args.dist.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(entry))
