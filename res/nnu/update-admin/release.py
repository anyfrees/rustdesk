import base64
import hashlib
import json
import re
import stat
import shutil
import zipfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PUBLIC_KEY = '1umorhoB3pej9Cu4Jlvi/n1JHPdLd6XxcdxDSFaWYGQ='
MAX_PACKAGE = 512 * 1024 * 1024
MAX_BUNDLE = 2100 * 1024 * 1024
NAME = re.compile(r'[a-zA-Z0-9._-]+\.(exe|msi|zip)\Z')


def verify_manifest(raw):
    try:
        if len(raw) > 65536:
            raise ValueError()
        envelope = json.loads(raw)
        payload = base64.b64decode(envelope['payload'], validate=True)
        signature = base64.b64decode(envelope['signature'], validate=True)
        if 'certificate' in envelope:
            from delegation import certified_key
            signer = certified_key(envelope['certificate'], PUBLIC_KEY)
        else:
            signer = Ed25519PublicKey.from_public_bytes(base64.b64decode(PUBLIC_KEY))
        signer.verify(signature, payload)
        m = json.loads(payload)
        if (m['schema'] != 1 or m['channel'] != 'stable' or type(m['build']) is not int
                or not 0 < m['build'] < 2**53 or not isinstance(m['version'], str)
                or not 0 < len(m['version']) <= 80 or not isinstance(m['notes'], str)
                or len(m['notes']) > 8000 or not isinstance(m['artifacts'], dict)
                or set(m['artifacts']) != {'portable', 'install', 'msi', 'zip'}):
            raise ValueError()
        names = set()
        for a in m['artifacts'].values():
            if (not NAME.fullmatch(a['name']) or a['name'] in names
                    or not re.fullmatch(r'[a-f0-9]{64}', a['sha256'])
                    or type(a['size']) is not int or not 0 < a['size'] <= MAX_PACKAGE
                    or a['url'] != f"https://rd.nnu.cn/client-updates/releases/{m['build']}/{a['name']}"):
                raise ValueError()
            names.add(a['name'])
            mirrors = a.get('mirrors', [])
            if not isinstance(mirrors, list) or len(mirrors) > 3:
                raise ValueError()
            for url in mirrors:
                from external_download import validate_url
                validate_url(url)
        if 'certificate' in envelope and (m.get('delivery') != 'external' or any(not a.get('mirrors') for a in m['artifacts'].values())):
            raise ValueError()
        if m.get('delivery') == 'external' and ('certificate' not in envelope or any(not a.get('mirrors') for a in m['artifacts'].values())):
            raise ValueError()
        return m
    except Exception as exc:
        raise ValueError('清单签名无效或格式不符合客户端协议') from exc


def check_files(directory, manifest):
    for a in manifest['artifacts'].values():
        path = directory / a['name']
        if not path.is_file() or path.is_symlink() or path.stat().st_size != a['size']:
            raise ValueError(f"安装包缺失或大小错误：{a['name']}")
        with path.open('rb') as f:
            digest = hashlib.file_digest(f, 'sha256').hexdigest()
        if digest != a['sha256']:
            raise ValueError(f"SHA-256 校验失败：{a['name']}")


def unpack_bundle(archive, directory):
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist()
        if len(infos) > 32 or sum(i.file_size for i in infos) > MAX_BUNDLE:
            raise ValueError('发布包过大或文件数量过多')
        if shutil.disk_usage(directory.parent).free < sum(i.file_size for i in infos) + 512 * 1024 * 1024:
            raise ValueError('服务器空间不足，无法解压发布包')
        seen = set()
        for i in infos:
            p = Path(i.filename)
            if (i.filename in seen or '\\' in i.filename or p.is_absolute()
                    or '..' in p.parts or ':' in i.filename
                    or stat.S_ISLNK(i.external_attr >> 16) or i.flag_bits & 1):
                raise ValueError('发布包包含不安全路径或重复文件')
            seen.add(i.filename)
        if 'stable.json' not in seen or z.getinfo('stable.json').file_size > 65536:
            raise ValueError('发布包根目录缺少 stable.json')
        raw = z.read('stable.json')
        manifest = verify_manifest(raw)
        if manifest.get('delivery') == 'external':
            raise ValueError('外链版本请使用外部地址发布，不能作为本地 ZIP 安装包导入')
        prefix = f"releases/{manifest['build']}/"
        expected = {prefix + a['name']: a for a in manifest['artifacts'].values()}
        # Auxiliary source and build notes from the old publisher are accepted but never extracted.
        extras = {prefix + n for n in ('RustDesk-NNU-1.5.0-Source.zip', 'SHA256SUMS.txt', 'README.md', 'BUILD-INFO.json')}
        if any(not i.is_dir() and i.filename not in expected.keys() | extras | {'stable.json'} for i in infos):
            raise ValueError('发布包含有清单之外的文件')
        directory.mkdir()
        for name, a in expected.items():
            if name not in seen or z.getinfo(name).file_size != a['size']:
                raise ValueError(f"安装包缺失或大小错误：{a['name']}")
            digest = hashlib.sha256()
            count = 0
            with z.open(name) as src, (directory / a['name']).open('wb') as dst:
                while chunk := src.read(1024 * 1024):
                    count += len(chunk)
                    if count > a['size']:
                        raise ValueError('解压大小超出清单')
                    digest.update(chunk)
                    dst.write(chunk)
            if count != a['size'] or digest.hexdigest() != a['sha256']:
                raise ValueError(f"SHA-256 校验失败：{a['name']}")
        return raw, manifest
