"""Build the Linux desktop client against the older x86_64 desktop ABI."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


PACKAGES = '''build-essential clang-11 libclang-11-dev llvm-11 libunwind-dev cmake curl git g++
libayatana-appindicator3-dev libasound2-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev
libpulse-dev libva-dev libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxdo-dev
libxfixes-dev nasm ninja-build pkg-config rpm unzip zip xz-utils libssl-dev libdrm-dev
libegl1-mesa-dev libgles2-mesa-dev meson patchelf libfuse2 procps libgbm-dev libinput-dev
libudev-dev libpam0g-dev libxrandr-dev libxi-dev libxtst-dev libnotify-dev libkeybinder-3.0-dev
xvfb xauth x11-utils fonts-noto-cjk libfuse3-dev autoconf automake libtool libtool-bin
gettext gperf bison flex python3 file libxkbcommon-dev libxkbcommon-x11-dev'''.split()


def execute(args, log, cwd=None, env=None):
    print('Compatibility step: ' + log.name, flush=True)
    with log.open('w') as output:
        result = subprocess.run([str(x) for x in args], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text(errors='replace')[-5000:], flush=True)
        raise RuntimeError('Linux compatibility build failed: ' + str(log))


def copy_changed(source, target):
    if not target.is_file() or source.read_bytes() != target.read_bytes():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def build(source, workspace, output, build_number, version, flutter, rust, vcpkg, downloads):
    workspace = Path(workspace)
    base = workspace.parent / 'nnu-linux-compat'
    if base.resolve().parent != Path('/build'):
        raise ValueError('Compatibility environment must stay in the private build directory')
    base.mkdir(exist_ok=True)
    with (base / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root = base / 'root'
        if not (root / 'etc/debian_version').exists():
            if shutil.which('debootstrap') is None:
                execute(['apt-get', 'update'], base / 'host-apt-update.log')
                execute(['apt-get', 'install', '-y', '--no-install-recommends', 'debootstrap'], base / 'debootstrap-tool.log')
            execute(['debootstrap', '--variant=minbase', '--include=ca-certificates', '--arch=amd64', 'buster', root,
                     'https://archive.debian.org/debian'], base / 'bootstrap.log')
        shutil.copy2('/etc/ssl/certs/ca-certificates.crt', root / 'etc/ssl/certs/ca-certificates.crt')
        shutil.copy2('/etc/resolv.conf', root / 'etc/resolv.conf')
        (root / 'etc/apt/sources.list').write_text('deb https://archive.debian.org/debian buster main\n'
                                                 'deb-src https://archive.debian.org/debian buster main\n')
        (root / 'etc/apt/apt.conf.d/99-nnu-archive').write_text('Acquire::Check-Valid-Until "false";\n')
        policy = root / 'usr/sbin/policy-rc.d'
        policy.write_text('#!/bin/sh\nexit 101\n'); policy.chmod(0o755)
        work = root / 'build/nnu-multiplatform'
        work.mkdir(parents=True, exist_ok=True)
        if not (work / 'vcpkg').exists():
            execute(['git', 'clone', '--shared', '--dissociate', vcpkg, work / 'vcpkg'], base / 'vcpkg-seed.log')
        names = json.loads((workspace / 'source-files.json').read_text())
        for name in names:
            path = Path(source) / name
            if path.is_file(): copy_changed(path, work / 'source' / name)
        for path in (Path(source) / 'libs/nnu-libsodium-sys').rglob('*'):
            if path.is_file(): copy_changed(path, work / 'source' / path.relative_to(source))
        helper = root / 'build/helpers'
        helper.mkdir(exist_ok=True)
        (root / 'tools').mkdir(exist_ok=True)
        shutil.copy2('/etc/ssl/certs/ca-certificates.crt', root / 'tools/ca-certificates.crt')
        for name in ('linux_compat.py', 'linux_packages.py'):
            shutil.copy2(Path(__file__).parent / name, helper / name)
        public_keys = os.environ.get('NNU_OFFICIAL_SUPPORT_PUBLIC_KEYS', '').strip()
        job = dict(build=build_number, version=version, flutter=str(flutter), rust=str(rust),
                   vcpkg=str(vcpkg), downloads=str(downloads), base=str(base), public_keys=public_keys)
        config = base / 'job.json'; config.write_text(json.dumps(job))
        shutil.copy2(config, helper / 'job.json')
        execute(['unshare', '--mount', '--propagation', 'private', sys.executable, __file__, '--namespace', config],
                base / 'build.log')
        shutil.copytree(work / 'output', output, dirs_exist_ok=True)
        for name in ('src/version.rs', 'Cargo.lock'):
            copy_changed(work / 'source' / name, Path(source) / name)
        shutil.copy2(work / 'linux-abi-verification.json', Path(output).parent / 'linux-abi-verification.json')


def namespace(job):
    root = Path(job['base']) / 'root'
    for source, target in [(job['flutter'], '/tools/flutter'), (job['rust'], '/opt/rust'),
                           (job['vcpkg'], '/tools/vcpkg-seed'), (job['downloads'], '/tools/downloads'),
                           ('/root/.cargo/registry', '/root/.cargo/registry'), ('/root/.cargo/git', '/root/.cargo/git'),
                           ('/root/.pub-cache', '/root/.pub-cache')]:
        destination = root / target.lstrip('/')
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(['mount', '--bind', source, str(destination)], check=True)
    for name in ('null', 'zero', 'random', 'urandom'):
        destination = root / 'dev' / name; destination.touch(exist_ok=True)
        subprocess.run(['mount', '--bind', '/dev/' + name, str(destination)], check=True)
    subprocess.run(['mount', '-t', 'proc', 'proc', str(root / 'proc')], check=True)
    (root / 'dev/shm').mkdir(exist_ok=True)
    subprocess.run(['mount', '-t', 'tmpfs', 'tmpfs', str(root / 'dev/shm')], check=True)
    os.execvp('chroot', ['chroot', str(root), '/usr/bin/python3', '-u', '/build/helpers/linux_compat.py', '--inside', '/build/helpers/job.json'])


def inside(job):
    root = Path('/build/nnu-multiplatform'); source = root / 'source'
    env = dict(os.environ, LANG='C.UTF-8', LC_ALL='C.UTF-8', DEBIAN_FRONTEND='noninteractive',
               PATH='/opt/rust/bin:/tools/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
               CC='clang-11', CXX='clang++-11', LIBCLANG_PATH='/usr/lib/llvm-11/lib', CARGO_BUILD_JOBS='6',
               VCPKG_ROOT=str(root / 'vcpkg'), VCPKG_DOWNLOADS='/tools/downloads', VCPKG_MAX_CONCURRENCY='6',
               VCPKG_BINARY_SOURCES='clear;files,' + str(root / 'binary-cache') + ',readwrite',
               SSL_CERT_FILE='/tools/ca-certificates.crt', CURL_CA_BUNDLE='/tools/ca-certificates.crt', CARGO_HTTP_CAINFO='/tools/ca-certificates.crt',
               FLUTTER_SUPPRESS_ANALYTICS='true', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='safe.directory', GIT_CONFIG_VALUE_0='/tools/flutter')
    env['NNU_OFFICIAL_SUPPORT_PUBLIC_KEYS'] = job['public_keys']
    marker = root / 'dependencies-v1'
    if not marker.exists():
        execute(['apt-get', 'update'], root / 'apt-update.log', env=env)
        execute(['apt-get', 'install', '-y', '--no-install-recommends'] + PACKAGES, root / 'apt-install.log', env=env)
        marker.touch()
    vcpkg = root / 'vcpkg'
    if not vcpkg.exists():
        execute(['git', 'clone', '--shared', '/tools/vcpkg-seed', vcpkg], root / 'vcpkg-clone.log', env=env)
    execute(['git', 'checkout', '9e593bb18ea69cc5095e012465dcd675a822ed0d'], root / 'vcpkg-baseline.log', cwd=vcpkg, env=env)
    if not (vcpkg / 'vcpkg').exists(): shutil.copy2('/tools/vcpkg-seed/vcpkg', vcpkg / 'vcpkg')
    (root / 'binary-cache').mkdir(exist_ok=True)
    installed = root / 'installed-linux'
    if not (vcpkg / 'installed').exists(): (vcpkg / 'installed').symlink_to(installed, target_is_directory=True)
    execute([vcpkg / 'vcpkg', 'install', '--triplet', 'x64-linux', '--x-install-root=' + str(installed), '--disable-metrics'], root / 'vcpkg.log', cwd=source, env=env)
    execute(['cargo', 'build', '--locked', '--features', 'flutter,hwcodec,unix-file-copy-paste', '--lib', '--release'],
            root / 'native.log', cwd=source, env=env)
    native = (source / 'target/release/liblibrustdesk.so').read_bytes()
    for key in job['public_keys'].split(','):
        if key.strip(): assert key.strip().encode() in native, 'Official-support public key missing from Linux core'
    execute(['flutter', 'pub', 'get'], root / 'flutter-pub.log', cwd=source / 'flutter', env=env)
    execute(['python3', 'build.py', '--flutter', '--hwcodec', '--unix-file-copy-paste', '--skip-cargo'],
            root / 'flutter.log', cwd=source, env=env)
    from linux_packages import package, RUNTIME_LIBRARIES
    runtime_sources = root / 'runtime-sources'
    runtime_sources.mkdir(exist_ok=True)
    sources = set()
    for _, name in RUNTIME_LIBRARIES:
        value = subprocess.check_output(['dpkg-query', '-W', '-f=${source:Package}=${source:Version}', name], universal_newlines=True).strip()
        sources.add(value)
    if not (runtime_sources / 'complete.json').exists():
        execute(['apt-get', 'source', '--download-only', '--only-source'] + sorted(sources), root / 'runtime-sources.log', cwd=runtime_sources, env=env)
        (runtime_sources / 'complete.json').write_text(json.dumps(sorted(sources)))
    bundled_sources = source / 'flutter/build/linux/x64/release/bundle/licenses/sources'
    bundled_sources.mkdir(parents=True, exist_ok=True)
    for path in runtime_sources.iterdir(): shutil.copy2(path, bundled_sources / path.name)
    package(source, root, root / 'output', job['build'], job['version'], minimum_glibc='2.28', minimum_libstdcpp='8')
    verify_abi(source / 'flutter/build/linux/x64/release/bundle', root / 'linux-abi-verification.json')


def verify_abi(bundle, proof):
    import re
    files = []
    for path in [bundle / 'rustdesk'] + sorted((bundle / 'lib').glob('*.so*')):
        symbols = subprocess.check_output(['readelf', '--version-info', str(path)], universal_newlines=True)
        versions = [tuple(map(int, version.split('.'))) for version in re.findall(r'GLIBC_(\d+[.]\d+)', symbols)]
        assert not versions or max(versions) <= (2, 28), 'Too new GLIBC: ' + str(path)
        cpp = [tuple(map(int, version.split('.'))) for version in re.findall(r'GLIBCXX_(\d+[.]\d+[.]\d+)', symbols)]
        assert not cpp or max(cpp) <= (3, 4, 25), 'Too new libstdc++: ' + str(path)
        abi = [tuple(map(int, version.split('.'))) for version in re.findall(r'CXXABI_(\d+[.]\d+[.]\d+)', symbols)]
        assert not abi or max(abi) <= (1, 3, 11), 'Too new C++ ABI: ' + str(path)
        files.append(dict(name=path.name, glibc='.'.join(map(str, max(versions))) if versions else None))
    proof.write_text(json.dumps(dict(verified=True,maximum_glibc='2.28',maximum_glibcxx='3.4.25',files=files), indent=2))


if __name__ == '__main__':
    config = json.loads(Path(sys.argv[2]).read_text())
    if sys.argv[1] == '--namespace': namespace(config)
    elif sys.argv[1] == '--inside': inside(config)
    else: raise ValueError('Unknown compatibility build mode')
