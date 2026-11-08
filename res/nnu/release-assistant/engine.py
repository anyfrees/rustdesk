"""Local-only release construction; signing keys never leave this computer."""
import ast
import base64
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import brotli
import signing_vault
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

PUBLIC_KEY = '1umorhoB3pej9Cu4Jlvi/n1JHPdLd6XxcdxDSFaWYGQ='
VERSION_FILE = 'flutter/lib/desktop/widgets/nnu_update_service.dart'
ARTIFACTS = ('RustDesk-NNU-1.5.0-x64-Portable.exe', 'RustDesk-NNU-1.5.0-x64-Install.exe',
             'RustDesk-NNU-1.5.0-x64.msi', 'RustDesk-NNU-1.5.0-x64.zip')
SKIP_DIRS = {'.git', '.dart_tool', '.venv', '__pycache__', 'node_modules', 'target',
             'build', 'dist', 'wheels', 'ephemeral', 'private', 'state', '.idea', '.vs'}
CORE_EXT = {'.rs', '.toml', '.lock', '.c', '.cpp', '.h', '.hpp', '.proto', '.cmake'}


class BuildError(Exception):
    pass


@dataclass
class Settings:
    source: str
    tools: str
    output: str
    key: str
    visual_studio: str = 'C:/BuildTools'

    @classmethod
    def defaults(cls):
        candidates = [Path(__file__).resolve(), Path(sys.executable).resolve(), Path.cwd()]
        source = None
        for candidate in candidates:
            for parent in (candidate, *candidate.parents):
                for path in (parent, parent / 'rustdesk-diy'):
                    if (path / VERSION_FILE).is_file() and (path / 'Cargo.toml').is_file():
                        source = path
                        break
                if source:
                    break
            if source:
                break
        source = source or Path.home() / 'Desktop/计划任务/rustdesk-diy'
        tools = Path.home() / '.codex/tools/nnu-build'
        return cls(str(source), str(tools), str(source.parent / 'dist'),
                   'builtin' if signing_vault.available() else str(tools / 'private/nnu-update-ed25519.pem'))


def config_path():
    return Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'NNU/ReleaseAssistant/settings.json'


def load_settings():
    values = asdict(Settings.defaults())
    if config_path().exists():
        values.update({k: v for k, v in json.loads(config_path().read_text(encoding='utf-8')).items()
                       if k in values and isinstance(v, str)})
    return Settings(**values)


def save_settings(settings):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(settings), ensure_ascii=False, indent=2), encoding='utf-8')


def save_result(result):
    path=config_path().with_name('last-result.json')
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def read_version(source):
    text = (Path(source) / VERSION_FILE).read_text(encoding='utf-8')
    build = re.search(r'^const nnuClientBuild = (\d+);$', text, re.M)
    version = re.search(r'^const nnuClientVersion = (.+);$', text, re.M)
    if not build or not version:
        raise BuildError('找不到客户端版本信息，请检查源码目录。')
    return int(build[1]), ast.literal_eval(version[1].replace('\\$', '$'))


def native_version(source):
    text=(Path(source)/'Cargo.toml').read_text(encoding='utf-8')
    match=re.search(r'^version\s*=\s*"(\d+\.\d+\.\d+)"',text,re.M)
    if not match:
        raise BuildError('客户端原生版本无法识别。')
    return match[1]


def artifact_names(version):
    return tuple(name.replace('1.5.0',version) for name in ARTIFACTS)


def next_version(source):
    current, label = read_version(source)
    build = max(current + 1, int(datetime.now().strftime('%Y%m%d')) * 100 + 1)
    label = label.replace(' · ', ' ')
    if (Path(source)/'Cargo.toml').exists():
        label = re.sub(r'^\d+\.\d+\.\d+',native_version(source),label)
    label = re.sub(r'UI(\d+)', lambda m: 'UI' + str(int(m[1]) + 1), label)
    return build, label


