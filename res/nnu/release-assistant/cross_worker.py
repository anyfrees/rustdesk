"""Local WSL build worker. Job JSON contains public paths/settings, never keys."""
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from linux_packages import download, package as linux_package, run

BASELINE = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
ANDROID = [('aarch64-linux-android', 'arm64-android', 'arm64-v8a', 'aarch64-linux-android'),
           ('armv7-linux-androideabi', 'arm-neon-android', 'armeabi-v7a', 'arm-linux-androideabi'),
           ('x86_64-linux-android', 'x64-android', 'x86_64', 'x86_64-linux-android')]


def valid_members(names):
    if any(PurePosixPath(n).is_absolute() or '..' in PurePosixPath(n).parts or '\\' in n for n in names):
        raise ValueError('Unsafe archive member')


def unpack_tar(archive, destination):
    with tarfile.open(archive) as content:
        valid_members(m.name for m in content.getmembers())
        for m in content.getmembers():
            if (m.issym() or m.islnk()) and (PurePosixPath(m.linkname).is_absolute() or
                    not (Path(destination) / m.name).parent.joinpath(m.linkname).resolve().is_relative_to(Path(destination).resolve())):
                raise ValueError('Unsafe archive link')
        content.extractall(destination)


def fetch(url, path, expected=None, algorithm='sha256'):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        part = path.with_suffix(path.suffix + '.part')
        with urllib.request.urlopen(url, timeout=120) as response, part.open('wb') as out:
            shutil.copyfileobj(response, out)
        part.replace(path)
    if expected and hashlib.new(algorithm, path.read_bytes()).hexdigest() != expected.lower():
        raise RuntimeError('Official checksum mismatch: ' + path.name)
    return path


