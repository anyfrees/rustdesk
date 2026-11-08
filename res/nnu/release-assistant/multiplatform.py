"""Windows GUI coordinator for Windows plus isolated local WSL platform builds."""
import ctypes
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

import android_signing
from engine import Builder, BuildError, VERSION_FILE, read_version, save_result, sha, source_files

DISTRO = 'NNU-SecureBuild'


def capture(args, **kwargs):
    frozen = getattr(sys, 'frozen', False)
    if frozen: ctypes.windll.kernel32.SetDllDirectoryW(None)
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              creationflags=subprocess.CREATE_NO_WINDOW, check=True, **kwargs)
    finally:
        if frozen: ctypes.windll.kernel32.SetDllDirectoryW(str(sys._MEIPASS))


def wsl_path(path):
    return capture(['wsl', '-d', DISTRO, '--exec', 'env', 'LANG=C.UTF-8', 'LC_ALL=C.UTF-8',
                    'wslpath', '-a', '-u', Path(path).resolve().as_posix()]).stdout.decode('utf-8').strip()


def check_local():
    try:
        result = capture(['wsl', '--list', '--quiet'])
        text = result.stdout.decode('utf-16-le' if b'\0' in result.stdout else 'utf-8').replace('\0', '')
        if DISTRO not in text.split(): raise ValueError('Dedicated distro is missing')
        capture(['wsl', '-d', DISTRO, '--exec', 'python3', '-c', 'import sys; assert sys.version_info >= (3,9)'])
    except Exception as exc:
        raise BuildError('Android/Linux 需要本地专用 WSL 环境 NNU-SecureBuild。当前环境不可用，请检查 WSL；不会改动其它 Linux 发行版。') from exc


