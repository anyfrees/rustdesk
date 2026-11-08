"""Prepare a signed release locally. Upload artifacts first and stable.json last over SSH."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil

from cryptography.hazmat.primitives import serialization


def prepare(source, destination, key_path, build, version, notes, artifact_version='1.5.0'):
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    target = destination / 'releases' / str(build)
    if target.exists():
        raise ValueError('This build already exists. Use a new immutable build number.')
    target.mkdir(parents=True)
    artifacts = {}
    files = {'portable': f'RustDesk-NNU-{artifact_version}-x64-Portable.exe',
             'install': f'RustDesk-NNU-{artifact_version}-x64-Install.exe',
             'msi': f'RustDesk-NNU-{artifact_version}-x64.msi',
             'zip': f'RustDesk-NNU-{artifact_version}-x64.zip'}
    for kind, pattern in files.items():
        path = source / pattern
        if not path.is_file():
            raise ValueError(f'Missing artifact: {path}')
        name = f'RustDesk-NNU-{build}-x64-{kind}{path.suffix}'
        shutil.copyfile(path, target / name)
        artifacts[kind] = {'name': name, 'size': path.stat().st_size,
                           'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                           'url': f'https://rd.nnu.cn/client-updates/releases/{build}/{name}'}
    for name in ('RustDesk-NNU-1.5.0-Source.zip', 'SHA256SUMS.txt', 'README.md', 'BUILD-INFO.json'):
        if (source / name).is_file():
            shutil.copyfile(source / name, target / name)
    manifest = {'schema': 1, 'channel': 'stable', 'build': build,
                'version': version, 'notes': notes, 'artifacts': artifacts}
    payload = json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode()
    envelope = {'payload': base64.b64encode(payload).decode(),
                'signature': base64.b64encode(key.sign(payload)).decode()}
    pending = destination / 'stable.json.tmp'
    pending.write_text(json.dumps(envelope, separators=(',', ':')) + '\n', encoding='utf-8')
    pending.replace(destination / 'stable.json')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--artifact-version', default='1.5.0')
    args = parser.parse_args()
    manifest = prepare(args.source, args.output, args.key, args.build, args.version,
                       args.notes.read_text(encoding='utf-8'), args.artifact_version)
    print(f"Signed stable release {manifest['version']} (build {manifest['build']}); {len(manifest['artifacts'])} packages")
