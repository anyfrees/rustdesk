"""Upload signed, immutable releases over SSH; replace the stable manifest last."""
import argparse
import base64
import getpass
import json
import os
from pathlib import Path
import shlex
import uuid

import paramiko
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--host', required=True)
parser.add_argument('--user', required=True)
parser.add_argument('--identity')
args = parser.parse_args()
envelope = json.loads((args.source / 'stable.json').read_text(encoding='utf-8'))
payload = base64.b64decode(envelope['payload'])
public = Path(__file__).resolve().parent.parent / 'update-public-key.txt'
Ed25519PublicKey.from_public_bytes(base64.b64decode(public.read_text().strip())).verify(base64.b64decode(envelope['signature']), payload)
manifest = json.loads(payload)
build = manifest['build']
if type(build) is not int or build <= 0:
    raise ValueError('Invalid build number')
release = args.source / 'releases' / str(build)
password = None if args.identity else os.environ.get('NNU_SSH_PASSWORD') or getpass.getpass('SSH password: ')
client = paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(args.host, username=args.user, password=password, key_filename=args.identity, timeout=20)
stage = '/tmp/nnu-release-' + uuid.uuid4().hex

def run(command):
    _, stdout, stderr = client.exec_command(command, timeout=180)
    output = stdout.read().decode(errors='replace')
    errors = stderr.read().decode(errors='replace')
    if stdout.channel.recv_exit_status():
        raise RuntimeError(errors or output)
    if output: print(output)

try:
    run(f'mkdir -m 700 {stage} {stage}/release')
    with client.open_sftp() as sftp:
        for file in sorted(release.iterdir()):
            if file.is_file():
                sftp.put(str(file), stage + '/release/' + file.name)
        sftp.put(str(args.source / 'stable.json'), stage + '/stable.json')
    checks = []
    for artifact in manifest['artifacts'].values():
        name = artifact['name']
        if Path(name).name != name or not all(c.isalnum() or c in '._-' for c in name):
            raise ValueError('Unsafe artifact filename')
        checks.append(artifact['sha256'] + '  ' + stage + '/release/' + name)
    run('sha256sum -c - <<\'SUMS\'\n' + '\n'.join(checks) + '\nSUMS')
    destination = f'/opt/nnu-rustdesk-updates/public/releases/{build}'
    run(f'sudo -n install -d -m 755 /opt/nnu-rustdesk-updates/public/releases && '
        f'test ! -e {destination} && '
        f'chmod 755 {stage}/release && chmod 644 {stage}/release/* && '
        f'sudo -n mv {stage}/release {destination} && '
        f'sudo -n install -m 644 {stage}/stable.json /opt/nnu-rustdesk-updates/public/stable.json.next && '
        'sudo -n mv -f /opt/nnu-rustdesk-updates/public/stable.json.next /opt/nnu-rustdesk-updates/public/stable.json')
    print(f'Published stable build {build}.')
finally:
    client.close()
