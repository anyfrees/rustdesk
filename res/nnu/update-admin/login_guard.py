"""Escalate password failures to verified challenges without locking Passkeys."""
import hashlib
import math
import threading
import time

from flask import jsonify, request
from werkzeug.exceptions import TooManyRequests


class LoginGuard:
    def __init__(self, app, db, event, account_auth, portal):
        self.db, self.event, self.portal = db, event, portal
        self.verifier = threading.BoundedSemaphore(1)
        with db() as c:
            c.execute('CREATE TABLE IF NOT EXISTS admin_login_failures(k TEXT PRIMARY KEY,n INTEGER,until REAL)')
        account_auth.login_guard = self
        account_auth.public_paths.add('/update-admin/api/login-protection')
        app.add_url_rule('/update-admin/api/login-protection', 'login_protection', self.status)
        app.after_request(self.headers)

    @staticmethod
    def ip_key():
        return 'ip:' + hashlib.sha256((request.remote_addr or '').encode()).hexdigest()

    def required(self):
        with self.db() as c:
            rows = c.execute('SELECT k,n FROM admin_login_failures WHERE k IN (?,?) AND until>?',
                             (self.ip_key(), 'global', time.time())).fetchall()
        return any(r['n'] >= (20 if r['k'] == 'global' else 3) for r in rows)

    def status(self):
        config = self.portal.config()
        return jsonify(required=self.required(), site_key=config['site_key'],
                       configured=bool(config['site_key'] and config['secret']))

    def before_login(self, data):
        if not self.required():
            return True
        config = self.portal.config()
        token = data.get('turnstile_token')
        if not config['secret'] or not isinstance(token, str) or not 1 <= len(token) <= 2048:
            self.failed()
            return False
        if not self.verifier.acquire(blocking=False):
            raise TooManyRequests('安全验证繁忙，请稍后重试')
        try:
            valid = self.portal.verify_turnstile(token, config, action='admin_login')
        finally:
            self.verifier.release()
        if not valid:
            self.failed()
        return valid

    def failed(self):
        now = time.time()
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            c.execute('DELETE FROM admin_login_failures WHERE until<?', (now,))
            for key in (self.ip_key(), 'global'):
                c.execute('''INSERT INTO admin_login_failures VALUES(?,1,?)
                    ON CONFLICT(k) DO UPDATE SET n=n+1''', (key, now + 900))
            count = c.execute('SELECT n FROM admin_login_failures WHERE k=?', (self.ip_key(),)).fetchone()[0]
            if count == 3:
                self.event(c, '后台登录连续失败，触发人机验证')

    def succeeded(self):
        with self.db() as c:
            c.execute('DELETE FROM admin_login_failures WHERE k=?', (self.ip_key(),))

    def headers(self, response):
        if request.path == '/update-admin/':
            response.headers['Content-Security-Policy'] = ("default-src 'self'; script-src 'self' https://challenges.cloudflare.com; "
                "frame-src https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com; "
                "style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
        if request.path == '/update-admin/api/login' and response.status_code == 429:
            key = 'password:' + self.ip_key()[3:]
            with self.db() as c:
                row = c.execute('SELECT until FROM limits WHERE key=?', (key,)).fetchone()
            response.headers['Retry-After'] = str(max(1, math.ceil(row['until'] - time.time())) if row else 5)
        return response
