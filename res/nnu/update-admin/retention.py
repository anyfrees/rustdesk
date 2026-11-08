"""Keep the current and one previous published version for each platform."""
import re
import shutil
from urllib.parse import urlsplit
import platform_release
import release


def prune(db, event, public, state, lock):
    removed, failed = [], []
    with lock, db() as c:
        windows = c.execute('SELECT * FROM releases ORDER BY build DESC').fetchall()
        native = c.execute('SELECT * FROM platform_releases ORDER BY build DESC').fetchall()
        keep = {r['build'] for r in [*windows, *native] if r['stage']}
        manifests = {r['build']: release.verify_manifest(r['envelope'].encode()) for r in windows}
        catalogs = {r['build']: platform_release.verify(r['envelope'].encode()) for r in native}
        for name in ('stable.json', 'stable-v2.json'):
            path = public / name
            if path.is_file():
                active = release.verify_manifest(path.read_bytes())
                keep.add(active['build'])
                older = [r['build'] for r in windows if r['published'] and r['build'] < active['build']]
                if older:
                    keep.add(max(older))
        for platform, build in c.execute('SELECT platform,build FROM platform_channels'):
            keep.add(build)
            older = [r['build'] for r in native if r['published'] and r['build'] < build
                     and any(k.startswith(platform + '-') for k in catalogs[r['build']]['artifacts'])]
            if older:
                keep.add(max(older))
        # A retained external release can refer to a local bootstrap package.
        for build in list(keep):
            for manifest in [manifests.get(build), catalogs.get(build)]:
                if not manifest:
                    continue
                for a in manifest['artifacts'].values():
                    for url in [a['url'], *a.get('mirrors', [])]:
                        u = urlsplit(url)
                        m = re.match(r'^/client-updates/releases/([0-9]+)/', u.path)
                        if u.hostname == 'rd.nnu.cn' and m:
                            keep.add(int(m[1]))
        if not keep:
            return dict(removed=[], failed=[])
        releases = public / 'releases'
        archives = state / 'platform-bundles'
        candidates = {r['build'] for r in [*windows, *native] if r['published'] and not r['stage']} - keep
        if releases.exists():
            candidates.update(int(p.name) for p in releases.iterdir()
                              if re.fullmatch('[0-9]{1,10}', p.name) and int(p.name) < min(keep))
        for build in sorted(candidates):
            target = releases / str(build)
            archive = archives / f'{build}.zip'
            try:
                if target.is_symlink() or target.resolve().parent != releases.resolve():
                    raise ValueError('发布目录路径无效')
                if archive.is_symlink() or archive.resolve().parent != archives.resolve():
                    raise ValueError('归档路径无效')
                if target.exists():
                    shutil.rmtree(target)
                archive.unlink(missing_ok=True)
                c.execute('DELETE FROM releases WHERE build=? AND stage IS NULL', (build,))
                c.execute('DELETE FROM platform_releases WHERE build=? AND stage IS NULL', (build,))
                event(c, '物理清理过期版本（保留当前及一个历史版本）', build)
                removed.append(build)
            except (OSError, ValueError):
                event(c, '过期版本物理清理失败，请检查磁盘及权限', build)
                failed.append(build)
    return dict(removed=removed, failed=failed)
