"""Export an existing signed release. This tool never loads a signing key."""
import argparse
import zipfile
from pathlib import Path
from release import verify_manifest, check_files


def bundle(source, destination):
    raw = (source / 'stable.json').read_bytes()
    manifest = verify_manifest(raw)
    directory = source / 'releases' / str(manifest['build'])
    check_files(directory, manifest)
    if destination.exists():
        raise ValueError('Output already exists')
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_STORED) as z:
        z.writestr('stable.json', raw)
        for a in manifest['artifacts'].values():
            z.write(directory / a['name'], f"releases/{manifest['build']}/{a['name']}")
    return manifest


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    result = bundle(args.source, args.output)
    print(f"Bundle ready: {result['version']} ({result['build']})")
