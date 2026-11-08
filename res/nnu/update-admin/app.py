import hashlib
import json
import os
import re
import secrets
import shutil
import sqlite3
import threading
import time
import zipfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

from flask import Flask, jsonify, request, session, send_from_directory, Response
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix

from accounts import AccountAuth
from announcements import register_announcements
from platforms import register_platforms
from retention import prune
from download_portal import DownloadPortal
from release import verify_manifest, check_files, unpack_bundle, MAX_BUNDLE, PUBLIC_KEY
from delegation import ExternalSigner
from external_download import inspect_download

STATE = Path(os.environ.get('NNU_STATE', '/state'))
PUBLIC = Path(os.environ.get('NNU_PUBLIC', '/public'))
CREDENTIALS = json.loads(Path(os.environ.get('NNU_CREDENTIALS', '/run/credentials.json')).read_text())
ORIGIN = os.environ.get('NNU_ORIGIN', 'https://rd.nnu.cn')
LOG = Path(os.environ.get('NNU_LOG', '/logs/access.log'))
BASE = '/update-admin'
STATE.mkdir(parents=True, exist_ok=True)
STAGING = PUBLIC / '.admin-staging'
STAGING.mkdir(exist_ok=True)
LOCK = threading.RLock()
STATS_LOCK = threading.Lock()
app = Flask(__name__, static_url_path=BASE + '/assets', static_folder='static')
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)
app.config.update(SECRET_KEY=CREDENTIALS['session_secret'], MAX_CONTENT_LENGTH=MAX_BUNDLE,
                  SESSION_COOKIE_NAME='nnu_admin', SESSION_COOKIE_PATH=BASE,
                  SESSION_COOKIE_SECURE=ORIGIN.startswith('https:'), SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE='Strict', PERMANENT_SESSION_LIFETIME=timedelta(hours=12))
app.config['TRUSTED_HOSTS'] = [urlsplit(ORIGIN).hostname, '127.0.0.1', 'localhost'] + [
    host.strip() for host in os.environ.get('NNU_HOST_ALIASES', '').split(',') if host.strip()]


@contextmanager
def db():
    connection = sqlite3.connect(STATE / 'admin.sqlite', timeout=30)
    connection.row_factory = sqlite3.Row
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


