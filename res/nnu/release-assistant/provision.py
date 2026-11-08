"""Download missing build tools from official sources; preserve existing installs."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

from engine import Builder, BuildError, environment, sha, source_files


def resource_root():
    packaged = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'resources'
    if packaged.exists() or getattr(sys,'frozen',False):
        return packaged
    return Path(os.environ.get('LOCALAPPDATA',Path.home()))/'NNU/ReleaseAssistant/packaging-assets/resources'


def extract_safe(archive, destination):
    root = Path(destination).resolve()
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            path = root / info.filename
            if ('\\' in info.filename or ':' in info.filename or not path.resolve().is_relative_to(root)
                    or (info.external_attr >> 16) & 0o170000 == 0o120000):
                raise BuildError('下载包包含不安全路径，已停止解压。')
        z.extractall(root)


def download(url, target, report, expected=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and (expected is None or sha(target) == expected):
        return target
    partial = target.with_suffix(target.suffix + '.part')
    report('log', '下载官方组件：' + target.name)
    with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as f:
        size = int(response.headers.get('Content-Length', 0))
        written, shown = 0, -1
        while chunk := response.read(1024 * 1024):
            f.write(chunk);written += len(chunk)
            percent = written * 100 // size if size else -1
            if percent // 10 > shown:
                report('log', f'下载 {target.name}：{percent}%');shown = percent // 10
        if size and written != size:
            raise BuildError('下载未完成，请重新点击补全。')
    if expected and sha(partial) != expected:
        raise BuildError('下载摘要校验失败，请删除下载缓存后重试。')
    os.replace(partial, target)
    return target


def complete_environment(settings, report):
    tools = Path(settings.tools)
    tools.mkdir(parents=True, exist_ok=True)
    runner = Builder(settings, report)
    runner.env = dict(os.environ)
    runner.env['PATH'] = ';'.join([str(Path.home()/'.cargo/bin'), str(Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Git/cmd'),
                                  str(tools/'flutter/bin'),runner.env['PATH']])
    cache = tools / 'downloads'
    cache.mkdir(exist_ok=True)
    def exists(command):
        return shutil.which(command,path=runner.env['PATH'])
    def winget(package, extra=()):
        if not exists('winget'):
            raise BuildError('此电脑缺少 Windows 应用安装程序，请先安装 Microsoft winget 后重试。')
        runner.run(['winget', 'install', '--id', package, '--exact', '--source', 'winget',
                    '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity', *extra], tools)
    report('phase', (1, '检查并补全构建环境'))
    report('log', '已安装组件会保留；仅补充缺少项。')
    for command, package in [('git','Git.Git'),('py','Python.Python.3.14')]:
        if not exists(command):
            winget(package,('--silent',))
            if not exists(command):
                raise BuildError(f'{package} 已安装。请重新打开助手使环境生效，然后再次补全。')
    visual = Path(settings.visual_studio)
    if not (visual/'MSBuild/Current/Bin/MSBuild.exe').is_file():
        report('log','安装 Visual Studio C++ 构建工具，可能需要管理员授权和数 GB 空间。')
        winget('Microsoft.VisualStudio.2022.BuildTools', ('--override',
            f'--wait --passive --norestart --installPath "{visual}" --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'))
    if not (tools/'flutter/bin/flutter.bat').is_file():
        with urllib.request.urlopen('https://storage.googleapis.com/flutter_infra_release/flutter/releases/releases_windows.json',timeout=60) as f:
            data=json.load(f)
        release=next((r for r in data['releases'] if r['version']=='3.24.5' and r['channel']=='stable'),None)
        if not release or not release.get('sha256'):
            raise BuildError('未找到官方 Flutter 3.24.5 摘要，已停止补全。')
        archive=download('https://storage.googleapis.com/flutter_infra_release/flutter/'+release['archive'],cache/'flutter-3.24.5.zip',report,release['sha256'])
        extract_safe(archive,tools)
    if not exists('rustup'):
        url='https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
        with urllib.request.urlopen(url+'.sha256',timeout=60) as f:
            checksum=f.read().decode().split()[0]
        installer=download(url,cache/'rustup-init.exe',report,checksum)
        runner.run([installer,'-y','--no-modify-path','--profile','minimal','--default-toolchain','1.75.0'],tools)
    result=subprocess.run(['rustup','toolchain','list'],env=runner.env,capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
    if b'1.75.0' not in result.stdout:
        runner.run(['rustup','toolchain','install','1.75.0','--profile','minimal'],tools)
    resources=resource_root()
    manifest=resources/'manifest.json'
    if not manifest.is_file():
        raise BuildError('助手组件不完整，请使用完整的助手程序目录。')
    for relative,digest in json.loads(manifest.read_text()).items():
        source=resources/relative
        if not source.is_file() or sha(source)!=digest:
            raise BuildError('助手集成组件摘要不符：'+relative)
        target=tools/relative
        if not target.exists():
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
    source=Path(settings.source)
    if not (source/'Cargo.toml').is_file():
        if source.exists() and any(source.iterdir()):
            raise BuildError('源码目录包含其他文件，请在设置中选择空目录后补全。')
        source.mkdir(parents=True,exist_ok=True)
        extract_safe(resources/'source-snapshot.zip',source)
        report('log','已恢复随工具附带的客户端源码。')
    build=tools/'source'
    if build.resolve()==source.resolve():
        raise BuildError('源码与构建缓存路径必须分开。')
    if not (build/'Cargo.toml').is_file():
        build.mkdir(parents=True,exist_ok=True)
        for path,relative in source_files(source):
            target=build/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
    if not (tools/'vcpkg/vcpkg.exe').is_file():
        vcpkg=tools/'vcpkg'
        if not (vcpkg/'.git').exists():
            runner.run(['git','clone','https://github.com/microsoft/vcpkg.git',vcpkg],tools)
        runner.run(['git','checkout','9e593bb18ea69cc5095e012465dcd675a822ed0d'],vcpkg)
        runner.run([vcpkg/'bootstrap-vcpkg.bat','-disableMetrics'],vcpkg)
    probe=subprocess.run(['py','-c','import cryptography,brotli'],env=runner.env,capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
    if probe.returncode:
        runner.run(['py','-m','pip','install','cryptography==50.0.2','brotli>=1.1,<2'],tools)
    environment(settings)
    report('log','构建环境已就绪。首次完整构建会继续下载并编译 vcpkg 所需库。')
