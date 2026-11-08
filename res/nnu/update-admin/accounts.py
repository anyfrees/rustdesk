import hashlib
import json
import re
import secrets
import time
from urllib.parse import urlsplit

from flask import jsonify, request, session
from werkzeug.exceptions import TooManyRequests
from werkzeug.security import check_password_hash, generate_password_hash
from webauthn import (base64url_to_bytes, generate_authentication_options,
                      generate_registration_options, options_to_json,
                      verify_authentication_response, verify_registration_response)
from webauthn.helpers.structs import (AuthenticatorSelectionCriteria,
                                     PublicKeyCredentialDescriptor,
                                     ResidentKeyRequirement,
                                     UserVerificationRequirement)


class AccountAuth:
    @staticmethod
    def data():
        data = request.get_json() or {}
        if not isinstance(data, dict):
            raise ValueError('请求格式不正确')
        return data

    def __init__(self, app, db, event, seed, origin, base):
        self.db, self.event, self.origin = db, event, origin
        self.rp_id = urlsplit(origin).hostname
        with db() as c:
            c.executescript('''
                CREATE TABLE IF NOT EXISTS account(id INTEGER PRIMARY KEY CHECK(id=1),
                  username TEXT NOT NULL,password_hash TEXT NOT NULL,
                  user_handle BLOB NOT NULL,revision INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS passkeys(id TEXT PRIMARY KEY,public_key BLOB NOT NULL,
                  sign_count INTEGER NOT NULL,name TEXT NOT NULL,created REAL,last_used REAL);
                CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY,browser TEXT,
                  purpose TEXT,challenge BLOB,revision INTEGER,expires REAL,name TEXT);
            ''')
            columns = {r['name'] for r in c.execute('PRAGMA table_info(sessions)')}
            if 'revision' not in columns:
                c.execute('ALTER TABLE sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0')
            if 'passkey_id' not in columns:
                c.execute('ALTER TABLE sessions ADD COLUMN passkey_id TEXT')
            c.execute('INSERT OR IGNORE INTO account VALUES(1,?,?,?,0)',
                      (seed['username'], seed['password_hash'], secrets.token_bytes(32)))
        self.public_paths = {base + path for path in (
            '/api/session', '/api/login', '/api/passkeys/login/options', '/api/passkeys/login/verify')}
        for path, method, handler in [
            ('/api/account', 'GET', self.account_info),
            ('/api/account', 'POST', self.update_account),
            ('/api/passkeys/register/options', 'POST', self.register_options),
            ('/api/passkeys/register/verify', 'POST', self.register_verify),
            ('/api/passkeys/login/options', 'POST', self.login_options),
            ('/api/passkeys/login/verify', 'POST', self.login_verify),
            ('/api/passkeys/<credential_id>/delete', 'POST', self.delete_passkey),
        ]:
            app.add_url_rule(base + path, endpoint='account_' + handler.__name__,
                             view_func=handler, methods=[method])

    def account(self, c=None):
        if c is not None:
            return c.execute('SELECT * FROM account WHERE id=1').fetchone()
        with self.db() as connection:
            return self.account(connection)

    @staticmethod
    def sid_hash():
        return hashlib.sha256(session.get('sid', '').encode()).hexdigest()

    def authenticated(self):
        if not session.get('sid'):
            return False
        with self.db() as c:
            return c.execute('''SELECT 1 FROM sessions s JOIN account a ON a.id=1
                WHERE s.id=? AND s.expires>? AND s.revision=a.revision''',
                (self.sid_hash(), time.time())).fetchone() is not None

    def limit(self, kind, maximum=10):
        key = kind + ':' + hashlib.sha256((request.remote_addr or '').encode()).hexdigest()
        now = time.time()
        with self.db() as c:
            c.execute('DELETE FROM limits WHERE until<?', (now,))
            c.execute('''INSERT INTO limits VALUES(?,1,?) ON CONFLICT(key)
                         DO UPDATE SET count=count+1''', (key, now + 900))
            count = c.execute('SELECT count FROM limits WHERE key=?', (key,)).fetchone()[0]
        if count > maximum:
            raise TooManyRequests('尝试次数过多，请 15 分钟后重试')
        return key

    def password_account(self, password):
        key = self.limit('password')
        account = self.account()
        valid = isinstance(password, str) and len(password) <= 512
        if not valid or not check_password_hash(account['password_hash'], password):
            raise ValueError('当前密码不正确')
        with self.db() as c:
            c.execute('DELETE FROM limits WHERE key=?', (key,))
        return account

    def issue_session(self, c, revision, passkey_id=None):
        if self.account(c)['revision'] != revision:
            raise ValueError('账户已变更，请重新登录')
        session.clear()
        session.permanent = True
        session['csrf'] = secrets.token_urlsafe(32)
        session['sid'] = secrets.token_urlsafe(32)
        c.execute('DELETE FROM sessions WHERE expires<?', (time.time(),))
        c.execute('INSERT INTO sessions(id,expires,revision,passkey_id) VALUES(?,?,?,?)',
                  (self.sid_hash(), time.time() + 43200, revision, passkey_id))

    def login(self):
        data = self.data()
        key = self.limit('password')
        guard = getattr(self, 'login_guard', None)
        if guard and not guard.before_login(data):
            return jsonify(error='请完成安全验证后重试'), 401
        account = self.account()
        password, username = data.get('password'), data.get('username')
        if not isinstance(password, str) or len(password) > 512 or not isinstance(username, str):
            if guard:
                guard.failed()
            return jsonify(error='账号或密码不正确'), 401
        valid = check_password_hash(account['password_hash'], password)
        if not secrets.compare_digest(username.encode(), account['username'].encode()) or not valid:
            if guard:
                guard.failed()
            return jsonify(error='账号或密码不正确'), 401
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            self.issue_session(c, account['revision'])
            c.execute('DELETE FROM limits WHERE key=?', (key,))
            self.event(c, '密码登录')
        if guard:
            guard.succeeded()
        return jsonify(csrf=session['csrf'], username=account['username'])

    def account_info(self):
        with self.db() as c:
            keys = [dict(r) for r in c.execute(
                'SELECT id,name,created,last_used FROM passkeys ORDER BY created')]
        return jsonify(username=self.account()['username'], passkeys=keys)

    def update_account(self):
        data = self.data()
        account = self.password_account(data.get('current_password'))
        username, password = data.get('username'), data.get('new_password', '')
        if not isinstance(username, str) or not re.fullmatch(r'[\w.@+-]{3,64}', username):
            raise ValueError('用户名需为 3–64 个中文、字母、数字或 . _ @ + - 字符')
        if not isinstance(password, str) or (password and not 12 <= len(password) <= 128):
            raise ValueError('新密码需为 12–128 个字符')
        if username == account['username'] and not password:
            raise ValueError('请先修改用户名或填写新密码')
        password_hash = generate_password_hash(password) if password else account['password_hash']
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            if self.account(c)['revision'] != account['revision']:
                raise ValueError('账户已变更，请重新打开设置')
            c.execute('UPDATE account SET username=?,password_hash=?,revision=revision+1 WHERE id=1',
                      (username, password_hash))
            c.execute('DELETE FROM sessions')
            c.execute('DELETE FROM challenges')
            self.issue_session(c, account['revision'] + 1)
            self.event(c, '修改用户名和密码' if password else '修改用户名')
        return jsonify(csrf=session['csrf'], username=username)

    def new_challenge(self, purpose, challenge, revision, name=''):
        browser = session.setdefault('webauthn_browser', secrets.token_urlsafe(32))
        token = secrets.token_urlsafe(32)
        with self.db() as c:
            c.execute('DELETE FROM challenges WHERE expires<? OR (browser=? AND purpose=?)',
                      (time.time(), browser, purpose))
            c.execute('INSERT INTO challenges VALUES(?,?,?,?,?,?,?)',
                      (token, browser, purpose, challenge, revision, time.time() + 180, name))
        return token

    def take_challenge(self, purpose, token):
        if not isinstance(token, str):
            raise ValueError('Passkey 请求已过期，请重试')
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT * FROM challenges WHERE id=? AND browser=? AND purpose=?',
                            (token, session.get('webauthn_browser', ''), purpose)).fetchone()
            if row:
                c.execute('DELETE FROM challenges WHERE id=?', (token,))
        if not row or row['expires'] < time.time() or row['revision'] != self.account()['revision']:
            raise ValueError('Passkey 请求已过期，请重试')
        return row

    def register_options(self):
        data = self.data()
        account = self.password_account(data.get('current_password'))
        name = data.get('name', 'Passkey')
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 60 or not name.isprintable():
            raise ValueError('请填写 1–60 个字符的 Passkey 名称')
        with self.db() as c:
            keys = c.execute('SELECT id FROM passkeys').fetchall()
        if len(keys) >= 10:
            raise ValueError('最多添加 10 个 Passkey')
        options = generate_registration_options(
            rp_id=self.rp_id, rp_name='NNU 版本管理', user_id=account['user_handle'],
            user_name=account['username'], timeout=120000,
            exclude_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(r['id'])) for r in keys],
            authenticator_selection=AuthenticatorSelectionCriteria(
                resident_key=ResidentKeyRequirement.REQUIRED, require_resident_key=True,
                user_verification=UserVerificationRequirement.REQUIRED))
        token = self.new_challenge('register', options.challenge, account['revision'], name.strip())
        return jsonify(request_id=token, options=json.loads(options_to_json(options)))

    def register_verify(self):
        data = self.data()
        challenge = self.take_challenge('register', data.get('request_id'))
        try:
            verified = verify_registration_response(
                credential=data['credential'], expected_challenge=challenge['challenge'],
                expected_origin=self.origin, expected_rp_id=self.rp_id,
                require_user_verification=True)
        except Exception as exc:
            raise ValueError('Passkey 验证失败，请重新添加') from exc
        credential_id = self.encode(verified.credential_id)
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            if self.account(c)['revision'] != challenge['revision']:
                raise ValueError('账户已变更，请重新添加 Passkey')
            if c.execute('SELECT 1 FROM passkeys WHERE id=?', (credential_id,)).fetchone():
                raise ValueError('此 Passkey 已添加')
            if c.execute('SELECT count(*) FROM passkeys').fetchone()[0] >= 10:
                raise ValueError('最多添加 10 个 Passkey')
            c.execute('INSERT INTO passkeys VALUES(?,?,?,?,?,NULL)',
                      (credential_id, verified.credential_public_key, verified.sign_count,
                       challenge['name'], time.time()))
            self.event(c, '添加 Passkey')
        return jsonify(ok=True)

    def login_options(self):
        self.limit('passkey', 30)
        options = generate_authentication_options(
            rp_id=self.rp_id, timeout=120000,
            user_verification=UserVerificationRequirement.REQUIRED)
        token = self.new_challenge('login', options.challenge, self.account()['revision'])
        return jsonify(request_id=token, options=json.loads(options_to_json(options)))

    def login_verify(self):
        self.limit('passkey-verify', 30)
        data = self.data()
        challenge = self.take_challenge('login', data.get('request_id'))
        credential = data.get('credential')
        if not isinstance(credential, dict) or not isinstance(credential.get('id'), str):
            raise ValueError('Passkey 验证失败，请重试')
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            account = self.account(c)
            key = c.execute('SELECT * FROM passkeys WHERE id=?', (credential['id'],)).fetchone()
            if not key or account['revision'] != challenge['revision']:
                raise ValueError('Passkey 不存在或已撤销')
            try:
                handle = base64url_to_bytes(credential['response']['userHandle'])
                if not secrets.compare_digest(handle, account['user_handle']):
                    raise ValueError('User handle mismatch')
                verified = verify_authentication_response(
                    credential=credential, expected_challenge=challenge['challenge'],
                    expected_origin=self.origin, expected_rp_id=self.rp_id,
                    credential_public_key=key['public_key'],
                    credential_current_sign_count=key['sign_count'],
                    require_user_verification=True)
            except Exception as exc:
                raise ValueError('Passkey 验证失败，请重试') from exc
            c.execute('UPDATE passkeys SET sign_count=?,last_used=? WHERE id=?',
                      (verified.new_sign_count, time.time(), key['id']))
            self.issue_session(c, account['revision'], key['id'])
            self.event(c, 'Passkey 登录')
        return jsonify(csrf=session['csrf'], username=account['username'])

    def delete_passkey(self, credential_id):
        data = self.data()
        account = self.password_account(data.get('current_password'))
        with self.db() as c:
            c.execute('BEGIN IMMEDIATE')
            if self.account(c)['revision'] != account['revision']:
                raise ValueError('账户已变更，请重新打开设置')
            row = c.execute('SELECT 1 FROM passkeys WHERE id=?', (credential_id,)).fetchone()
            if not row:
                raise ValueError('Passkey 不存在或已撤销')
            own = c.execute('SELECT passkey_id FROM sessions WHERE id=?', (self.sid_hash(),)).fetchone()
            c.execute('DELETE FROM passkeys WHERE id=?', (credential_id,))
            c.execute('DELETE FROM sessions WHERE passkey_id=?', (credential_id,))
            c.execute('DELETE FROM challenges WHERE purpose=?', ('register',))
            self.event(c, '撤销 Passkey')
        logged_out = bool(own and own['passkey_id'] == credential_id)
        if logged_out:
            session.clear()
        return jsonify(ok=True, logged_out=logged_out)

    @staticmethod
    def encode(value):
        import base64
        return base64.urlsafe_b64encode(value).rstrip(b'=').decode()