def source_files(source):
    source = Path(source).resolve()
    for root, dirs, files in os.walk(source, followlinks=False):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not (Path(root) / d).is_symlink()]
        if Path(root).relative_to(source).as_posix() == 'res/msi/CustomActions':
            dirs[:] = [d for d in dirs if d not in {'x64', 'ARM64', 'Debug', 'Release'}]
        for name in files:
            path = Path(root) / name
            lower = name.lower()
            public_test_fixture = path.relative_to(source).as_posix() in {
                'libs/hbb_common/tests/data/websocket-cert.pem',
                'libs/hbb_common/tests/data/websocket-key.pem',
                'src/trusted_devices/tests/credentials.rs',
            }
            if (path.is_symlink() or (path.suffix.lower() in {'.pem', '.pfx', '.p12', '.key', '.pyc', '.dpapi', '.nnu-key', '.jks', '.keystore'} and not public_test_fixture)
                    or lower.startswith('.env') or (lower.startswith('credentials') and not public_test_fixture)
                    or lower in {'ssh.txt', 'login.txt', '.git', 'key.properties'}):
                continue
            if path.resolve().is_relative_to(source):
                yield path, path.relative_to(source)


def core_fingerprint(source):
    digest = hashlib.sha256()
    for path, relative in sorted(source_files(source), key=lambda item: item[1].as_posix()):
        name = relative.as_posix()
        if name == 'src/version.rs':
            continue
        is_core = name.startswith(('src/', 'libs/')) and not name.startswith('libs/portable/')
        if ((is_core and path.suffix in CORE_EXT)
                or name in {'Cargo.toml', 'Cargo.lock', 'build.rs', 'rust-toolchain.toml', '.cargo/config.toml',
                            'res/nnu/apply-portable-update.ps1'}):
            digest.update(name.encode() + b'\0' + path.read_bytes().replace(b'\r\n', b'\n') + b'\0')
    return digest.hexdigest()


def validate_key(settings):
    raw = signing_material(settings)
    try:
        key = serialization.load_pem_private_key(raw, password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError()
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        if public != base64.b64decode(PUBLIC_KEY):
            raise ValueError()
    except Exception as exc:
        raise BuildError('签名密钥与客户端公钥不匹配，请选择原有发布密钥。') from exc


def signing_material(settings):
    if settings.key == 'builtin':
        return signing_vault.read()
    path = Path(settings.key).resolve()
    if not path.is_file():
        raise BuildError('发布签名密钥未设置，请在设置中选择本机密钥文件。')
    if path.is_relative_to(Path(settings.source).resolve()) or path.is_relative_to(Path(settings.output).resolve()):
        raise BuildError('签名密钥必须放在源码和产物目录之外的私人目录。')
    return path.read_bytes()


def executable(name):
    path = shutil.which(name)
    if not path:
        raise BuildError(f'本机缺少 {name}，请先配置构建环境。')
    return path


def environment(settings):
    tools = Path(settings.tools)
    required = {
        'Flutter': tools / 'flutter/bin/flutter.bat',
        'LLVM': tools / 'llvm/bin/libclang.dll',
        'NuGet': tools / 'nuget.exe',
        'Visual Studio': Path(settings.visual_studio) / 'MSBuild/Current/Bin/MSBuild.exe',
        '窗口组件': tools / 'RustDeskTempTopMostWindow/WindowInjection/x64/Release/WindowInjection.dll',
        'vcpkg': tools / 'vcpkg/vcpkg.exe',
        '打印驱动': tools / 'rustdesk_printer_driver_v4-1.4.zip',
        '打印适配器': tools / 'printer_driver_adapter.zip',
        '显示驱动': tools / 'usbmmidd_v2.zip',
    }
    missing = [name for name, path in required.items() if not path.is_file()]
    for name in ('py', 'cargo', 'rustc', 'powershell.exe'):
        if not shutil.which(name):
            missing.append(name)
    if not (Path(settings.source) / VERSION_FILE).is_file():
        missing.append('客户端源码')
    if not (tools / 'source/flutter/windows/CMakeLists.txt').is_file():
        missing.append('独立构建缓存')
    if missing:
        raise BuildError('需要配置：' + '、'.join(missing) + '。请打开设置检查路径。')
    if Path(settings.source).resolve() == (tools / 'source').resolve():
        raise BuildError('源码目录与构建缓存必须分开，请选择 rustdesk-diy 源码目录。')
    output = Path(settings.output).resolve()
    if output == Path(settings.source).resolve() or Path(settings.source).resolve().is_relative_to(output):
        raise BuildError('产物目录不能包含源码目录，请选择独立的 dist 文件夹。')
    output.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output).free < 2 * 1024**3:
        raise BuildError('产物所在磁盘至少需要 2 GB 可用空间。')
    validate_key(settings)
    return required