class MultiPlatformBuilder(Builder):
    def build(self, build, version, notes, password='', force_full=False, targets=('windows',)):
        targets = tuple(dict.fromkeys(targets))
        if not targets or any(t not in ('windows', 'linux', 'android') for t in targets):
            raise BuildError('请选择要生成的安装包平台。')
        cross = [t for t in targets if t != 'windows']
        if not cross: return super().build(build, version, notes, password, force_full)
        check_local()
        current, _ = read_version(self.settings.source)
        if type(build) is not int or build <= current or ('android' in targets and build > 2100000000):
            raise BuildError('内部版本号无效，请刷新助手；Android 版本号不能超过 2100000000。')
        if not version.strip() or len(version) > 80 or not version.isprintable() or not notes.strip() or len(notes) > 8000:
            raise BuildError('请填写有效的版本名称和更新说明。')
        windows_result = None
        if 'windows' in targets:
            def relay(kind, payload):
                if kind != 'done': self.report(kind, payload)
            windows_result = Builder(self.settings, relay).build(build, version, notes, password, force_full)
        job = Path(self.settings.output) / f'NNU-多平台-{build}-{datetime.now():%Y%m%d-%H%M%S}'
        job.mkdir(parents=True, exist_ok=False)
        packages = job / '安装包'; packages.mkdir()
        self.logfile = (job / '构建日志.txt').open('w', encoding='utf-8')
        try:
            self.phase(1, '准备本地多平台构建环境')
            # Copy scripts rather than relying on this EXE's temporary extraction directory.
            helper = Path(self.settings.tools) / 'multiplatform-worker'
            helper.mkdir(parents=True, exist_ok=True)
            source_helpers = Path(self.settings.source) / 'res/nnu/release-assistant'
            if not (source_helpers / 'cross_worker.py').exists():
                raise BuildError('当前源码缺少多平台构建组件，请使用助手自带源码或包含这些组件的 NNU 源码。')
            for name in ('cross_worker.py', 'linux_packages.py', 'android_packages.py', 'android_key_worker.py'):
                shutil.copy2(source_helpers / name, helper / name)
            shutil.copytree(source_helpers / 'sodium-sys', helper / 'sodium-sys', dirs_exist_ok=True)
            archive = job / '构建源码.zip'
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
                for path, relative in source_files(self.settings.source):
                    data = path.read_bytes()
                    if relative.as_posix() == VERSION_FILE:
                        text = data.decode('utf-8').replace('\r\n', '\n')
                        text = re.sub(r'(const nnuClientBuild = )\d+', lambda m: m[1] + str(build), text)
                        literal = json.dumps(version.strip(), ensure_ascii=False).replace('$', '\\$')
                        text = re.sub(r'^const nnuClientVersion = .+;$', lambda _: f'const nnuClientVersion = {literal};', text, flags=re.M)
                        data = text.encode('utf-8')
                    elif relative.as_posix() == 'flutter/assets/nnu-release.json':
                        data = json.dumps({'build': build, 'version': version.strip()}, ensure_ascii=False).encode('utf-8')
                    z.writestr(relative.as_posix(), data)
            if 'android' in cross:
                key_worker = wsl_path(helper / 'android_key_worker.py')
                if not android_signing.available():
                    try:
                        capture(['wsl', '-d', DISTRO, '--exec', 'test', '-x', '/usr/lib/jvm/java-17-openjdk-amd64/bin/keytool'])
                    except subprocess.CalledProcessError:
                        self.env = os.environ.copy()
                        self.run(['wsl', '-d', DISTRO, '--exec', 'apt-get', 'update'], cwd=job)
                        self.run(['wsl', '-d', DISTRO, '--exec', 'apt-get', 'install', '-y', '--no-install-recommends', 'openjdk-17-jdk-headless'], cwd=job)
                    raw = capture(['wsl', '-d', DISTRO, '--exec', 'python3', key_worker]).stdout
                    android_signing.store(raw)
                capture(['wsl', '-d', DISTRO, '--exec', 'python3', key_worker, '--import-key'], input=android_signing.read())
                self.log('Android 签名密钥已载入私有工作区；密钥不进入源码和安装包目录。')
            config = {'targets': cross, 'build': build, 'version': version, 'source_zip': wsl_path(archive),
                      'output': wsl_path(packages), 'vcpkg_seed': wsl_path(Path(self.settings.tools) / 'vcpkg'),
                      'vcpkg_downloads': wsl_path(Path(self.settings.tools) / 'vcpkg/downloads')}
            config_path = job / 'local-build.json'
            config_path.write_text(json.dumps(config), encoding='utf-8')
            self.phase(3, '在本机编译所选 Android / Linux 安装包')
            self.env = os.environ.copy()
            self.run(['wsl', '-d', DISTRO, '--exec', 'python3', '-u', wsl_path(helper / 'cross_worker.py'), wsl_path(config_path)],
                     cwd=job)
            if windows_result:
                shutil.copytree(Path(windows_result['folder']) / '安装包', packages / 'Windows', dirs_exist_ok=True)
            self.phase(5, '汇总安装包和校验信息')
            installers = [p for p in packages.rglob('*') if p.is_file()]
            if not installers: raise BuildError('构建没有生成安装包，请查看日志。')
            (job / 'SHA256SUMS.txt').write_text(''.join(f'{sha(p)}  {p.relative_to(job).as_posix()}\n' for p in sorted(installers)), encoding='utf-8')
            bundle = job / f'NNU-{build}-多平台安装包.zip'
            with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as z:
                for p in installers + [job / 'SHA256SUMS.txt']:
                    z.write(p, p.relative_to(job).as_posix())
            result = {'folder': str(job), 'bundle': str(bundle), 'windows_bundle': windows_result['bundle'] if windows_result else '',
                      'build': build, 'version': version, 'platforms': targets, 'distribution_only': True}
            from platform_bundle import create as create_platform_bundle
            result['platform_bundle'] = create_platform_bundle(self.settings, job, packages, build, version, notes, result['windows_bundle'])
            (job / '构建结果.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
            if not windows_result:
                # Keep the visible source build counter in step after a successful cross-only build.
                path = Path(self.settings.source) / VERSION_FILE; text = path.read_text(encoding='utf-8')
                text = re.sub(r'(const nnuClientBuild = )\d+', lambda m: m[1] + str(build), text)
                literal = json.dumps(version.strip(), ensure_ascii=False).replace('$', '\\$')
                text = re.sub(r'^const nnuClientVersion = .+;$', lambda _: f'const nnuClientVersion = {literal};', text, flags=re.M)
                path.write_text(text, encoding='utf-8')
                metadata = Path(self.settings.source) / 'flutter/assets/nnu-release.json'
                metadata.write_text(json.dumps({'build': build, 'version': version.strip()}, ensure_ascii=False), encoding='utf-8')
            save_result(result); self.report('done', result)
            return result
        except Exception:
            if windows_result: self.log('Windows 安装包已保留：' + windows_result['folder'])
            raise
        finally:
            self.logfile.close()
