"""Build metadata and packaging for the manual GitHub Apple workflow."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=ROOT):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)


def metadata():
    data = json.loads((ROOT / 'flutter/assets/nnu-release.json').read_text())
    native = re.search(r'^version\s*=\s*"([^"]+)"', (ROOT / 'Cargo.toml').read_text(), re.M)[1]
    if not data['version'].startswith(native + ' '):
        raise ValueError('Native and NNU versions differ')
    return data, native


def configure():
    key = (ROOT / 'res/nnu/official-support-public-keys.txt').read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('Invalid official support public key')
    with open(os.environ['GITHUB_ENV'], 'a') as env:
        env.write('NNU_OFFICIAL_SUPPORT_PUBLIC_KEYS=' + key + '\n')
        env.write('NNU_APPLE_PLATFORM=' + os.environ['APPLE_PLATFORM'] + '\n')
        env.write('NNU_APPLE_ARCH=' + os.environ['APPLE_ARCH'] + '\n')
    if os.environ['APPLE_PLATFORM'] == 'ios':
        path = ROOT / 'flutter/ios/Runner.xcodeproj/project.pbxproj'
        text = path.read_text().replace('com.carriez.flutterHbb', 'cn.nnu.rustdesk')
        text = re.sub(r'DEVELOPMENT_TEAM = [^;]+;', 'DEVELOPMENT_TEAM = "";', text)
        path.write_text(text)
        path = ROOT / 'flutter/ios/Runner/Info.plist'
        data = plistlib.loads(path.read_bytes())
        data['CFBundleDisplayName'] = 'RustDesk VIP支持专业版'
        path.write_bytes(plistlib.dumps(data))
    elif os.environ['APPLE_ARCH'] == 'arm64':
        replacements = [
            ('build.py', 'MACOSX_DEPLOYMENT_TARGET=10.14', 'MACOSX_DEPLOYMENT_TARGET=12.3'),
            ('flutter/macos/Podfile', "platform :osx, '10.14'", "platform :osx, '12.3'"),
            ('Cargo.toml', 'osx_minimum_system_version = "10.14"', 'osx_minimum_system_version = "12.3"'),
        ]
        for relative, before, after in replacements:
            path = ROOT / relative
            path.write_text(path.read_text().replace(before, after))
        path = ROOT / 'flutter/macos/Runner.xcodeproj/project.pbxproj'
        path.write_text(re.sub(r'MACOSX_DEPLOYMENT_TARGET = [\d.]+;', 'MACOSX_DEPLOYMENT_TARGET = 12.3;', path.read_text()))


def package(platform):
    data, native = metadata()
    arch = os.environ['NNU_APPLE_ARCH']
    label = data['version'].replace(' ', '-')
    out = ROOT / 'dist/apple'
    out.mkdir(parents=True, exist_ok=True)
    stem = f'RustDesk-NNU-{label}-{platform}-{arch}'
    public = (ROOT / 'res/nnu/official-support-public-keys.txt').read_bytes().strip()
    if platform == 'ios':
        app = ROOT / 'flutter/build/ios/iphoneos/Runner.app'
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != 'cn.nnu.rustdesk' or info['CFBundleShortVersionString'] != native:
            raise ValueError('Unexpected iOS bundle identity/version')
        executable = app / info['CFBundleExecutable']
        if public not in executable.read_bytes():
            raise ValueError('Official support root missing from iOS binary')
        payload = out / 'Payload'
        payload.mkdir()
        run('ditto', app, payload / app.name)
        run('ditto', '-c', '-k', '--keepParent', 'Payload', stem + '-unsigned.ipa', cwd=out)
        signature = 'unsigned; requires signing before installation'
    else:
        app = ROOT / 'flutter/build/macos/Build/Products/Release/RustDesk.app'
        dylibs = list(app.rglob('*rustdesk*.dylib'))
        if not any(public in p.read_bytes() for p in dylibs):
            raise ValueError('Official support root missing from macOS binary')
        run('codesign', '--force', '--deep', '--sign', '-', '--entitlements', ROOT / 'flutter/macos/Runner/Release.entitlements', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, out / (stem + '.app.zip'))
        layout = out / 'dmg-layout'
        layout.mkdir()
        run('ditto', app, layout / app.name)
        (layout / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', 'RustDesk NNU', '-srcfolder', layout, '-format', 'UDZO', out / (stem + '.dmg'))
        signature = 'ad-hoc; not Developer ID signed or notarized'
    artifacts = []
    for path in sorted(out.iterdir()):
        if path.suffix not in ('.dmg', '.ipa', '.zip'):
            continue
        artifacts.append(dict(name=path.name, size=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    proof = dict(schema='nnu.apple.build.v1', **data, native_version=native, platform=platform, arch=arch,
                 source_commit=os.environ['GITHUB_SHA'], signing=signature, artifacts=artifacts)
    (out / 'BUILD-INFO.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2))
    (out / 'SHA256SUMS.txt').write_text(''.join(f"{a['sha256']}  {a['name']}\n" for a in artifacts))
    (out / 'README.txt').write_text(data['version'] + '\n' + signature + '\nSource: ' + os.environ['GITHUB_SHA'] + '\n')
    print(json.dumps(proof, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'matrix':
        metadata()
        for name in ['src/bridge_generated.rs', 'src/bridge_generated.io.rs', 'flutter/lib/generated_bridge.dart', 'flutter/lib/generated_bridge.freezed.dart', 'flutter/macos/Runner/bridge_generated.h', 'flutter/ios/Runner/bridge_generated.h']:
            if not (ROOT / name).is_file():
                raise ValueError('Generated bridge missing: ' + name)
        rows = [
            dict(platform='macos', arch='x86_64', os='macos-15-intel', target='x86_64-apple-darwin', triplet='x64-osx', host_triplet='x64-osx', flutter='3.24.5', macos_minimum='10.14', extra_args=''),
            dict(platform='macos', arch='arm64', os='macos-15', target='aarch64-apple-darwin', triplet='arm64-osx', host_triplet='arm64-osx', flutter='3.44.9', macos_minimum='12.3', extra_args='--screencapturekit'),
            dict(platform='ios', arch='arm64', os='macos-15', target='aarch64-apple-ios', triplet='arm64-ios', host_triplet='arm64-osx', flutter='3.24.5', macos_minimum='12.3', extra_args=''),
        ]
        choice = os.environ.get('REQUESTED_PLATFORM', 'all')
        if choice not in ('all', 'macos', 'macos-arm64', 'macos-x86_64', 'ios'):
            raise ValueError('Unsupported platform')
        value = json.dumps(dict(include=[r for r in rows if choice == 'all' or r['platform'] == choice or r['platform'] + '-' + r['arch'] == choice]))
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('value=' + value + '\n')
    elif command == 'configure':
        configure()
    elif command == 'package-macos':
        package('macos')
    elif command == 'package-ios':
        package('ios')
    else:
        raise ValueError('Unknown command')
