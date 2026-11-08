"""Signed Android/Linux release bundles, separate from the Windows update protocol."""
import base64
import hashlib
import json
from pathlib import PurePosixPath
import re
import shutil
import stat
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
import release

KINDS = {
    'android-arm64': ('Android', 'arm64-v8a', 'apk'),
    'android-armv7': ('Android', 'armeabi-v7a', 'apk'),
    'android-x64': ('Android', 'x86_64', 'apk'),
    'android-universal': ('Android', 'universal', 'apk'),
    'android-aab': ('Android', 'release', 'aab'),
    'linux-deb': ('Linux', 'x86_64', 'deb'),
    'linux-rpm': ('Linux', 'x86_64', 'rpm'),
    'linux-appimage': ('Linux', 'x86_64', 'AppImage'),
    'linux-tar': ('Linux', 'x86_64', 'tar.gz'),
}
MAX_CATALOG = 131072


def verify(raw):
    try:
        if len(raw) > MAX_CATALOG:
            raise ValueError()
        envelope = json.loads(raw)
        payload = base64.b64decode(envelope['payload'], validate=True)
        Ed25519PublicKey.from_public_bytes(base64.b64decode(release.PUBLIC_KEY)).verify(
            base64.b64decode(envelope['signature'], validate=True), payload)
        m = json.loads(payload)
        if (m['schema'] != 1 or m['type'] != 'nnu-platform-release' or type(m['build']) is not int
                or not 0 < m['build'] <= 2100000000 or not isinstance(m['version'], str)
                or not 0 < len(m['version']) <= 80 or not isinstance(m['notes'], str)
                or len(m['notes']) > 8000 or not isinstance(m['artifacts'], dict)
                or not m['artifacts'] or not set(m['artifacts']) <= KINDS.keys()):
            raise ValueError()
        for key, a in m['artifacts'].items():
            folder, arch, ext = KINDS[key]
            expected = (f"RustDesk-NNU-{m['build']}-android-{arch}.{ext}" if folder == 'Android'
                        else f"RustDesk-NNU-{m['build']}-linux-x86_64.{ext}")
            if a['name'] != expected or a['path'] != f'{folder}/{expected}':
                raise ValueError()
            if a['url'] != f"https://rd.nnu.cn/client-updates/releases/{m['build']}/{a['path']}":
                raise ValueError()
            valid_file(a, 512 * 1024**2)
        for folder in ('android', 'linux'):
            selected = {k for k in m['artifacts'] if k.startswith(folder + '-')}
            if selected and selected != {k for k in KINDS if k.startswith(folder + '-')}:
                raise ValueError()
        for name, a in m.get('sources', {}).items():
            if name not in ('Windows', 'CrossPlatform') or a['path'] != f'Sources/RustDesk-NNU-{name}-Source.zip':
                raise ValueError()
            valid_file(a, 128 * 1024**2)
        if m.get('windows') is not None:
            if m['windows']['path'] != 'windows-update.zip':
                raise ValueError()
            valid_file(m['windows'], release.MAX_BUNDLE)
        return m
    except Exception as exc:
        raise ValueError('多平台清单签名无效或格式不正确') from exc


def valid_file(a, maximum):
    if (type(a['size']) is not int or not 0 < a['size'] <= maximum
            or not isinstance(a['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', a['sha256'])):
        raise ValueError('文件摘要或大小无效')


def files(m):
    return list(m['artifacts'].values()) + list(m.get('sources', {}).values())


def check(path, a):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != a['size']:
        raise ValueError('安装包缺失或大小不符')
    with path.open('rb') as f:
        if hashlib.file_digest(f, 'sha256').hexdigest() != a['sha256']:
            raise ValueError('安装包 SHA256 不符')


def unpack(archive, directory):
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist()
        if len(infos) > 24 or sum(i.file_size for i in infos) > release.MAX_BUNDLE:
            raise ValueError('多平台发布包过大或文件过多')
        if shutil.disk_usage(directory.parent).free < sum(i.file_size for i in infos) + 512 * 1024**2:
            raise ValueError('服务器空间不足，无法解包')
        seen = set()
        for i in infos:
            p = PurePosixPath(i.filename)
            if (i.filename.casefold() in seen or p.is_absolute() or '..' in p.parts
                    or '\\' in i.filename or ':' in i.filename or i.flag_bits & 1
                    or stat.S_ISLNK(i.external_attr >> 16)):
                raise ValueError('发布包包含不安全路径')
            seen.add(i.filename.casefold())
        info = z.getinfo('platform-release.json')
        if info.file_size > MAX_CATALOG:
            raise ValueError('清单过大')
        raw = z.read(info)
        m = verify(raw)
        expected = {a['path']: a for a in files(m)}
        if m.get('windows'):
            expected['windows-update.zip'] = m['windows']
        if set(z.namelist()) != set(expected) | {'platform-release.json'}:
            raise ValueError('发布包文件与签名清单不一致')
        directory.mkdir()
        for name, a in expected.items():
            if z.getinfo(name).file_size != a['size']:
                raise ValueError('发布包大小与清单不符')
            target = directory / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(name) as source, target.open('xb') as out:
                digest = hashlib.sha256()
                size = 0
                while chunk := source.read(1024**2):
                    size += len(chunk)
                    if size > a['size']:
                        raise ValueError('文件大小超限')
                    out.write(chunk)
                    digest.update(chunk)
                if size != a['size'] or digest.hexdigest() != a['sha256']:
                    raise ValueError('发布包 SHA256 校验失败')
        return raw, m
