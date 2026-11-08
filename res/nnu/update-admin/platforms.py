"""Authenticated platform import/publish/history and public signed update feeds."""
import json
import os
import secrets
import shutil
import time
from flask import Response, jsonify, request, send_file
import platform_release as catalog
import release
from retention import prune


def register_platforms(app, db, event, base, public, state, staging, lock, atomic, current, publish_windows):
    archives = state / 'platform-bundles'
    archives.mkdir(exist_ok=True)

    def pending_bundle(stage):
        private = archives / f'pending-{stage}.zip'
        return private if private.is_file() else staging / stage / 'bundle.zip'
    with db() as c:
        c.executescript('''CREATE TABLE IF NOT EXISTS platform_releases(
          build INTEGER PRIMARY KEY,envelope TEXT NOT NULL,imported REAL NOT NULL,published REAL,stage TEXT,windows_stage TEXT);
          CREATE TABLE IF NOT EXISTS platform_channels(platform TEXT PRIMARY KEY,build INTEGER NOT NULL);''')

    @app.get(base + '/api/platforms', endpoint='platform_overview')
    def overview():
        with db() as c:
            rows = c.execute('SELECT * FROM platform_releases ORDER BY build DESC').fetchall()
            channels = dict(c.execute('SELECT platform,build FROM platform_channels').fetchall())
        return jsonify(current=channels, releases=[dict(manifest=catalog.verify(r['envelope'].encode()),
            imported=r['imported'], published=r['published'], pending=bool(r['stage'])) for r in rows])

    @app.get(base + '/platforms/<platform>/stable.json', endpoint='platform_feed')
    def feed(platform):
        if platform not in ('android', 'linux'):
            return Response(status=404)
        if (state / 'paused').exists():
            return Response(status=204)
        with db() as c:
            row = c.execute('SELECT r.envelope FROM platform_releases r JOIN platform_channels p ON r.build=p.build WHERE p.platform=?', (platform,)).fetchone()
        return Response(row['envelope'], mimetype='application/json') if row else Response(status=404)

    @app.post(base + '/api/platforms/import')
    def import_platforms():
        if request.mimetype != 'application/zip':
            raise ValueError('请选择多平台发布包 ZIP')
        if not lock.acquire(blocking=False):
            return jsonify(error='另一项发布操作正在进行'), 409
        job = staging / secrets.token_hex(16)
        incoming = archives / f'pending-{job.name}.zip'
        winjob = None
        job.mkdir()
        try:
            with db() as c:
                if c.execute('SELECT count(*) FROM platform_releases WHERE stage IS NOT NULL').fetchone()[0] >= 3:
                    raise ValueError('最多保留 3 个待发布多平台版本')
            size = 0
            with incoming.open('xb') as f:
                while chunk := request.stream.read(1024**2):
                    size += len(chunk)
                    if size > release.MAX_BUNDLE or shutil.disk_usage(state).free < 768 * 1024**2:
                        raise ValueError('发布包过大或空间不足')
                    f.write(chunk)
                f.flush()
                os.fsync(f.fileno())
            incoming.chmod(0o600)
            if shutil.disk_usage(staging).free < size + 512 * 1024**2:
                raise ValueError('服务器空间不足，无法验证发布包')
            raw, m = catalog.unpack(incoming, job / 'files')
            build = m['build']
            winraw = winmanifest = None
            if m.get('windows'):
                winraw, winmanifest = release.unpack_bundle(job / 'files/windows-update.zip', job / 'windows')
                if winmanifest['build'] != build or winmanifest['version'] != m['version']:
                    raise ValueError('Windows 与多平台版本不一致')
            with db() as c:
                old = c.execute('SELECT * FROM platform_releases WHERE build=?', (build,)).fetchone()
                if old:
                    if catalog.verify(old['envelope'].encode()) != m:
                        raise ValueError('相同构建号已登记，不能覆盖')
                    return jsonify(manifest=m, existing=True)
                if winmanifest:
                    existing = c.execute('SELECT * FROM releases WHERE build=?', (build,)).fetchone()
                    if existing and release.verify_manifest(existing['envelope'].encode()) != winmanifest:
                        raise ValueError('同号 Windows 版本内容不同')
                    active = current()
                    if not existing and build > (active['build'] if active else 0):
                        if c.execute('SELECT count(*) FROM releases WHERE stage IS NOT NULL').fetchone()[0] >= 3:
                            raise ValueError('Windows 待发布版本已满')
                        winjob = staging / secrets.token_hex(16)
                        winjob.mkdir()
                        os.rename(job / 'windows', winjob / 'release')
                        c.execute('INSERT INTO releases VALUES(?,?,?,?,?)', (build, winraw.decode(), time.time(), None, winjob.name))
                c.execute('INSERT INTO platform_releases VALUES(?,?,?,?,?,?)',
                    (build, raw.decode(), time.time(), None, job.name, winjob.name if winjob else None))
                event(c, '导入并验证多平台发布包', build)
            job = winjob = incoming = None
            return jsonify(manifest=m, existing=False)
        finally:
            if job:
                shutil.rmtree(job)
            if winjob:
                shutil.rmtree(winjob)
            if incoming:
                incoming.unlink(missing_ok=True)
            lock.release()

    @app.post(base + '/api/platforms/publish/<int:build>', endpoint='platform_publish')
    def publish(build):
        with lock:
            return publish_locked(build)

    def publish_locked(build):
        # Preflight every native package before allowing the existing Windows publisher to run.
        with lock, db() as c:
            row = c.execute('SELECT * FROM platform_releases WHERE build=?', (build,)).fetchone()
            if not row:
                raise ValueError('多平台版本不存在')
            m = catalog.verify(row['envelope'].encode())
            groups = {key.split('-')[0] for key in m['artifacts']}
            for group in groups:
                active = c.execute('SELECT build FROM platform_channels WHERE platform=?', (group,)).fetchone()
                if active and active['build'] > build:
                    raise ValueError('不能回退平台版本')
            job = staging / row['stage'] if row['stage'] else None
            if job and pending_bundle(row['stage']).parent != archives and not (archives / f'{build}.zip').exists() and shutil.disk_usage(state).free < pending_bundle(row['stage']).stat().st_size + 128 * 1024**2:
                raise ValueError('服务器空间不足，无法归档发布包')
            for a in catalog.files(m):
                source = job / 'files' / a['path'] if job else public / 'releases' / str(build) / a['path']
                if not source.is_file():
                    source = public / 'releases' / str(build) / a['path']
                catalog.check(source, a)
            windows = current()
            update_windows = bool(m.get('windows') and build > (windows['build'] if windows else 0))
        if update_windows:
            publish_windows(build)
        with lock, db() as c:
            # Recheck monotonic channels after the Windows operation released its own lock.
            for group in groups:
                active = c.execute('SELECT build FROM platform_channels WHERE platform=?', (group,)).fetchone()
                if active and active['build'] > build:
                    raise ValueError('平台已有更新版本，请刷新')
            target = public / 'releases' / str(build)
            target.mkdir(parents=True, exist_ok=True)
            for a in catalog.files(m):
                destination = target / a['path']
                if destination.exists():
                    catalog.check(destination, a)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    os.rename(job / 'files' / a['path'], destination)
            if job:
                archive = archives / f'{build}.zip'
                if not archive.exists():
                    incoming = pending_bundle(row['stage'])
                    if incoming.parent == archives:
                        os.replace(incoming, archive)
                    else:
                        temporary = archives / (str(build) + '.' + secrets.token_hex(8) + '.tmp')
                        try:
                            with incoming.open('rb') as source, temporary.open('xb') as destination:
                                shutil.copyfileobj(source, destination, 1024**2)
                                destination.flush()
                                os.fsync(destination.fileno())
                            temporary.chmod(0o600)
                            os.replace(temporary, archive)
                        finally:
                            temporary.unlink(missing_ok=True)
            for group in groups:
                c.execute('INSERT OR REPLACE INTO platform_channels VALUES(?,?)', (group, build))
            c.execute('UPDATE platform_releases SET published=?,stage=NULL WHERE build=?', (time.time(), build))
            event(c, '发布多平台客户端', build)
        if job:
            shutil.rmtree(job)
        cleanup = prune(db, event, public, state, lock)
        return jsonify(ok=True, windows_published=update_windows, cleanup=cleanup)

    @app.get(base + '/api/platforms/bundle/<int:build>')
    def download_bundle(build):
        with db() as c:
            row = c.execute('SELECT stage FROM platform_releases WHERE build=?', (build,)).fetchone()
        if not row:
            return Response(status=404)
        path = pending_bundle(row['stage']) if row['stage'] else archives / f'{build}.zip'
        return send_file(path, as_attachment=True, download_name=f'NNU-{build}-Platform-Release.zip')

    @app.post(base + '/api/platforms/discard/<int:build>', endpoint='platform_discard')
    def discard(build):
        with lock, db() as c:
            row = c.execute('SELECT * FROM platform_releases WHERE build=?', (build,)).fetchone()
            if not row or not row['stage']:
                raise ValueError('只能移除待发布多平台版本')
            shutil.rmtree(staging / row['stage'])
            (archives / f"pending-{row['stage']}.zip").unlink(missing_ok=True)
            if row['windows_stage']:
                win = c.execute('SELECT stage FROM releases WHERE build=?', (build,)).fetchone()
                if win and win['stage'] == row['windows_stage']:
                    shutil.rmtree(staging / win['stage'])
                    c.execute('DELETE FROM releases WHERE build=?', (build,))
            c.execute('DELETE FROM platform_releases WHERE build=?', (build,))
            event(c, '移除待发布多平台版本', build)
        return jsonify(ok=True)
