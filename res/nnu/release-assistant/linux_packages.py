"""Run in the local Linux build environment, never on the live remote desktop."""
import hashlib
import json
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


RUNTIME_LIBRARIES = (
    ('libxdo.so.3', 'libxdo3'),
    ('libayatana-appindicator3.so.1', 'libayatana-appindicator3-1'),
    ('libayatana-indicator3.so.7', 'libayatana-indicator3-7'),
    ('libayatana-ido3-0.4.so.0', 'libayatana-ido3-0.4-0'),
    ('libdbusmenu-gtk3.so.4', 'libdbusmenu-gtk3-4'),
    ('libdbusmenu-glib.so.4', 'libdbusmenu-glib4'),
)


def bundle_runtime(bundle):
    licenses = bundle / 'licenses'
    licenses.mkdir(exist_ok=True)
    versions = []
    for name, package in RUNTIME_LIBRARIES:
        library = Path('/usr/lib/x86_64-linux-gnu') / name
        copyright = Path('/usr/share/doc') / package / 'copyright'
        if not library.is_file() or not copyright.is_file():
            raise RuntimeError('Missing Linux runtime library or license: ' + package)
        target = bundle / 'lib' / name
        shutil.copy2(library, target)
        run(['patchelf', '--set-rpath', '$ORIGIN', target])
        shutil.copy2(copyright, licenses / (package + '-copyright'))
        source = subprocess.check_output(['dpkg-query', '-W', '-f=${source:Package} ${source:Version}', package], text=True).strip()
        versions.append(dict(library=name, source=source, modification='RUNPATH=$ORIGIN'))
    for name in ('LGPL-2.1', 'LGPL-3', 'GPL-3'):
        shutil.copy2(Path('/usr/share/common-licenses') / name, licenses / name)
    (licenses / 'linux-runtime.json').write_text(json.dumps(versions, indent=2))
    # These libraries are loaded with dlopen, so ELF dependency collectors miss them.
    run(['patchelf', '--set-rpath', '$ORIGIN', bundle / 'lib/librustdesk.so'])


def package(source, root, output, build, version, minimum_glibc='2.35', minimum_libstdcpp='11'):
    source, root, output = Path(source), Path(root), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    bundle = source / 'flutter/build/linux/x64/release/bundle'
    for required in ('rustdesk', 'lib/librustdesk.so', 'lib/libflutter_linux_gtk.so', 'data/flutter_assets/AssetManifest.bin'):
        if not (bundle / required).is_file():
            raise RuntimeError('Linux bundle incomplete: ' + required)
    bundle_runtime(bundle)
    shutil.copy2(source / 'res/nnu/linux_desktop_shortcut.py', bundle / 'nnu_desktop_shortcut.py')
    shutil.copy2(source / 'res/128x128@2x.png', bundle / 'rustdesk.png')
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
    run(['cp', '-a', str(bundle) + '/.', staging / 'usr/share/rustdesk'])
    control = staging / 'DEBIAN/control'
    metadata = re.sub(r'^Version: .+$', f'Version: {native}+nnu.{build}', control.read_text(), flags=re.M)
    metadata = re.sub(r'^Maintainer: .+$', 'Maintainer: NNU <admin@nnu.cn>', metadata, flags=re.M)
    metadata = re.sub(r'^Homepage: .+$', 'Homepage: https://rd.nnu.cn/', metadata, flags=re.M)
    metadata = re.sub(r'^Depends: ', f'Depends: python3, libc6 (>= {minimum_glibc}), libstdc++6 (>= {minimum_libstdcpp}), ', metadata, flags=re.M)
    metadata = re.sub(r'^Depends: (.*)$', lambda m: 'Depends: ' + ', '.join(
        item.strip() for item in m[1].split(',') if not re.match(r'^\s*(libxdo3|gstreamer1[.]0-pipewire)(?:\s|$)', item)), metadata, flags=re.M)
    metadata = re.sub(r'^Recommends: .+$', 'Recommends: gstreamer1.0-pipewire', metadata, flags=re.M)
    control.write_text(metadata)
    for name in ('preinst', 'postinst', 'prerm', 'postrm'):
        script = staging / 'DEBIAN' / name
        if script.is_file():
            script.write_bytes(script.read_bytes().replace(b'\r\n', b'\n'))
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
    private_abi = '^(' + '|'.join(path.name.replace('.', '[.]') for path in sorted((bundle / 'lib').glob('*.so*'))) + ').*$'
    spec.write_text(f'''%global __provides_exclude {private_abi}
%global __requires_exclude {private_abi}
Name: rustdesk-nnu
Version: {native}
Release: {build}
Summary: RustDesk NNU remote desktop
License: AGPL-3.0
URL: https://rd.nnu.cn/
BuildArch: x86_64
Requires: python3, libgtk-3.so.0()(64bit), libXss.so.1()(64bit), libXrandr.so.2()(64bit), libasound.so.2()(64bit), libpulse.so.0()(64bit)
Conflicts: rustdesk
Provides: rustdesk = {native}
%description
{version}. Locally compiled Flutter client with NNU server defaults.
%install
mkdir -p %{{buildroot}}
cp -a {staging}/usr %{{buildroot}}/
%post
/usr/bin/python3 /usr/share/rustdesk/nnu_desktop_shortcut.py --all-users || true
if [ -d /run/systemd/system ]; then
 cp /usr/share/rustdesk/files/systemd/rustdesk.service /usr/lib/systemd/system/rustdesk.service
 systemctl daemon-reload
 systemctl enable rustdesk.service
 systemctl start rustdesk.service
fi
%preun
if [ "$1" -eq 0 ]; then
 /usr/bin/python3 /usr/share/rustdesk/nnu_desktop_shortcut.py --all-users --remove-installed || true
fi
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
    run(['cp', '-a', str(bundle) + '/.', appdir / 'usr/bin'])
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
    for library in sorted((appdir / 'usr/bin/lib').glob('*.so*')):
        arguments.extend(['--library', library])
    run(arguments + ['--output', 'appimage'], cwd=root, env=env)
    print('Linux DEB, RPM, AppImage and tar.gz packaged', flush=True)
