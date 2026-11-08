"""Verified public downloads with bounded admission and server-owned stream leases."""
import hashlib
import hmac
import json
import re
import secrets
import threading
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from flask import Response, jsonify, request, send_from_directory
from werkzeug.exceptions import TooManyRequests
import platform_release
import release


class DownloadPortal:
    def __init__(self, app, db, event, state, public, lock, atomic, account_auth, origin):
        self.app, self.db, self.event = app, db, event
        self.state, self.public, self.lock, self.atomic = state, public, lock, atomic
        self.auth, self.origin = account_auth, origin
        self.config_file = state / 'download-portal.json'
        self.key = app.secret_key.encode()
        self.assets = Path(__file__).parent / 'portal-static'
        self.verifiers = threading.BoundedSemaphore(2)
        with db() as c:
            c.executescript('''CREATE TABLE IF NOT EXISTS download_limits(k TEXT PRIMARY KEY,window INTEGER,n INTEGER);
              CREATE TABLE IF NOT EXISTS download_queue(id TEXT PRIMARY KEY,owner TEXT NOT NULL,ip TEXT NOT NULL,
              artifact TEXT NOT NULL,created REAL NOT NULL,touched REAL NOT NULL,status TEXT NOT NULL,
              deadline REAL,bytes INTEGER NOT NULL DEFAULT 0);''')
        app.add_url_rule('/downloads/', 'download_home', self.home)
        app.add_url_rule('/downloads/assets/<path:name>', 'download_asset', self.asset)
        app.add_url_rule('/downloads/api/catalog', 'download_catalog', self.catalog)
        app.add_url_rule('/downloads/api/join', 'download_join', self.join, methods=['POST'])
        app.add_url_rule('/downloads/api/status', 'download_status', self.status)
        app.add_url_rule('/downloads/api/cancel', 'download_cancel', self.cancel, methods=['POST'])
        app.add_url_rule('/downloads/file/<ticket>', 'download_stream', self.stream, methods=['GET'])
        app.add_url_rule('/update-admin/api/download-settings', 'download_settings', self.settings, methods=['GET','POST'])
        app.after_request(self.headers)
        app.before_request(self.body_limit)

    def body_limit(self):
        if request.path.startswith('/downloads/api/'):
            request.max_content_length=8192
            if request.method=='POST' and request.mimetype!='application/json':
                raise ValueError('请求格式不正确，请刷新下载页面')

    def config(self):
        defaults = dict(site_key='', secret='', concurrency=2, rate_kib=512, queue_limit=40)
        if self.config_file.is_file():
            defaults.update(json.loads(self.config_file.read_text()))
        return defaults

    def settings(self):
        config = self.config()
        if request.method == 'POST':
            data = request.get_json() or {}
            self.auth.password_account(data.get('current_password'))
            site, secret = data.get('site_key'), data.get('secret', '')
            if not isinstance(site,str) or not re.fullmatch('[A-Za-z0-9_-]{10,128}',site):
                raise ValueError('请填写有效的 Turnstile 站点公钥')
            if not isinstance(secret,str) or (secret and not re.fullmatch('[A-Za-z0-9_-]{10,256}',secret)):
                raise ValueError('Turnstile 服务端密钥格式无效')
            if site != config['site_key'] and not secret:
                raise ValueError('更换站点公钥时请同时填写对应服务端密钥')
            for key,minimum,maximum in [('concurrency',1,4),('rate_kib',128,2048),('queue_limit',5,100)]:
                if type(data.get(key)) is not int or not minimum <= data[key] <= maximum:
                    raise ValueError('下载并发、速率或队列上限超出允许范围')
                config[key] = data[key]
            config.update(site_key=site, secret=secret or config['secret'])
            if not config['secret']:
                raise ValueError('请先配置 Turnstile 服务端密钥')
            if self.origin.startswith('https:') and (re.fullmatch('[123]x0+AA|[123]x0+AB|[123]x0+BB|[123]x0+FF',site) or re.fullmatch('[123]x0+AA',config['secret'])):
                raise ValueError('正式站点不能使用 Turnstile 官方测试密钥')
            with self.lock:
                self.atomic(self.config_file, json.dumps(config).encode())
                self.config_file.chmod(0o600)
                with self.db() as c:
                    c.execute("UPDATE download_queue SET status='cancelled' WHERE status IN ('waiting','ready')")
                    self.event(c,'更新下载验证与排队配置')
        return jsonify(site_key=config['site_key'],secret_configured=bool(config['secret']),
                       concurrency=config['concurrency'],rate_kib=config['rate_kib'],queue_limit=config['queue_limit'])

    def digest(self, value):
        return hmac.new(self.key,value.encode(),hashlib.sha256).hexdigest()

    def identity(self):
        cookie = request.cookies.get('nnu_download','')
        if not re.fullmatch('[A-Za-z0-9_-]{43}',cookie):
            raise ValueError('下载会话已过期，请刷新页面')
        return self.digest('owner:'+cookie), self.digest('ip:'+request.remote_addr)

    def csrf(self):
        cookie = request.cookies.get('nnu_download','')
        token = request.headers.get('X-Download-Token','')
        if request.headers.get('Origin') != self.origin or not secrets.compare_digest(
                token if token.isascii() else '',self.digest('csrf:'+cookie)):
            raise ValueError('页面验证已过期，请刷新后重试')
        return self.identity()

    def limit(self, kind, ip, maximum):
        window = int(time.time() // 60)
        key = kind+':'+ip
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            c.execute('DELETE FROM download_limits WHERE window<?',(window-2,))
            row = c.execute('SELECT * FROM download_limits WHERE k=?',(key,)).fetchone()
            n = row['n']+1 if row and row['window']==window else 1
            c.execute('INSERT OR REPLACE INTO download_limits VALUES(?,?,?)',(key,window,n))
        if n>maximum:
            raise TooManyRequests('请求过于频繁，请一分钟后重试')

    def packages(self):
        output = {}
        path = self.public / ('stable-v2.json' if (self.public/'stable-v2.json').exists() else 'stable.json')
        if path.is_file():
            m = release.verify_manifest(path.read_bytes())
            for kind,a in m['artifacts'].items():
                # External releases use another host; the queue only admits local immutable files.
                if m.get('delivery') != 'external':
                    output[f"{m['build']}:{kind}"] = dict(a,kind=kind,platform='windows',build=m['build'],version=m['version'],path=f"releases/{m['build']}/{a['name']}")
        with self.db() as c:
            rows = c.execute('SELECT DISTINCT r.envelope FROM platform_releases r JOIN platform_channels p ON p.build=r.build').fetchall()
            channels = dict(c.execute('SELECT platform,build FROM platform_channels'))
        for row in rows:
            m = platform_release.verify(row['envelope'].encode())
            for kind,a in m['artifacts'].items():
                group = kind.split('-')[0]
                if channels.get(group)==m['build']:
                    output[f"{m['build']}:{kind}"] = dict(a,kind=kind,platform=group,build=m['build'],version=m['version'],path=f"releases/{m['build']}/{a['path']}")
            for kind,a in m.get('sources',{}).items():
                output[f"{m['build']}:source-{kind}"] = dict(a,name=Path(a['path']).name,kind='source-'+kind,platform='source',build=m['build'],version=m['version'],path=f"releases/{m['build']}/{a['path']}")
        return output

    def home(self):
        return send_from_directory(self.assets,'index.html')

    def asset(self,name):
        return send_from_directory(self.assets,name)

    def catalog(self):
        self.limit('catalog',self.digest(request.remote_addr),30)
        config = self.config()
        cookie = request.cookies.get('nnu_download','')
        if not re.fullmatch('[A-Za-z0-9_-]{43}',cookie):
            cookie = secrets.token_urlsafe(32)
        packages = []
        for key,value in self.packages().items():
            packages.append({k:v for k,v in dict(value,id=key).items() if k not in ('url','path','mirrors')})
        response = jsonify(packages=packages,site_key=config['site_key'],ready=bool(config['site_key'] and config['secret']),
                           csrf=self.digest('csrf:'+cookie),concurrency=config['concurrency'],rate_kib=config['rate_kib'])
        response.set_cookie('nnu_download',cookie,max_age=3600,secure=self.origin.startswith('https:'),httponly=True,samesite='Strict',path='/downloads')
        return response

    def verify_turnstile(self, token, config, action='software_download'):
        if not isinstance(token,str) or not 1<=len(token)<=2048:
            return False
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self,*args,**kwargs):
                return None
        body=json.dumps(dict(secret=config['secret'],response=token,remoteip=request.remote_addr)).encode()
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
        req=urllib.request.Request('https://challenges.cloudflare.com/turnstile/v0/siteverify',data=body,headers={'Content-Type':'application/json'})
        try:
            with opener.open(req,timeout=6) as response:
                result=json.loads(response.read(16384))
            return result.get('success') is True and result.get('hostname')==urlsplit(self.origin).hostname and result.get('action')==action
        except (OSError,ValueError):
            return False

    def advance(self,c):
        now=time.time()
        c.execute("UPDATE download_queue SET status='expired' WHERE (status='waiting' AND touched<?) OR (status IN ('ready','active') AND deadline<?)", (now-45,now))
        c.execute("DELETE FROM download_queue WHERE status NOT IN ('waiting','ready','active') AND touched<?",(now-3600,))
        config=self.config()
        active=c.execute("SELECT count(*) FROM download_queue WHERE status IN ('ready','active')").fetchone()[0]
        for row in c.execute("SELECT id FROM download_queue WHERE status='waiting' ORDER BY created,id LIMIT ?",(max(0,config['concurrency']-active),)).fetchall():
            c.execute("UPDATE download_queue SET status='ready',deadline=? WHERE id=?",(now+30,row['id']))

    def owner_row(self,c,owner,ip):
        return c.execute('SELECT * FROM download_queue WHERE owner=? AND ip=? ORDER BY created DESC LIMIT 1',(owner,ip)).fetchone()

    def view(self,c,row):
        position=0
        if row['status']=='waiting':
            position=c.execute("SELECT count(*) FROM download_queue WHERE status='waiting' AND (created<? OR (created=? AND id<=?))",(row['created'],row['created'],row['id'])).fetchone()[0]
        return dict(status=row['status'],position=position,expires=row['deadline'],name=json.loads(row['artifact'])['name'],
                    download=f"/downloads/file/{row['id']}" if row['status']=='ready' else None)

    def join(self):
        owner,ip=self.csrf()
        self.limit('join',ip,8)
        config=self.config()
        if not config['secret'] or not config['site_key']:
            raise ValueError('下载验证尚未配置，请联系管理员')
        data=request.get_json() or {}
        if not isinstance(data,dict) or not isinstance(data.get('artifact'),str) or len(data['artifact'])>80:
            raise ValueError('请从页面选择安装包')
        artifact=self.packages().get(data.get('artifact'))
        if not artifact:
            raise ValueError('此安装包已更新，请重新选择')
        if not self.verifiers.acquire(blocking=False):
            raise TooManyRequests('安全验证繁忙，请稍后重试')
        try:
            if not self.verify_turnstile(data.get('token'),config):
                raise ValueError('安全验证未通过或已过期，请重新验证')
        finally:
            self.verifiers.release()
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            self.advance(c)
            row=c.execute("SELECT id FROM download_queue WHERE (owner=? OR ip=?) AND status IN ('waiting','ready','active')",(owner,ip)).fetchone()
            if row:
                raise ValueError('当前设备或网络已有下载，请完成或取消后重试')
            if c.execute("SELECT count(*) FROM download_queue WHERE status='waiting'").fetchone()[0]>=config['queue_limit']:
                raise TooManyRequests('下载队列已满，请稍后重试')
            ticket=secrets.token_urlsafe(32);now=time.time()
            c.execute('INSERT INTO download_queue VALUES(?,?,?,?,?,?,?,?,0)',(ticket,owner,ip,json.dumps(artifact),now,now,'waiting',None))
            self.advance(c)
            return jsonify(self.view(c,c.execute('SELECT * FROM download_queue WHERE id=?',(ticket,)).fetchone()))

    def status(self):
        owner,ip=self.identity()
        self.limit('status',ip,45)
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            self.advance(c)
            c.execute("UPDATE download_queue SET touched=? WHERE owner=? AND ip=? AND status='waiting'",(time.time(),owner,ip))
            row=self.owner_row(c,owner,ip)
            return jsonify(self.view(c,row) if row else dict(status='none',position=0))

    def cancel(self):
        owner,ip=self.csrf()
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            c.execute("UPDATE download_queue SET status='cancelled',touched=? WHERE owner=? AND ip=? AND status IN ('waiting','ready')",(time.time(),owner,ip))
            self.advance(c)
        return jsonify(ok=True)

    def stream(self,ticket):
        owner,ip=self.identity()
        self.limit('file',ip,8)
        if request.method!='GET' or request.headers.get('Range'):
            return Response('请从下载页面重新获取完整安装包',status=416)
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE');self.advance(c)
            row=c.execute("SELECT * FROM download_queue WHERE id=? AND owner=? AND ip=? AND status='ready'",(ticket,owner,ip)).fetchone()
            if not row:
                raise ValueError('下载凭证失效，请返回下载页重新验证')
            artifact=json.loads(row['artifact']);path=self.public/artifact['path']
            if not path.resolve().is_relative_to(self.public.resolve()) or path.is_symlink() or not path.is_file() or path.stat().st_size!=artifact['size']:
                raise ValueError('安装包已更新，请返回下载页重新选择')
            handle=path.open('rb')
            if hashlib.file_digest(handle,'sha256').hexdigest()!=artifact['sha256']:
                handle.close()
                raise ValueError('安装包校验不符，已停止提供下载，请联系管理员')
            handle.seek(0);deadline=time.time()+1200
            c.execute("UPDATE download_queue SET status='active',deadline=?,touched=? WHERE id=?",(deadline,time.time(),ticket))
        rate=self.config()['rate_kib']*1024
        def chunks():
            count=0;started=time.monotonic();completed=False
            try:
                while data:=handle.read(65536):
                    if time.time()>deadline:
                        break
                    count+=len(data)
                    delay=count/rate-(time.monotonic()-started)
                    if delay>0:time.sleep(delay)
                    yield data
                completed=count==artifact['size']
            finally:
                handle.close()
                with self.db() as c:
                    c.execute("UPDATE download_queue SET status=?,bytes=?,touched=? WHERE id=? AND status='active'",('completed' if completed else 'interrupted',count,time.time(),ticket))
                    self.advance(c)
        response=Response(chunks(),mimetype='application/octet-stream')
        response.content_length=artifact['size']
        response.headers['Content-Disposition']=f'attachment; filename="{artifact["name"]}"'
        response.headers['X-Accel-Buffering']='no'
        response.headers['Cache-Control']='private, no-store'
        response.headers['Accept-Ranges']='none'
        return response

    def headers(self,response):
        if request.path.startswith('/downloads/'):
            response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; style-src 'self'; img-src 'self' data:; connect-src 'self' https://challenges.cloudflare.com; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
            response.headers['Cache-Control']='no-store'
            if response.status_code==429:response.headers['Retry-After']='60'
        return response
