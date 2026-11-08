"""Run in the local Linux build environment, never on the live remote desktop."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def native_version(source):
    match = re.search(r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', (Path(source) / 'Cargo.toml').read_text(), re.M)
    if not match: raise ValueError('Native application version is missing')
    return match[1]


def download(url, path, expected):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        part = path.with_suffix(path.suffix + '.part')
        with urllib.request.urlopen(url, timeout=90) as response, part.open('wb') as output:
            shutil.copyfileobj(response, output)
        part.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError('Download checksum mismatch: ' + path.name)
    path.chmod(0o755)
    return path


def package(source, root, output, build, version):
    source, root, output = Path(source), Path(root), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    bundle = source / 'flutter/build/linux/x64/release/bundle'
    for required in ('rustdesk', 'lib/librustdesk.so', 'lib/libflutter_linux_gtk.so', 'data/flutter_assets/AssetManifest.bin'):
        if not (bundle / required).is_file():
            raise RuntimeError('Linux bundle incomplete: ' + required)
    native = native_version(source)
    deb = source / f'rustdesk-{native}.deb'
    if not deb.exists():
        raise RuntimeError('DEB build did not produce its installer')
    prefix = f'RustDesk-NNU-{build}-linux-x86_64'
    with tarfile.open(output / (prefix + '.tar.gz'), 'w:gz') as archive:
        archive.add(bundle, arcname='RustDesk-NNU')
    staging = root / 'linux-rpm-stage'
    if staging.exists():
        if staging.resolve().parent != root.resolve(): raise RuntimeError('Unsafe packaging staging directory')
        shutil.rmtree(staging)
    staging.mkdir(exist_ok=True)
    run(['dpkg-deb', '--raw-extract', deb, staging])
    control = staging / 'DEBIAN/control'
    metadata = re.sub(r'^Version: .+$', f'Version: {native}+nnu.{build}', control.read_text(), flags=re.M)
    metadata = re.sub(r'^Maintainer: .+$', 'Maintainer: NNU <admin@nnu.cn>', metadata, flags=re.M)
    metadata = re.sub(r'^Homepage: .+$', 'Homepage: https://rd.nnu.cn/', metadata, flags=re.M)
    metadata = re.sub(r'^Depends: ', 'Depends: libc6 (>= 2.35), libstdc++6 (>= 11), ', metadata, flags=re.M)
    control.write_text(metadata)
    launcher = staging / 'usr/bin/rustdesk'
    if launcher.is_symlink() and os.readlink(launcher) == '/usr/share/rustdesk/rustdesk':
        launcher.unlink()
    if not launcher.exists() and not launcher.is_symlink():
        launcher.symlink_to('../share/rustdesk/rustdesk')
    for entry in (staging / 'usr/share/applications').glob('*.desktop'):
        lines = entry.read_text().splitlines()
        entry.write_text('\n'.join('MimeType=' + ';'.join(x.strip() for x in line[9:].split(';') if x.strip()) + ';'
                                    if line.startswith('MimeType=') else 'Name=RustDesk VIP支持专业版' if line in ('Name=RustDesk', 'Name=RustDesk NNU') else line for line in lines) + '\n')
    run(['dpkg-deb', '--root-owner-group', '-b', staging, output / (prefix + '.deb')])
    rpmroot = root / 'rpmbuild'
    for directory in ('BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS'):
        (rpmroot / directory).mkdir(parents=True, exist_ok=True)
    spec = rpmroot / 'SPECS/nnu.spec'
    # Use the Flutter bundle from the DEB, including its plugins, assets and native core.
    spec.write_text(f'''Name: rustdesk-nnu
Version: {native}
Release: {build}
Summary: RustDesk NNU remote desktop
License: AGPL-3.0
URL: https://rd.nnu.cn/
BuildArch: x86_64
Requires: gtk3, libXdo, libXScrnSaver, libXtst, libXfixes, libXrandr, alsa-lib, pulseaudio-libs
Conflicts: rustdesk
Provides: rustdesk = {native}
%description
{version}. Locally compiled Flutter client with NNU server defaults.
%install
mkdir -p %{{buildroot}}
cp -a {staging}/usr %{{buildroot}}/
%post
if [ -d /run/systemd/system ]; then
 cp /usr/share/rustdesk/files/systemd/rustdesk.service /usr/lib/systemd/system/rustdesk.service
 systemctl daemon-reload
 systemctl enable rustdesk.service
 systemctl start rustdesk.service
fi
%preun
if [ "$1" -eq 0 ] && [ -d /run/systemd/system ]; then
 systemctl disable --now rustdesk.service
 rm -f /usr/lib/systemd/system/rustdesk.service
 systemctl daemon-reload
fi
%files
/usr/bin/rustdesk
/usr/share/rustdesk
/usr/share/applications/*
/usr/share/icons/hicolor/256x256/apps/rustdesk.png
/usr/share/icons/hicolor/scalable/apps/rustdesk.svg
''')
    run(['rpmbuild', '--define', '_topdir ' + str(rpmroot), '--define', '_build_id_links none', '-bb', spec])
    rpm = rpmroot / f'RPMS/x86_64/rustdesk-nnu-{native}-{build}.x86_64.rpm'
    shutil.copy2(rpm, output / (prefix + '.rpm'))
    appdir = root / 'RustDesk-NNU.AppDir'
    if appdir.exists():
        if appdir.resolve().parent != root.resolve(): raise RuntimeError('Unsafe AppImage staging directory')
        shutil.rmtree(appdir)
    (appdir / 'usr/bin').mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, appdir / 'usr/bin', dirs_exist_ok=True)
    desktop = appdir / 'rustdesk.desktop'
    desktop.write_text((source / 'res/rustdesk.desktop').read_text().replace('Name=RustDesk\n', 'Name=RustDesk VIP支持专业版\n'))
    shutil.copy2(source / 'res/128x128@2x.png', appdir / 'rustdesk.png')
    # linuxdeploy supplies its AppRun and collects the required shared libraries.
    tool = download('https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage',
                    root / 'downloads/linuxdeploy-x86_64.AppImage',
                    'c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d')
    env = dict(os.environ, ARCH='x86_64', OUTPUT=str(output / (prefix + '.AppImage')), APPIMAGE_EXTRACT_AND_RUN='1')
    arguments = [tool, '--appdir', appdir, '--executable', appdir / 'usr/bin/rustdesk', '--desktop-file', desktop,
                 '--icon-file', appdir / 'rustdesk.png']
    for library in sorted((appdir / 'usr/bin/lib').glob('*.so')):
        arguments.extend(['--library', library])
    run(arguments + ['--output', 'appimage'], cwd=root, env=env)
    print('Linux DEB, RPM, AppImage and tar.gz packaged', flush=True)
