"""Prepare official source with an explicit, compatibility-checked NNU recipe."""
import hashlib
import json
import os
import re
import shutil
import subprocess
import urllib.request
from datetime import datetime
from pathlib import Path

from engine import Builder, BuildError, source_files, sha, read_version, VERSION_FILE
from provision import download, extract_safe, resource_root

BASE_COMMIT = 'fada664df7a294d1d1a9ca3e7cd3637069122f17'
HBB_BASE = '229b904508364c8997aad0fb5af57effac859f60'


def api(path):
    request = urllib.request.Request('https://api.github.com/repos/rustdesk/' + path,
                                     headers={'User-Agent': 'NNU-Release-Assistant', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def official_latest():
    release = api('rustdesk/releases/latest')
    tag = release['tag_name']
    if release.get('prerelease') or release.get('draft') or not re.fullmatch(r'v?\d+\.\d+\.\d+', tag):
        raise BuildError('官方最新版本不是可识别的稳定版，已停止自动套用。')
    obj = api('rustdesk/git/ref/tags/' + tag)['object']
    if obj['type'] == 'tag':
        obj = api('rustdesk/git/tags/' + obj['sha'])['object']
    if obj['type'] != 'commit' or not re.fullmatch(r'[a-f0-9]{40}', obj['sha']):
        raise BuildError('官方版本提交无法确认。')
    return {'version': tag.lstrip('v'), 'tag': tag, 'commit': obj['sha'], 'url': release['html_url']}


def export_recipe(source, destination):
    source, destination = Path(source), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    def git_diff(repository, base, paths):
        return subprocess.check_output(['git', '-C', str(repository), 'diff', '--binary', base, '--', *paths],
                                       creationflags=subprocess.CREATE_NO_WINDOW)
    main = git_diff(source, BASE_COMMIT, ['src', 'flutter', 'res/msi'])
    # Untracked UI additions are outside git diff and must be added explicitly.
    extras = subprocess.check_output(['git','-C',str(source),'ls-files','--others','--exclude-standard','-z','--','flutter','src'],creationflags=subprocess.CREATE_NO_WINDOW).decode().split('\0')
    for name in extras:
        if name and (source/name).suffix in {'.dart','.rs'}:
            result=subprocess.run(['git','-C',str(source),'diff','--no-index','--binary','--','/dev/null',name],capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode not in (0,1):
                raise BuildError('无法导出当前 DIY 文件：'+name)
            main += result.stdout
    (destination/'nnu-main.patch').write_bytes(main)
    shared = git_diff(source/'libs/hbb_common',HBB_BASE,['src/config.rs'])
    (destination/'nnu-common.patch').write_bytes(shared)
    for relative in ('src/flutter_ffi.rs','Cargo.toml','flutter/pubspec.yaml'):
        original=subprocess.check_output(['git','-C',str(source),'show',BASE_COMMIT+':'+relative],creationflags=subprocess.CREATE_NO_WINDOW)
        (destination/(Path(relative).name+'.base')).write_bytes(original)
    (destination/'recipe.json').write_text(json.dumps({'base':BASE_COMMIT,'hbb_base':HBB_BASE,
        'patches':{p.name:sha(p) for p in destination.glob('*.patch')},'native_version':'1.5.0'},indent=2))


def secure_dependencies(source, runner):
    lock = (Path(source) / 'Cargo.lock').read_text(encoding='utf-8')
    for package, fixed in [('openssl', (0, 10, 81)), ('rustls-webpki', (0, 103, 16)),
                           ('rustls', (0, 23, 46)), ('crossbeam-channel', (0, 5, 15)),
                           ('rand', (0, 8, 6)), ('rand', (0, 9, 3))]:
        for version in re.findall(r'name = "' + re.escape(package) + r'"\s+version = "([0-9.]+)"', lock):
            current = tuple(int(part) for part in version.split('.'))
            if current[:2] == fixed[:2] and current < fixed:
                runner.run(['cargo', 'update', '-p', package + '@' + version,
                            '--precise', '.'.join(map(str, fixed))], source)
    versions = re.findall(r'name = "url"\s+version = "([0-9.]+)"', lock)
    if any(tuple(map(int, version.split('.'))) < (2, 5, 4) for version in versions):
        # Keep the IDNA security fix compatible with the Windows Rust 1.75 toolchain.
        for package, version in [('url', '2.5.4'), ('idna', '1.0.3'), ('idna_adapter', '1.2.0'),
                                 ('zerofrom', '0.1.5'), ('zerofrom-derive', '0.1.5'),
                                 ('litemap', '0.7.4'), ('utf8_iter', '1.0.4'),
                                 ('utf16_iter', '1.0.5'), ('write16', '1.0.0')]:
            runner.run(['cargo', 'update', '-p', package, '--precise', version], source)


def unpack_github(archive, destination):
    stage=destination.with_name(destination.name+'-unpack')
    if stage.exists() or destination.exists():
        raise BuildError('源码目录已存在，请重试生成新目录。')
    stage.mkdir(parents=True)
    extract_safe(archive,stage)
    roots=list(stage.iterdir())
    if len(roots)!=1 or not roots[0].is_dir():
        raise BuildError('官方源码包目录结构异常。')
    os.rename(roots[0],destination)
    stage.rmdir()


def prepare_latest(settings, report, force=False):
    report('phase',(1,'检查 RustDesk 官方稳定版'))
    latest=official_latest()
    source=Path(settings.source)
    cargo=(source/'Cargo.toml').read_text(encoding='utf-8')
    version=re.search(r'^version\s*=\s*"([^"]+)"',cargo,re.M)[1]
    current=tuple(int(x) for x in version.split('.')[:3])
    target=tuple(int(x) for x in latest['version'].split('.'))
    if target <= current and not force:
        report('upstream_current',latest)
        return None
    runner=Builder(settings,report)
    runner.env=dict(os.environ, RUSTUP_TOOLCHAIN='1.75.0',LIBCLANG_PATH=str(Path(settings.tools)/'llvm/bin'),PYTHONUTF8='1')
    runner.env['PATH']=str(Path(settings.tools)/'flutter/bin')+';'+str(Path.home()/'.cargo/bin')+';'+runner.env['PATH']
    root=Path(settings.tools)/'official-sources'
    root.mkdir(parents=True,exist_ok=True)
    job=root/f"rustdesk-{latest['version']}-nnu-{datetime.now():%Y%m%d-%H%M%S}"
    archive=download(f"https://codeload.github.com/rustdesk/rustdesk/zip/{latest['commit']}",root/f"official-{latest['commit']}.zip",report)
    unpack_github(archive,job)
    report('phase',(2,'套用 NNU 样式及服务器参数'))
    recipe=resource_root()/'diy-recipe'
    if (source/'.git').exists() and version=='1.5.0':
        recipe=root/f"recipe-{datetime.now():%Y%m%d-%H%M%S}"
        export_recipe(source,recipe)
    config=json.loads((recipe/'recipe.json').read_text())
    for name,digest in config['patches'].items():
        if sha(recipe/name)!=digest:
            raise BuildError('DIY 配方文件摘要不一致，已停止。')
    shared=api('rustdesk/contents/libs/hbb_common?ref='+latest['commit'])
    if shared.get('submodule_git_url','').rstrip('/') not in ('https://github.com/rustdesk/hbb_common','https://github.com/rustdesk/hbb_common.git'):
        raise BuildError('官方公共库地址已变化，需要检查兼容性。')
    hbb_archive=download('https://codeload.github.com/rustdesk/hbb_common/zip/'+shared['sha'],root/f"common-{shared['sha']}.zip",report)
    # GitHub archive represents the empty submodule as a directory.
    hbb=job/'libs/hbb_common'
    if hbb.exists() and not any(hbb.iterdir()):
        hbb.rmdir()
    unpack_github(hbb_archive,hbb)
    try:
        for repository,patch in [(job,recipe/'nnu-main.patch'),(hbb,recipe/'nnu-common.patch')]:
            runner.run(['git','apply','--check','--ignore-space-change',patch],repository)
            runner.run(['git','apply','--ignore-space-change',patch],repository)
    except Exception as exc:
        (job/'NNU-兼容检查未通过.txt').write_text('DIY 补丁与官方源码存在冲突；当前源码和线上版本未更改。',encoding='utf-8')
        raise BuildError('官方新版与 DIY 配方存在冲突，已保留原有源码。请查看日志；不要使用不完整源码构建。') from exc
    for directory in ('res/nnu','docs'):
        for path,relative in source_files(source/directory):
            destination=job/directory/relative;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,destination)
    secure_dependencies(job, runner)
    existing=read_version(source)
    version_path=job/VERSION_FILE
    text=version_path.read_text(encoding='utf-8')
    text=re.sub(r'^const nnuClientBuild = \d+;$',f'const nnuClientBuild = {existing[0]};',text,flags=re.M)
    version_path.write_text(text,encoding='utf-8')
    ffi=(job/'src/flutter_ffi.rs').read_bytes().replace(b'\r\n',b'\n')
    compatible=ffi==(recipe/'flutter_ffi.rs.base').read_bytes().replace(b'\r\n',b'\n')
    if compatible:
        for relative in ('src/bridge_generated.rs','src/bridge_generated.io.rs',
                         'flutter/lib/generated_bridge.dart','flutter/lib/generated_bridge.freezed.dart',
                         'flutter/macos/Runner/bridge_generated.h','flutter/ios/Runner/bridge_generated.h'):
            if not (source/relative).is_file():
                raise BuildError('本机缺少桥接文件，请先补全环境。')
            (job/relative).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source/relative,job/relative)
    else:
        workflow=(job/'.github/workflows/bridge.yml').read_text(encoding='utf-8')
        bridge=re.search(r'FLUTTER_RUST_BRIDGE_VERSION:\s*"([^"]+)"',workflow)
        if not bridge or bridge[1]!='1.80.1':
            raise BuildError('官方桥接工具版本已变更，需要更新兼容配方；原源码保持不变。')
        report('phase',(3,'生成新版 Flutter/Rust 桥接'))
        runner.run(['rustup','component','add','rustfmt','--toolchain','1.75.0'],job)
        runner.run(['cargo','install','cargo-expand','--version','1.0.95','--locked'],job)
        runner.run(['cargo','install','flutter_rust_bridge_codegen','--version','1.80.1','--features','uuid','--locked'],job)
        runner.run([Path(settings.tools)/'flutter/bin/flutter.bat','pub','get'],job/'flutter',allow_symlink=True)
        runner.run(['flutter_rust_bridge_codegen','--rust-input','./src/flutter_ffi.rs','--dart-output','./flutter/lib/generated_bridge.dart',
                    '--c-output','./flutter/macos/Runner/bridge_generated.h'],job)
        shutil.copy2(job/'flutter/macos/Runner/bridge_generated.h',job/'flutter/ios/Runner/bridge_generated.h')
    report('phase',(4,'验证 DIY 配置和界面回归'))
    required={'src/nnu.rs':['https://rd.nnu.cn','allow-auto-update','NNU_PORTABLE_PASSWORD','nnu-auto-update'],
              'src/nnu_update.rs':['https://rd.nnu.cn/client-updates/','verify_release','user_is_idle'],
              'libs/hbb_common/src/config.rs':['rd.nnu.cn','22222'],
              'flutter/lib/desktop/widgets/nnu_update_service.dart':['https://rd.nnu.cn/client-updates/', '1umorhoB3pej9Cu4Jlvi/n1JHPdLd6XxcdxDSFaWYGQ='],
              'flutter/lib/desktop/widgets/nnu_support.dart':['nnu.cn','admin@nnu.cn']}
    for name,values in required.items():
        content=(job/name).read_text(encoding='utf-8')
        if any(value not in content for value in values):
            raise BuildError('DIY 配置校验未通过：'+name)
    flutter=Path(settings.tools)/'flutter/bin/flutter.bat'
    runner.run([flutter,'pub','get'],job/'flutter',allow_symlink=True)
    runner.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',source/'res/nnu/release-assistant/prepare-junctions.ps1','-BuildRoot',job],job)
    runner.run([flutter,'pub','get','--offline'],job/'flutter')
    runner.run([flutter,'test','test/nnu_support_test.dart','test/nnu_update_test.dart','test/nnu_action_button_test.dart','test/nnu_auto_update_test.dart'],job/'flutter')
    result={**latest,'source':str(job),'patch_base':config['base'],'compatible_bridge_reused':compatible}
    (job/'NNU-UPSTREAM.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    report('upstream_ready',result)
    return result