def baseline_path(settings):
    return Path(settings.tools) / 'release-assistant/native-baseline.json'


def native_reusable(settings):
    path = baseline_path(settings)
    dll = Path(settings.tools) / 'source/flutter/build/windows/x64/runner/Release/librustdesk.dll'
    if not path.is_file() or not dll.is_file():
        return False
    baseline = json.loads(path.read_text())
    return (baseline['source'] == core_fingerprint(settings.source)
            and baseline['sha256'] == sha(dll))


def seed_verified_native(settings, metadata):
    """Initialize this machine only from an already verified native build."""
    dll = Path(settings.tools) / 'source/flutter/build/windows/x64/runner/Release/librustdesk.dll'
    info = json.loads(Path(metadata).read_text(encoding='utf-8'))
    if sha(dll) != info['native_core_sha256'] or core_fingerprint(settings.source) != core_fingerprint(Path(settings.tools) / 'source'):
        raise BuildError('原生核心来源无法确认，请使用完整构建。')
    path = baseline_path(settings)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'source': core_fingerprint(settings.source), 'sha256': sha(dll)}))


@contextmanager
def build_lock(settings):
    import msvcrt
    path = Path(settings.tools) / 'release-assistant.lock'
    with path.open('a+b') as f:
        f.seek(0)
        if not f.read(1):
            f.write(b'0'); f.flush()
        f.seek(0)
        try:
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise BuildError('另一项构建正在进行，请等待它完成。') from exc
        try:
            yield
        finally:
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_bundle(settings, packages, destination, build, version, notes):
    validate_key(settings)
    packages, destination = Path(packages), Path(destination)
    upstream = json.loads((packages/'BUILD-INFO.json').read_text(encoding='utf-8')).get('version','1.5.0') if (packages/'BUILD-INFO.json').exists() else '1.5.0'
    for name in artifact_names(upstream):
        if not (packages / name).is_file():
            raise BuildError('安装包不完整，缺少：' + name)
    publisher = load_module(Path(settings.source) / 'res/nnu/update-server/publish.py', 'nnu_release_publisher')
    public = Path(settings.source) / 'res/nnu/update-admin'
    old_release = sys.modules.get('release')
    try:
        sys.modules['release'] = load_module(public / 'release.py', 'nnu_release_validator')
        bundler = load_module(public / 'bundle.py', 'nnu_release_bundler')
        signed = destination / 'signed'
        publisher.prepare(packages, signed, signing_vault.PrivateKeySource(signing_material(settings)), build, version, notes, upstream)
        bundle = destination / f'NNU-{build}-升级发布包.zip'
        bundler.bundle(signed, bundle)
        with zipfile.ZipFile(bundle, 'a', compression=zipfile.ZIP_STORED) as archive:
            for name in ('RustDesk-NNU-1.5.0-Source.zip', 'SHA256SUMS.txt', 'README.md', 'BUILD-INFO.json'):
                extra = packages / name
                if extra.is_file():
                    archive.write(extra, f'releases/{build}/{name}')
    finally:
        if old_release is None:
            sys.modules.pop('release', None)
        else:
            sys.modules['release'] = old_release
    return bundle


def package_existing(settings, folder, report=lambda *args: None):
    folder = Path(folder)
    info = json.loads((folder / 'BUILD-INFO.json').read_text(encoding='utf-8'))
    build = info['build']
    # The manifest must use the build actually embedded in these binaries.
    version = info.get('display_version') or f"{info.get('version', '1.5.0')} NNU {info['ui_revision']}"
    notes = (folder / '更新说明.txt').read_text(encoding='utf-8')
    destination = Path(settings.output) / f'NNU-{build}-重新打包-{datetime.now():%Y%m%d-%H%M%S}'
    destination.mkdir()
    report('phase', (4, '校验并生成升级发布包'))
    bundle = release_bundle(settings, folder, destination, build, version, notes)
    result={'folder': str(destination), 'bundle': str(bundle), 'build': build, 'version': version}
    save_result(result)
    report('done', result)
    return bundle