class Worker:
    def __init__(self, job):
        self.job = job
        self.root = Path(job.get('root', '/build/nnu-multiplatform'))
        if not self.root.is_absolute() or not self.root.resolve().is_relative_to(Path('/build')) or self.root.resolve() == Path('/build'):
            raise ValueError('Build root must be an absolute private /build subdirectory')
        self.root.mkdir(parents=True, exist_ok=True)
        self.source = self.root / 'source'
        self.flutter = self.root / 'flutter'
        self.sdk = self.root / 'android-sdk'
        self.rust = Path('/opt/rust') if Path('/opt/rust/bin/rustc').exists() else self.root / 'rust'
        self.env = dict(os.environ, LANG='C.UTF-8', LC_ALL='C.UTF-8',
                        PATH=f'{self.rust}/bin:{self.flutter}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                        LIBCLANG_PATH='/usr/lib/llvm-14/lib', CARGO_BUILD_JOBS='6',
                        GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='safe.directory', GIT_CONFIG_VALUE_0=str(self.flutter))

    def execute(self, args, cwd=None, env=None, name='build'):
        logfile = self.root / (name + '.log')
        print('Local step: ' + name, flush=True)
        with logfile.open('w') as log:
            result = subprocess.run([str(x) for x in args], cwd=cwd or self.root,
                                    env=env or self.env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            with logfile.open('rb') as log:
                log.seek(max(0, logfile.stat().st_size - 5000))
                print(log.read().decode(errors='replace'), flush=True)
            raise RuntimeError(f'{name} failed; local log: {logfile}')

    def prepare(self):
        print('Preparing isolated local Linux/Android toolchains', flush=True)
        marker = self.root / 'apt-dependencies-v2'
        if not marker.exists():
            packages = '''build-essential clang libclang-dev libunwind-dev llvm cmake curl git g++
            libayatana-appindicator3-dev libasound2-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev
            libpulse-dev libva-dev libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxdo-dev
            libxfixes-dev nasm ninja-build openjdk-17-jdk-headless pkg-config rpm unzip zip xz-utils
            libssl-dev libdrm-dev libegl1-mesa-dev libgles2-mesa-dev meson patchelf libfuse2 procps
            libpipewire-0.3-dev libgbm-dev libinput-dev libudev-dev libpam0g-dev libxrandr-dev libxi-dev
            libxtst-dev libnotify-dev libkeybinder-3.0-dev xvfb xauth x11-utils fonts-noto-cjk libfuse3-dev
            autoconf automake libtool libtool-bin gettext gperf bison flex'''.split()
            self.execute(['apt-get', 'update'], name='apt-update')
            self.execute(['apt-get', 'install', '-y', '--no-install-recommends'] + packages,
                         env=dict(self.env, DEBIAN_FRONTEND='noninteractive'), name='apt-install')
            marker.touch()
        downloads = self.root / 'downloads'; downloads.mkdir(exist_ok=True)
        if not self.flutter.exists():
            with urllib.request.urlopen('https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json', timeout=60) as response:
                manifest = json.load(response)
            item = next(x for x in manifest['releases'] if x.get('version') == '3.24.5' and x.get('channel') == 'stable')
            archive = fetch(manifest['base_url'] + '/' + item['archive'], downloads / 'flutter.tar.xz', item['sha256'])
            unpack_tar(archive, self.root)
        if not (self.rust / 'bin/rustc').exists():
            name = 'rust-1.88.0-x86_64-unknown-linux-gnu.tar.xz'
            url = 'https://static.rust-lang.org/dist/' + name
            with urllib.request.urlopen(url + '.sha256', timeout=60) as response:
                digest = response.read().decode().split()[0]
            unpack_tar(fetch(url, downloads / name, digest), downloads)
            self.execute(['bash', downloads / name[:-7] / 'install.sh', '--prefix=' + str(self.rust), '--disable-ldconfig'], name='rust-install')
        version = subprocess.check_output([self.rust / 'bin/rustc', '--version'], env=self.env, text=True)
        if not version.startswith('rustc 1.88.0 '):
            raise RuntimeError('Cross-platform security profile requires Rust 1.88.0')
        if 'android' in self.job['targets']:
            tools = self.sdk / 'cmdline-tools/latest'
            if not tools.exists():
                with urllib.request.urlopen('https://dl.google.com/android/repository/repository2-3.xml', timeout=60) as response:
                    tree = ET.fromstring(response.read())
                package = next(p for p in tree.findall('remotePackage') if p.get('path') == 'cmdline-tools;latest')
                archive = next(a for a in package.findall('./archives/archive') if a.findtext('host-os') == 'linux')
                name = archive.findtext('complete/url')
                path = fetch('https://dl.google.com/android/repository/' + name, downloads / name,
                             archive.findtext('complete/checksum'), archive.find('complete/checksum').get('type', 'sha1'))
                with zipfile.ZipFile(path) as z:
                    valid_members(z.namelist()); z.extractall(self.sdk / 'unpacked')
                tools.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(self.sdk / 'unpacked/cmdline-tools'), tools)
                for file in (tools / 'bin').iterdir(): file.chmod(0o755)
            sdk_env = dict(self.env, JAVA_HOME='/usr/lib/jvm/java-17-openjdk-amd64')
            command = [str(tools / 'bin/sdkmanager'), '--sdk_root=' + str(self.sdk)]
            with (self.root / 'sdk-install.log').open('w') as log:
                for args in (['--licenses'], ['platform-tools', 'platforms;android-36', 'build-tools;36.0.0', 'ndk;28.2.13676358', 'cmake;3.22.1']):
                    subprocess.run(command + args, input='y\n' * 100, text=True, cwd=self.root,
                                   env=sdk_env, stdout=log, stderr=subprocess.STDOUT, check=True)
            for target, _, _, _ in ANDROID:
                if (self.rust / 'lib/rustlib' / target / 'lib').exists(): continue
                name = f'rust-std-1.88.0-{target}.tar.xz'; url = 'https://static.rust-lang.org/dist/' + name
                with urllib.request.urlopen(url + '.sha256', timeout=60) as response:
                    digest = response.read().decode().split()[0]
                unpack_tar(fetch(url, downloads / name, digest), downloads)
                self.execute(['bash', downloads / name[:-7] / 'install.sh', '--prefix=' + str(self.rust), '--disable-ldconfig'], name='rust-target-' + target)
            if not (self.rust / 'bin/cargo-ndk').exists():
                self.execute(['cargo', 'install', 'cargo-ndk', '--version', '3.1.2', '--locked', '--root', self.rust], name='cargo-ndk-install')
        self.execute(['flutter', 'config', '--no-analytics', '--enable-linux-desktop', '--android-sdk', self.sdk], name='flutter-config')
        self.execute(['flutter', 'precache'] + (['--linux'] if 'linux' in self.job['targets'] else []) +
                     (['--android'] if 'android' in self.job['targets'] else []), name='flutter-cache')
        vcpkg = self.root / 'vcpkg'
        if not vcpkg.exists():
            seed = Path(self.job.get('vcpkg_seed', ''))
            self.execute(['git', 'clone', '--no-checkout', str(seed) if (seed / '.git').is_dir() else
                          'https://github.com/microsoft/vcpkg.git', vcpkg], name='vcpkg-clone')
        self.execute(['git', 'checkout', BASELINE], cwd=vcpkg, name='vcpkg-baseline')
        if not (vcpkg / 'vcpkg').exists():
            self.execute(['bash', vcpkg / 'bootstrap-vcpkg.sh', '-disableMetrics'], name='vcpkg-bootstrap')

    def export_source(self):
        self.source.mkdir(exist_ok=True)
        previous = self.root / 'source-files.json'
        with zipfile.ZipFile(self.job['source_zip']) as z:
            names = z.namelist(); valid_members(names)
            for name in json.loads(previous.read_text()) if previous.exists() else []:
                if name not in names:
                    path = self.source / name
                    if path.is_file(): path.unlink()
            for item in z.infolist():
                path = self.source / item.filename
                if item.is_dir(): path.mkdir(parents=True, exist_ok=True); continue
                path.parent.mkdir(parents=True, exist_ok=True)
                data = z.read(item)
                if path.suffix in {'.patch', '.diff', '.sh', '.cmake', '.toml', '.rs', '.py', '.gradle', '.dart', '.yaml', '.yml', '.json', '.xml', '.txt', '.h', '.c', '.cpp'}:
                    data = data.replace(b'\r\n', b'\n')
                if not path.exists() or path.read_bytes() != data: path.write_bytes(data)
            previous.write_text(json.dumps(names))
        for script in (self.source / 'res/DEBIAN').iterdir():
            if script.name != 'control': script.chmod(0o755)
        vendor = self.source / 'libs/nnu-libsodium-sys'
        shutil.copytree(Path(__file__).parent / 'sodium-sys', vendor, dirs_exist_ok=True)
        if not (vendor / 'libsodium/configure').exists():
            archive = fetch('https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz',
                            self.root / 'downloads/libsodium-1.0.22.tar.gz',
                            'adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349')
            unpack_tar(archive, self.root / 'downloads')
            shutil.copytree(self.root / 'downloads/libsodium-1.0.22', vendor / 'libsodium', dirs_exist_ok=True)
        manifest = self.source / 'Cargo.toml'; text = manifest.read_text()
        if 'libs/nnu-libsodium-sys' not in text:
            manifest.write_text(text.replace('[patch.crates-io]', '[patch.crates-io]\nlibsodium-sys = { path = "libs/nnu-libsodium-sys" }'))
        for package, version in [('openssl', '0.10.81'), ('tokio', '1.54.1'), ('rustls', '0.23.46')]:
            self.execute(['cargo', 'update', '-p', package, '--precise', version], cwd=self.source, name='update-' + package)
        lock = (self.source / 'Cargo.lock').read_text()
        for version in re.findall(r'name = "time"\s+version = "([0-9.]+)"', lock):
            current = tuple(map(int, version.split('.')))
            if (0, 3, 0) <= current < (0, 3, 47):
                self.execute(['cargo', 'update', '-p', 'time@' + version, '--precise', '0.3.47'],
                             cwd=self.source, name='update-time')
        pubspec = self.source / 'flutter/pubspec.yaml'
        assets = pubspec.read_text().replace('family: GestureIcons', 'family: gestureicons')
        if not re.search(r'^  cupertino_icons:', assets, re.M):
            assets = assets.replace('dependencies:\n', 'dependencies:\n  cupertino_icons: 1.0.8\n', 1)
        pubspec.write_text(assets)
        self.execute(['flutter', 'pub', 'get'], cwd=self.source / 'flutter', name='flutter-pub')

    def native_deps(self, triplet, profile):
        (self.root / 'binary-cache').mkdir(exist_ok=True)
        installed = self.root / ('installed-linux' if triplet == 'x64-linux' else 'installed-' + triplet)
        prefix = self.root / 'native' / profile; prefix.mkdir(parents=True, exist_ok=True)
        (prefix / '.vcpkg-root').touch()
        if not (prefix / 'installed').is_symlink(): (prefix / 'installed').symlink_to(installed, target_is_directory=True)
        ndk = self.sdk / 'ndk/28.2.13676358'
        env = dict(self.env, VCPKG_ROOT=str(self.root / 'vcpkg'), VCPKG_MAX_CONCURRENCY='6',
                   VCPKG_BINARY_SOURCES='clear;files,' + str(self.root / 'binary-cache') + ',readwrite',
                   ANDROID_NDK_HOME=str(ndk), ANDROID_NDK_ROOT=str(ndk))
        seed = self.job.get('vcpkg_downloads')
        if seed and Path(seed).is_dir(): env['VCPKG_DOWNLOADS'] = seed
        self.execute([self.root / 'vcpkg/vcpkg', 'install', '--triplet', triplet, '--x-install-root=' + str(installed),
                      '--disable-metrics'], cwd=self.source, env=env, name='vcpkg-' + triplet)
        if triplet == 'arm-neon-android' and not (installed / 'arm-android').exists():
            (installed / 'arm-android').symlink_to('arm-neon-android', target_is_directory=True)
        return dict(self.env, VCPKG_ROOT=str(prefix))

    def build(self):
        self.prepare(); self.export_source()
        output = Path(self.job['output']); build = int(self.job['build']); version = self.job['version']
        if 'linux' in self.job['targets']:
            from linux_compat import build as build_linux
            build_linux(self.source, self.root, output / 'Linux', build, version, self.flutter, self.rust,
                        self.root / 'vcpkg', self.job.get('vcpkg_downloads') or self.root / 'vcpkg/downloads')
        if 'android' in self.job['targets']:
            ndk = self.sdk / 'ndk/28.2.13676358'
            for target, triplet, abi, sysroot in ANDROID:
                env = self.native_deps(triplet, triplet)
                env.update(ANDROID_NDK_HOME=str(ndk), ANDROID_NDK_ROOT=str(ndk), CARGO_TARGET_DIR=str(self.root / 'target-android'),
                           RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384')
                env['PATH'] = str(ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin') + ':' + env['PATH']
                self.execute(['cargo', 'ndk', '--platform', '22', '--target', target, 'build', '--locked', '--release',
                              '--features', 'flutter,hwcodec', '--lib'], cwd=self.source, env=env, name='cargo-' + abi)
                destination = self.source / 'flutter/android/app/src/main/jniLibs' / abi
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(self.root / 'target-android' / target / 'release/liblibrustdesk.so', destination / 'librustdesk.so')
                shutil.copy2(ndk / 'toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib' / sysroot / 'libc++_shared.so', destination / 'libc++_shared.so')
            from android_packages import package
            package(self.source, self.root, output / 'Android', build, version, self.env)
        # Exact matching source includes the resolved cross-platform lock and public native wrapper.
        with zipfile.ZipFile(output.parent / 'RustDesk-NNU-CrossPlatform-Source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
            written = set()
            for name in json.loads((self.root / 'source-files.json').read_text()):
                path = self.source / name
                if path.is_file(): archive.write(path, name); written.add(name)
            for path in (self.source / 'libs/nnu-libsodium-sys').rglob('*'):
                name = path.relative_to(self.source).as_posix()
                if path.is_file() and name not in written: archive.write(path, name)
        print('Selected local platform builds completed', flush=True)


if __name__ == '__main__':
    job = json.loads(Path(sys.argv[1]).read_text())
    worker = Worker(job)
    with (worker.root / 'worker.lock').open('w') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise SystemExit('Another local platform build is already running')
        worker.build()