with db() as c:
    c.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS releases(build INTEGER PRIMARY KEY, envelope TEXT NOT NULL,
          imported REAL NOT NULL, published REAL, stage TEXT);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, at REAL, action TEXT, build INTEGER);
        CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY, count INTEGER, until REAL);
        CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, expires REAL);
        CREATE TABLE IF NOT EXISTS counters(day TEXT, kind TEXT, requests INTEGER, bytes INTEGER,
          PRIMARY KEY(day,kind));
        CREATE TABLE IF NOT EXISTS offsets(inode TEXT PRIMARY KEY, offset INTEGER);
    ''')


def current():
    path = PUBLIC / 'stable-v2.json' if (PUBLIC / 'stable-v2.json').exists() else PUBLIC / 'stable.json'
    return verify_manifest(path.read_bytes()) if path.exists() else None


def atomic(path, content):
    temp = path.with_name(path.name + '.next')
    with temp.open('wb') as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp, 0o644)
    os.replace(temp, path)


def event(c, action, build=None):
    c.execute('INSERT INTO events(at,action,build) VALUES(?,?,?)', (time.time(), action, build))


account_auth = AccountAuth(app, db, event, CREDENTIALS, ORIGIN, BASE)
external_signer = ExternalSigner(STATE)
os.chmod(STATE, 0o700)
os.chmod(STATE / 'admin.sqlite', 0o600)


def authenticated():
    return account_auth.authenticated()

register_announcements(app, db, event, BASE)

@app.before_request
def protect():
    if not request.path.startswith(BASE + '/api/'):
        return
    if request.path not in (BASE + '/api/import', BASE + '/api/platforms/import'):
        request.max_content_length = 65536
    if request.method != 'GET':
        if request.headers.get('Origin') not in (None, ORIGIN):
            return jsonify(error='请求来源不正确'), 403
        token = request.headers.get('X-CSRF-Token', '')
        if not token or not token.isascii() or not secrets.compare_digest(token, session.get('csrf', '')):
            return jsonify(error='页面已过期，请刷新后重试'), 403
    if request.path not in account_auth.public_paths and not authenticated():
        return jsonify(error='请先登录'), 401


@app.after_request
def headers(response):
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'same-origin'
    response.headers.setdefault('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
    return response


@app.errorhandler(Exception)
def errors(exc):
    if isinstance(exc, HTTPException):
        return jsonify(error=('发布包过大' if request.path == BASE + '/api/import' else '请求内容过大') if exc.code == 413 else exc.description if exc.code == 429 else '请求无法处理'), exc.code
    if isinstance(exc, (ValueError, zipfile.BadZipFile, KeyError)):
        return jsonify(error=str(exc) if isinstance(exc, ValueError) else '发布包格式不正确'), 400
    app.logger.exception('Request failed')
    return jsonify(error='操作失败，请重试或检查服务器日志'), 500


@app.get('/healthz')
def health():
    return 'ok\n'


@app.get('/feed')
def feed():
    if (STATE / 'paused').exists():
        return Response(status=204)
    path = PUBLIC / 'stable-v2.json' if request.args.get('protocol') == '2' and (PUBLIC / 'stable-v2.json').exists() else PUBLIC / 'stable.json'
    return Response(path.read_bytes(), mimetype='application/json') if path.exists() else Response(status=404)


@app.get(BASE + '/')
def index():
    return send_from_directory('static', 'index.html')


@app.get(BASE + '/api/session')
def session_info():
    session.setdefault('csrf', secrets.token_urlsafe(32))
    return jsonify(csrf=session['csrf'], authenticated=authenticated(), username=account_auth.account()['username'] if authenticated() else None)


@app.post(BASE + '/api/login')
def login():
    return account_auth.login()

@app.post(BASE + '/api/logout')
def logout():
    with db() as c:
        c.execute('DELETE FROM sessions WHERE id=?', (hashlib.sha256(session['sid'].encode()).hexdigest(),))
    session.clear()
    return jsonify(ok=True)


def ingest_stats():
    if not LOG.exists():
        return False
    with STATS_LOCK, db() as c, LOG.open('rb') as f:
        stat = os.fstat(f.fileno())
        inode = f'{stat.st_dev}:{stat.st_ino}'
        row = c.execute('SELECT offset FROM offsets WHERE inode=?', (inode,)).fetchone()
        offset = row[0] if row and row[0] <= stat.st_size else 0
        # Bound each refresh; the next refresh continues from the saved cursor.
        f.seek(offset)
        end = offset + 32 * 1024 * 1024
        while f.tell() < end:
            line = f.readline()
            if not line:
                break
            if not line.endswith(b'\n'):
                f.seek(-len(line), 1)
                break
            m = re.search(rb'\[([^\]]+)\] "GET /client-updates/releases/\d+/([^ ?]+)(?:\?[^ ]*)? HTTP/[^\"]+" (200|206) (\d+)', line)
            if not m:
                continue
            name = m[2].decode('ascii', 'ignore')
            kind = next((k for k in ('portable', 'install', 'msi', 'zip') if re.search(r'-' + k + r'\.(exe|msi|zip)$', name)), None)
            if not kind:
                continue
            day = datetime.strptime(m[1].decode(), '%d/%b/%Y:%H:%M:%S %z').astimezone(timezone(timedelta(hours=8))).date().isoformat()
            c.execute('INSERT INTO counters VALUES(?,?,1,?) ON CONFLICT(day,kind) DO UPDATE SET requests=requests+1,bytes=bytes+excluded.bytes', (day, kind, int(m[4])))
        c.execute('INSERT OR REPLACE INTO offsets VALUES(?,?)', (inode, f.tell()))
    return True


def stats_state():
    if not LOG.exists():
        return False, False
    stat = LOG.stat()
    with db() as c:
        row = c.execute('SELECT offset FROM offsets WHERE inode=?', (f'{stat.st_dev}:{stat.st_ino}',)).fetchone()
    return True, not row or row[0] + 1024 * 1024 < stat.st_size


def collect_stats():
    while True:
        pending = False
        try:
            ingest_stats()
            _, pending = stats_state()
        except Exception:
            app.logger.exception('Access log aggregation failed')
        time.sleep(0.25 if pending else 30)


@app.get(BASE + '/api/overview')
def overview():
    available, pending = stats_state()
    today = datetime.now(timezone(timedelta(hours=8))).date()
    since = (today - timedelta(days=6)).isoformat()
    active = current()
    with db() as c:
        rows = c.execute('SELECT * FROM releases ORDER BY build DESC').fetchall()
        releases = [dict(manifest=verify_manifest(r['envelope'].encode()), imported=r['imported'], published=r['published'], pending=bool(r['stage'])) for r in rows]
        stats = [dict(r) for r in c.execute('SELECT * FROM counters WHERE day>=? ORDER BY day', (since,))]
        events = [dict(r) for r in c.execute('SELECT * FROM events ORDER BY id DESC LIMIT 12')]
    next_build = max(int(today.strftime('%Y%m%d')) * 100 + 1, max([r['manifest']['build'] for r in releases] + [0]) + 1)
    return jsonify(current=active, paused=(STATE / 'paused').exists(), releases=releases, next_build=next_build,
                   external_ready=external_signer.ready(PUBLIC_KEY),
                   stats=stats, stats_available=available, stats_pending=pending, events=events)


@app.post(BASE + '/api/import')
def import_release():
    if request.mimetype != 'application/zip':
        raise ValueError('请选择 ZIP 发布包')
    if not LOCK.acquire(blocking=False):
        return jsonify(error='另一项发布操作正在进行，请稍后重试'), 409
    job = STAGING / secrets.token_hex(16)
    job.mkdir()
    try:
        with db() as c:
            if c.execute('SELECT count(*) FROM releases WHERE stage IS NOT NULL').fetchone()[0] >= 3:
                raise ValueError('最多保留 3 个待发布版本，请先发布或移除')
        size = 0
        with (job / 'bundle.zip').open('wb') as f:
            while chunk := request.stream.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_BUNDLE or shutil.disk_usage(STATE).free < 768 * 1024 * 1024:
                    raise ValueError('发布包过大或服务器空间不足')
                f.write(chunk)
        raw, manifest = unpack_bundle(job / 'bundle.zip', job / 'release')
        (job / 'bundle.zip').unlink()
        build = manifest['build']
        target = PUBLIC / 'releases' / str(build)
        if target.exists():
            check_files(target, manifest)
        with db() as c:
            old = c.execute('SELECT * FROM releases WHERE build=?', (build,)).fetchone()
            if old:
                if verify_manifest(old['envelope'].encode()) != manifest:
                    raise ValueError('相同构建号已存在，不能覆盖')
                return jsonify(manifest=manifest, existing=True)
            c.execute('INSERT INTO releases VALUES(?,?,?,?,?)', (build, raw.decode(), time.time(), None, job.name))
            event(c, '导入并验证', build)
        job = None
        return jsonify(manifest=manifest, existing=False)
    finally:
        if job:
            shutil.rmtree(job)
        LOCK.release()


@app.post(BASE + '/api/external')
def prepare_external():
    data = request.get_json() or {}
    build, version, notes, urls = data.get('build'), data.get('version'), data.get('notes', ''), data.get('urls')
    kinds = {'portable': 'exe', 'install': 'exe', 'msi': 'msi', 'zip': 'zip'}
    if (type(build) is not int or not 0 < build < 2**53 or not isinstance(version, str)
            or not 0 < len(version.strip()) <= 80 or not version.isprintable()
            or not isinstance(notes, str) or len(notes) > 8000 or not isinstance(urls, dict) or set(urls) != set(kinds)):
        raise ValueError('请填写版本、递增构建号和四类安装包的下载地址')
    if not external_signer.ready(PUBLIC_KEY):
        raise ValueError('外链发布签名尚未启用，请先完成可信发布配置')
    if not LOCK.acquire(blocking=False):
        return jsonify(error='另一项发布操作正在进行，请稍后重试'), 409
    job = STAGING / secrets.token_hex(16)
    try:
        with db() as c:
            if c.execute('SELECT 1 FROM releases WHERE build=?', (build,)).fetchone():
                raise ValueError('构建号已存在，请使用下一个构建号')
            if c.execute('SELECT count(*) FROM releases WHERE stage IS NOT NULL').fetchone()[0] >= 3:
                raise ValueError('最多保留 3 个待发布版本，请先发布或移除')
        active = current()
        if active and build <= active['build']:
            raise ValueError('构建号必须大于当前发布版本')
        artifacts = {}
        for kind, extension in kinds.items():
            try:
                artifact = inspect_download(urls[kind], kind)
            except ValueError as exc:
                raise ValueError(f'{dict(portable="便携版 EXE", install="安装版 EXE", msi="MSI", zip="ZIP")[kind]}：{exc}') from exc
            name = f'RustDesk-NNU-{build}-x64-{kind}.{extension}'
            artifacts[kind] = dict(artifact, name=name, url=f'https://rd.nnu.cn/client-updates/releases/{build}/{name}')
        manifest = dict(schema=1, channel='stable', build=build, version=version.strip(), notes=notes,
                        delivery='external', artifacts=artifacts)
        raw = external_signer.sign(manifest, PUBLIC_KEY)
        verify_manifest(raw)
        job.mkdir()
        (job / 'external.json').write_bytes(raw)
        with db() as c:
            c.execute('INSERT INTO releases VALUES(?,?,?,?,?)', (build, raw.decode(), time.time(), None, job.name))
            event(c, '校验外链并签名', build)
        job = None
        return jsonify(manifest=manifest, existing=False)
    finally:
        if job and job.exists():
            shutil.rmtree(job)
        LOCK.release()


@app.post(BASE + '/api/publish/<int:build>')
def publish(build):
    with LOCK, db() as c:
        row = c.execute('SELECT * FROM releases WHERE build=?', (build,)).fetchone()
        if not row:
            raise ValueError('版本不存在')
        raw = row['envelope'].encode()
        manifest = verify_manifest(raw)
        active = current()
        if active and build <= active['build']:
            raise ValueError('只能发布构建号更大的版本')
        if manifest.get('delivery') == 'external':
            if not (PUBLIC / 'stable.json').exists():
                raise ValueError('请先发布兼容外链的本地客户端版本，供旧客户端升级')
            if not row['stage'] or not (STAGING / row['stage'] / 'external.json').is_file():
                raise ValueError('待发布的外链校验记录不存在，请重新校验')
            atomic(PUBLIC / 'stable-v2.json', raw)
        else:
            target = PUBLIC / 'releases' / str(build)
            if target.exists():
                check_files(target, manifest)
            else:
                if not row['stage']:
                    raise ValueError('待发布文件不存在，请重新导入')
                source = STAGING / row['stage'] / 'release'
                check_files(source, manifest)
                # Both mounts are on the same host filesystem. A completed directory is visible at once.
                os.rename(source, target)
            atomic(PUBLIC / 'stable.json', raw)
            (PUBLIC / 'stable-v2.json').unlink(missing_ok=True)
        c.execute('UPDATE releases SET published=?,stage=NULL WHERE build=?', (time.time(), build))
        event(c, '发布', build)
        if row['stage']:
            shutil.rmtree(STAGING / row['stage'])
    cleanup = prune(db, event, PUBLIC, STATE, LOCK)
    return jsonify(ok=True, cleanup=cleanup)


@app.post(BASE + '/api/discard/<int:build>')
def discard(build):
    with LOCK, db() as c:
        row = c.execute('SELECT * FROM releases WHERE build=?', (build,)).fetchone()
        if not row or not row['stage']:
            raise ValueError('只能移除待发布版本')
        active = current()
        if active and active['build'] == build:
            raise ValueError('当前版本不能移除')
        shutil.rmtree(STAGING / row['stage'], ignore_errors=False)
        c.execute('DELETE FROM releases WHERE build=?', (build,))
        event(c, '移除待发布版本', build)
    return jsonify(ok=True)


@app.post(BASE + '/api/push')
def push():
    data = request.get_json() or {}
    if type(data.get('paused')) is not bool:
        raise ValueError('参数错误')
    with LOCK, db() as c:
        path = STATE / 'paused'
        if data['paused']:
            atomic(path, b'paused\n')
        else:
            path.unlink(missing_ok=True)
        event(c, '暂停推送' if data['paused'] else '恢复推送')
    return jsonify(ok=True)


def bootstrap():
    active = current()
    if active:
        with db() as c:
            row = c.execute('SELECT 1 FROM releases WHERE build=?', (active['build'],)).fetchone()
            if not row:
                path = PUBLIC / ('stable-v2.json' if active.get('delivery') == 'external' else 'stable.json')
                if active.get('delivery') != 'external':
                    check_files(PUBLIC / 'releases' / str(active['build']), active)
                c.execute('INSERT INTO releases VALUES(?,?,?,?,NULL)', (active['build'], path.read_text(), time.time(), path.stat().st_mtime))


register_platforms(app, db, event, BASE, PUBLIC, STATE, STAGING, LOCK, atomic, current, publish)
download_portal = DownloadPortal(app, db, event, STATE, PUBLIC, LOCK, atomic, account_auth, ORIGIN)
from login_guard import LoginGuard
login_guard = LoginGuard(app, db, event, account_auth, download_portal)
from mobile_import import MobileImport
mobile_import = MobileImport(app, download_portal, STATE, ORIGIN)
bootstrap()
if os.environ.get('NNU_STATS_WORKER', '1') == '1':
    threading.Thread(target=collect_stats, name='access-log-collector', daemon=True).start()

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=32171, threaded=True)