class Builder:
    def __init__(self, settings, report=lambda *args: None):
        self.settings, self.report = settings, report
        self.logfile = None
        self.password = ''

    def log(self, message):
        if self.password:
            message = message.replace(self.password, '[已隐藏]')
        if self.logfile:
            self.logfile.write(message.rstrip() + '\n'); self.logfile.flush()
        self.report('log', message.rstrip())

    def run(self, args, cwd, env=None, allow_symlink=False):
        self.log('执行：' + ' '.join(str(a) for a in args))
        child_env = (env or self.env).copy()
        for key in list(child_env):
            if key.startswith('_PYI_') or key in {'PYTHONHOME', 'PYTHONPATH'}:
                child_env.pop(key)
        frozen = getattr(sys, 'frozen', False)
        if frozen:
            ctypes.windll.kernel32.SetDllDirectoryW(None)
        try:
            process = subprocess.Popen([str(x) for x in args], cwd=cwd, env=child_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        finally:
            if frozen:
                ctypes.windll.kernel32.SetDllDirectoryW(str(sys._MEIPASS))
        lines = []
        for line in iter(process.stdout.readline, b''):
            try:
                decoded = line.decode('utf-8')
            except UnicodeDecodeError:
                decoded = line.decode('gb18030', errors='replace')
            self.log(decoded)
            lines.append(decoded)
        process.stdout.close()
        if process.wait() and not (allow_symlink and 'symlink support' in ''.join(lines)):
            raise BuildError('构建步骤未完成，请打开日志查看具体原因。')

    def phase(self, number, label):
        self.report('phase', (number, label))
        self.log(label)

    def build(self, build, version, notes, password='', force_full=False):
        settings = self.settings
        environment(settings)
        current, _ = read_version(settings.source)
        if type(build) is not int or build <= current or build >= 2**53:
            raise BuildError('内部版本号必须大于源码当前版本，请重新打开助手。')
        if not isinstance(version, str) or not 1 <= len(version.strip()) <= 80 or not version.isprintable():
            raise BuildError('请填写 1–80 个字符的版本名称。')
        if not notes.strip() or len(notes) > 8000:
            raise BuildError('请填写更新说明，最多 8000 个字符。')
        full = force_full or not native_reusable(settings)
        if full and not (password or os.environ.get('NNU_PORTABLE_PASSWORD')):
            raise BuildError('本次需要完整构建，请在设置中填写便携版预设密码。')
        self.password = password or os.environ.get('NNU_PORTABLE_PASSWORD', '')
        tools, source = Path(settings.tools), Path(settings.source)
        cache = tools / 'source'
        job = Path(settings.output) / f'NNU-{build}-{datetime.now():%Y%m%d-%H%M%S}'
        job.mkdir()
        self.logfile = (job / '构建日志.log').open('w', encoding='utf-8')
        version_path = source / VERSION_FILE
        before = version_path.read_bytes()
        metadata_path = source / 'flutter/assets/nnu-release.json'
        metadata_before = metadata_path.read_bytes() if metadata_path.exists() else None
        metadata_updated = json.dumps({'build': build, 'version': version.strip()}, ensure_ascii=False).encode('utf-8')
        text = before.decode('utf-8').replace('\r\n', '\n')
        text = re.sub(r'^const nnuClientBuild = \d+;$', f'const nnuClientBuild = {build};', text, flags=re.M)
        literal = json.dumps(version.strip(), ensure_ascii=False).replace('$', '\\$')
        text = re.sub(r'^const nnuClientVersion = .+;$', lambda _: f'const nnuClientVersion = {literal};', text, flags=re.M)
        updated = text.encode('utf-8')
        success = False
        version_written = False
        try:
            with build_lock(settings):
                (tools / 'release-assistant').mkdir(exist_ok=True)
                self.phase(1, '准备源码和构建环境')
                version_path.write_bytes(updated)
                version_written = True
                if metadata_before is not None:
                    metadata_path.write_bytes(metadata_updated)
                # Remove files deleted from the source, only within this build checkout.
                managed_path = tools / 'release-assistant/synced-files.json'
                files = list(source_files(source))
                current_files = {relative.as_posix() for _, relative in files}
                previous = set(json.loads(managed_path.read_text())) if managed_path.exists() else set()
                if (source / '.git').exists():
                    tracked = subprocess.run(['git', '-C', str(source), 'ls-files', '--deleted', '-z'],
                                             capture_output=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
                    previous.update(n for n in tracked.stdout.decode().split('\0') if n)
                for name in previous - current_files:
                    stale = (cache / name).resolve()
                    if not stale.is_relative_to(cache.resolve()) or '.git' in Path(name).parts:
                        raise BuildError('构建缓存路径异常，请检查设置。')
                    if stale.is_file():
                        stale.unlink()
                for path, relative in files:
                    destination = cache / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, destination)
                managed_path.write_text(json.dumps(sorted(current_files)))
                self.env = dict(os.environ)
                self.env.update(RUSTUP_TOOLCHAIN='1.75.0', VCPKG_ROOT=str(tools / 'vcpkg'),
                                VCPKG_VISUAL_STUDIO_PATH=settings.visual_studio,
                                VCPKG_DEFAULT_HOST_TRIPLET='x64-windows-static',
                                LIBCLANG_PATH=str(tools / 'llvm/bin'), CARGO_BUILD_JOBS='8', PYTHONUTF8='1')
                self.env['PATH'] = str(tools / 'flutter/bin') + ';' + str(tools / 'llvm/bin') + ';' + self.env['PATH']
                if self.password:
                    self.env['NNU_PORTABLE_PASSWORD'] = self.password
                flutter = tools / 'flutter/bin/flutter.bat'
                self.run([flutter, 'pub', 'get'], cache / 'flutter', allow_symlink=True)
                self.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                          source / 'res/nnu/release-assistant/prepare-junctions.ps1', '-BuildRoot', cache], cache)
                self.run([flutter, 'pub', 'get', '--offline'], cache / 'flutter')
                self.phase(2, '运行回归检查')
                tests = [p for p in ['test/nnu_support_test.dart', 'test/nnu_update_test.dart', 'test/nnu_external_update_test.dart', 'test/nnu_platform_update_test.dart', 'test/nnu_action_button_test.dart', 'test/nnu_auto_update_test.dart', 'test/nnu_connection_window_option_test.dart', 'test/nnu_management_options_test.dart', 'test/nnu_lan_announcement_test.dart', 'test/nnu_announcement_themes_test.dart']
                         if (cache / 'flutter' / p).exists()]
                self.run([flutter, 'test', *tests], cache / 'flutter')
                test_env = self.env.copy()
                test_env.setdefault('NNU_PORTABLE_PASSWORD', 'nnu-build-test-fixture')
                self.run(['rustc', '--edition=2021', '--test', 'res/nnu/test_bootstrap.rs', '-o',
                          tools / 'release-assistant/bootstrap-tests.exe'], cache, test_env)
                self.run([tools / 'release-assistant/bootstrap-tests.exe'], cache)
                self.phase(3, '编译客户端' + ('（完整构建）' if full else '（复用已验证核心）'))
                if full:
                    self.run([tools / 'vcpkg/vcpkg.exe', 'install', '--triplet', 'x64-windows-static',
                              '--host-triplet', 'x64-windows-static', f'--x-install-root={tools / "vcpkg/installed"}'], cache)
                    self.run(['cargo', 'build', '--locked', '--release'], cache / 'libs/virtual_display/dylib')
                    self.run(['cargo', 'build', '--locked', '--features', 'flutter,hwcodec,vram', '--lib', '--release'], cache)
                self.run([flutter, 'build', 'windows', '--release', '--no-pub'], cache / 'flutter')
                dist = cache / 'flutter/build/windows/x64/runner/Release'
                shutil.copy2(cache / 'target/release/deps/dylib_virtual_display.dll', dist)
                shutil.copy2(tools / 'RustDeskTempTopMostWindow/WindowInjection/x64/Release/WindowInjection.dll', dist)
                self.run(['py', 'res/nnu/package-drivers.py', '--tools', tools, '--dist', dist], cache)
                self.phase(4, '生成四种安装包并校验')
                packages = job / '安装包'
                packages.mkdir()
                names = artifact_names(native_version(source))
                self.run(['py', 'generate.py', '-f', dist, '-o', '.', '-e', dist / 'rustdesk.exe', '-l', '9'], cache / 'libs/portable')
                for name in names[:2]:
                    shutil.copy2(cache / 'target/release/rustdesk-portable-packer.exe', packages / name)
                msi = cache / 'res/msi'
                templates = {p: p.read_bytes() for p in msi.rglob('*') if p.suffix in {'.wxs', '.wxl', '.wixproj', '.props'}}
                try:
                    self.run(['py', 'preprocess.py', '--arp', '-d', dist], msi)
                    self.run([tools / 'nuget.exe', 'restore', 'msi.sln', '-NonInteractive'], msi)
                    self.run([Path(settings.visual_studio) / 'MSBuild/Current/Bin/MSBuild.exe', 'msi.sln',
                              '-p:Configuration=Release', '-p:Platform=x64', '/p:TargetVersion=Windows10'], msi)
                    built = max((msi / 'Package/bin').glob('*/Release/en-us/Package.msi'), key=lambda p: p.stat().st_mtime)
                    shutil.copy2(built, packages / names[2])
                finally:
                    for path, content in templates.items():
                        path.write_bytes(content)
                with zipfile.ZipFile(packages / names[3], 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                    for path in dist.rglob('*'):
                        if path.is_file():
                            archive.write(path, path.relative_to(dist).as_posix())
                self.verify_payload(dist, cache / 'libs/portable/data.bin', packages, names)
                with zipfile.ZipFile(packages / 'RustDesk-NNU-1.5.0-Source.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                    for path, relative in source_files(source):
                        archive.write(path, 'RustDesk-NNU-1.5.0/' + relative.as_posix())
                (packages / '更新说明.txt').write_text(notes, encoding='utf-8')
                shutil.copy2(source / 'docs/NNU-Windows.md', packages / 'README.md')
                shutil.copy2(source / 'LICENCE', packages / 'LICENCE')
                revision = re.search(r'UI[\w.]+', version)
                info = {'version': native_version(source), 'ui_revision': revision[0] if revision else version,
                        'build': build, 'display_version': version, 'built_locally': True,
                        'native_core_sha256': sha(dist / 'librustdesk.dll'), 'native_reused': not full,
                        'portable_compression_level': 9, 'authenticode_signing': 'unsigned',
                        'update_manifest_signature': 'Ed25519', 'source_fingerprint': core_fingerprint(source)}
                (packages / 'BUILD-INFO.json').write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding='utf-8')
                (packages / 'SHA256SUMS.txt').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(packages.iterdir())
                                                           if p.is_file() and p.name.isascii()), encoding='ascii')
                self.phase(5, '本机签名并生成升级发布包')
                bundle = release_bundle(settings, packages, job, build, version, notes)
                baseline = baseline_path(settings)
                baseline.parent.mkdir(parents=True, exist_ok=True)
                if core_fingerprint(source) == core_fingerprint(cache):
                    baseline.write_text(json.dumps({'source': core_fingerprint(source), 'sha256': sha(dist / 'librustdesk.dll')}))
                else:
                    baseline.unlink(missing_ok=True)
                result = {'folder': str(job), 'bundle': str(bundle), 'build': build, 'version': version}
                (job / '构建结果.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
                success = True
                save_result(result)
                self.report('done', result)
                return result
        finally:
            if version_written and not success and version_path.read_bytes() == updated:
                version_path.write_bytes(before)
                if metadata_before is not None and metadata_path.read_bytes() == metadata_updated:
                    metadata_path.write_bytes(metadata_before)
            self.password = ''
            self.logfile.close()

    def verify_payload(self, dist, blob_path, packages, names=ARTIFACTS):
        blob = blob_path.read_bytes()
        if blob[:8] != b'rustdesk':
            raise BuildError('便携包数据无效。')
        offset, count = 8, 0
        with zipfile.ZipFile(packages / names[3]) as archive:
            if archive.testzip() is not None:
                raise BuildError('ZIP 安装包校验失败。')
            while blob[offset:offset + 8] != b'rustdesk':
                length = int.from_bytes(blob[offset:offset + 4], 'big'); offset += 4
                name = blob[offset:offset + length].decode(); offset += length
                length = int.from_bytes(blob[offset:offset + 4], 'big'); offset += 4
                data = brotli.decompress(blob[offset:offset + length]); offset += length
                checksum = blob[offset:offset + 32]; offset += 32
                if (hashlib.md5(data).hexdigest().encode() != checksum or (dist / name).read_bytes() != data
                        or archive.read(name.replace('\\', '/').removeprefix('./')) != data):
                    raise BuildError('安装包文件校验失败：' + name)
                count += 1
        if blob not in (packages / names[0]).read_bytes():
            raise BuildError('EXE 与便携包数据不一致。')
        self.log(f'已逐文件校验 {count} 个安装文件。')
