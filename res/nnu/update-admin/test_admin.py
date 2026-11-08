import base64
import hashlib
import importlib
import io
import json
import os
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from pathlib import Path
import secrets
import cbor2

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from werkzeug.security import generate_password_hash
import release


class AdminTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.public = cls.root / 'public'
        cls.public.mkdir()
        (cls.public / 'releases').mkdir()
        cls.key = Ed25519PrivateKey.generate()
        release.PUBLIC_KEY = base64.b64encode(cls.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        cls.creds = cls.root / 'credentials.json'
        cls.creds.write_text(json.dumps(dict(username='admin',password_hash=generate_password_hash('test-secret-123'),session_secret='test-session-secret')))
        cls.log = cls.root / 'access.log'
        cls.log.write_text('112.0.0.1 - - [31/Oct/2026:13:20:28 +0800] "GET /client-updates/releases/1/RustDesk-1-x64-install.exe HTTP/1.1" 206 1024 "-" "-" "-"\n')
        os.environ.update(NNU_STATE=str(cls.root/'state'),NNU_PUBLIC=str(cls.public),NNU_CREDENTIALS=str(cls.creds),NNU_ORIGIN='http://localhost',NNU_LOG=str(cls.log),NNU_STATS_WORKER='0')
        cls.module = importlib.import_module('app')
        cls.app = cls.module.app
        cls.app.config['TESTING'] = True

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        with self.module.db() as c:
            seed=json.loads(self.creds.read_text())
            c.execute('UPDATE account SET username=?,password_hash=?,revision=revision+1 WHERE id=1',('admin',seed['password_hash']))
            c.executescript('DELETE FROM passkeys;DELETE FROM challenges;DELETE FROM sessions;DELETE FROM limits;DELETE FROM admin_login_failures;')
            c.execute("UPDATE announcement SET revision=0,title='',body='',published_title=NULL,published_body=NULL,published_at=NULL,draft_items=NULL,published_items=NULL,interval_seconds=8,published_interval=8 WHERE id=1")
        self.client = self.app.test_client()
        self.csrf = self.client.get('/update-admin/api/session').json['csrf']

    def post(self, path, data=None, **kw):
        return self.client.post('/update-admin/api'+path, json=data, headers={'X-CSRF-Token':self.csrf}, **kw)

    def login(self):
        r=self.post('/login', dict(username='admin',password='test-secret-123'))
        self.assertEqual(r.status_code,200)
        self.csrf=r.json['csrf']

    def archive(self, build, corrupt=False, traversal=False, invalid_signature=False):
        artifacts={}
        content=b'fixture installer content'
        for kind,ext in [('portable','exe'),('install','exe'),('msi','msi'),('zip','zip')]:
            name=f'RustDesk-{build}-x64-{kind}.{ext}'
            artifacts[kind]=dict(name=name,size=len(content),sha256=hashlib.sha256(content).hexdigest(),url=f'https://rd.nnu.cn/client-updates/releases/{build}/{name}')
        m=dict(schema=1,channel='stable',build=build,version=f'1.5.0 test {build}',notes='测试更新',artifacts=artifacts)
        payload=json.dumps(m).encode()
        raw=json.dumps(dict(payload=base64.b64encode(payload).decode(),signature=base64.b64encode((Ed25519PrivateKey.generate() if invalid_signature else self.key).sign(payload)).decode())).encode()
        output=io.BytesIO()
        with zipfile.ZipFile(output,'w') as z:
            z.writestr('stable.json',raw)
            for a in artifacts.values():z.writestr(f"releases/{build}/{a['name']}",b'X'*len(content) if corrupt else content)
            if traversal:z.writestr('../escape.txt',b'bad')
        return output.getvalue(),raw

    def upload(self, data):
        return self.client.post('/update-admin/api/import',data=data,content_type='application/zip',headers={'X-CSRF-Token':self.csrf})

    def platform_archive(self, build, corrupt=False, windows=False):
        import platform_release
        contents, artifacts = {}, {}
        for kind,(folder,arch,ext) in platform_release.KINDS.items():
            name=(f'RustDesk-NNU-{build}-android-{arch}.{ext}' if folder=='Android' else f'RustDesk-NNU-{build}-linux-x86_64.{ext}')
            path=f'{folder}/{name}'
            value=('fixture '+kind).encode()
            artifacts[kind]=dict(name=name,path=path,size=len(value),sha256=hashlib.sha256(value).hexdigest(),url=f'https://rd.nnu.cn/client-updates/releases/{build}/{path}')
            contents[path]=b'X'*len(value) if corrupt else value
        m=dict(schema=1,type='nnu-platform-release',build=build,version=f'1.5.0 test {build}',notes='平台更新',artifacts=artifacts)
        if windows:
            value,_=self.archive(build)
            contents['windows-update.zip']=value
            m['windows']=dict(path='windows-update.zip',size=len(value),sha256=hashlib.sha256(value).hexdigest())
        payload=json.dumps(m).encode()
        raw=json.dumps(dict(payload=base64.b64encode(payload).decode(),signature=base64.b64encode(self.key.sign(payload)).decode())).encode()
        output=io.BytesIO()
        with zipfile.ZipFile(output,'w') as z:
            z.writestr('platform-release.json',raw)
            for path,value in contents.items():z.writestr(path,value)
        return output.getvalue(),raw

    def platform_upload(self, data):
        return self.client.post('/update-admin/api/platforms/import',data=data,content_type='application/zip',headers={'X-CSRF-Token':self.csrf})

    def test_platform_a_combined_publish_and_verified_downloads(self):
        self.assertEqual(self.client.get('/update-admin/api/platforms').status_code,401)
        self.login()
        data,raw=self.platform_archive(301,windows=True)
        self.assertEqual(self.platform_upload(data).status_code,200)
        with self.client.get('/update-admin/api/platforms/bundle/301') as downloaded:
            self.assertEqual(downloaded.data,data)
        self.assertEqual(self.client.get('/update-admin/platforms/android/stable.json').status_code,404)
        result=self.post('/platforms/publish/301',{})
        self.assertEqual(result.status_code,200,result.json)
        self.assertTrue(result.json['windows_published'])
        for platform in ['android','linux']:
            self.assertEqual(self.client.get(f'/update-admin/platforms/{platform}/stable.json').data,raw)
        self.assertEqual(self.client.get('/update-admin/api/overview').json['current']['build'],301)
        overview=self.client.get('/update-admin/api/platforms').json
        self.assertEqual(overview['current'],dict(android=301,linux=301))
        self.assertFalse(overview['releases'][0]['pending'])
        with self.client.get('/update-admin/api/platforms/bundle/301') as downloaded:
            self.assertEqual(downloaded.data,data)
        self.assertEqual(self.post('/platforms/publish/301',{}).status_code,200)
        self.assertEqual(self.post('/platforms/discard/301',{}).status_code,400)
        self.assertEqual(self.post('/push',dict(paused=True)).status_code,200)
        self.assertEqual(self.client.get('/update-admin/platforms/linux/stable.json').status_code,204)
        self.post('/push',dict(paused=False))

    def test_platform_b_rejects_corruption_and_removes_only_pending(self):
        self.login()
        previous=self.client.get('/update-admin/api/platforms').json['current']
        invalid,_=self.platform_archive(302,corrupt=True)
        self.assertEqual(self.platform_upload(invalid).status_code,400)
        data,_=self.platform_archive(302,windows=True)
        self.assertEqual(self.client.post('/update-admin/api/platforms/import',data=data,content_type='application/zip').status_code,403)
        self.assertEqual(self.platform_upload(data).status_code,200)
        self.assertEqual(self.post('/platforms/discard/302',{}).status_code,200)
        with self.module.db() as c:
            self.assertIsNone(c.execute('SELECT * FROM releases WHERE build=302').fetchone())
        self.assertEqual(self.client.get('/update-admin/api/platforms').json['current'],previous)

    def test_platform_c_refuses_channel_rollback(self):
        self.login()
        newer,_=self.platform_archive(303)
        self.assertEqual(self.platform_upload(newer).status_code,200)
        self.assertEqual(self.post('/platforms/publish/303',{}).status_code,200)
        data,_=self.platform_archive(299)
        self.assertEqual(self.platform_upload(data).status_code,200)
        self.assertEqual(self.post('/platforms/publish/299',{}).status_code,400)
        self.assertEqual(self.post('/platforms/discard/299',{}).status_code,200)

    def test_authorization_csrf_and_revocation(self):
        self.assertEqual(self.client.get('/update-admin/api/overview').status_code,401)
        self.assertEqual(self.client.post('/update-admin/api/login',json={}).status_code,403)
        self.assertEqual(self.post('/login',dict(username='admin',password='wrong')).status_code,401)
        self.login()
        self.assertEqual(self.client.post('/update-admin/api/push',json={'paused':True},headers={'X-CSRF-Token':self.csrf,'Origin':'https://evil.example'}).status_code,403)
        cookie=self.client.get_cookie('nnu_admin',path='/update-admin')
        self.assertEqual(self.post('/logout',{}).status_code,200)
        self.client.set_cookie('nnu_admin',cookie.value,path='/update-admin')
        self.assertEqual(self.client.get('/update-admin/api/overview').status_code,401)

    def test_import_verify_publish_pause_and_history(self):
        self.login()
        first,raw=self.archive(100)
        self.assertEqual(self.upload(first).status_code,200)
        self.assertFalse((self.public/'stable.json').exists())
        self.assertEqual(self.post('/publish/100',{}).status_code,200)
        self.assertEqual((self.public/'stable.json').read_bytes(),raw)
        self.assertEqual(self.client.get('/feed').data,raw)
        self.assertEqual(self.post('/push',{'paused':True}).status_code,200)
        self.assertEqual(self.client.get('/feed').status_code,204)
        self.assertEqual((self.public/'stable.json').read_bytes(),raw)
        self.assertEqual(self.post('/push',{'paused':False}).status_code,200)
        self.assertEqual(self.client.get('/feed').data,raw)
        self.assertEqual(self.post('/publish/100',{}).status_code,400)
        second,raw2=self.archive(101)
        self.assertEqual(self.upload(second).status_code,200)
        staged=next((self.public/'.admin-staging').glob('*/release/*'))
        self.assertFalse((staged.parent.parent/'bundle.zip').exists())
        staged.write_bytes(b'changed')
        self.assertEqual(self.post('/publish/101',{}).status_code,400)
        self.assertEqual((self.public/'stable.json').read_bytes(),raw)
        self.assertEqual(self.post('/discard/101',{}).status_code,200)
        self.assertFalse(staged.parent.parent.exists())
        with self.module.db() as c:
            self.assertIsNone(c.execute('SELECT 1 FROM releases WHERE build=101').fetchone())
            self.assertIsNotNone(c.execute('SELECT 1 FROM events WHERE build=101').fetchone())
        self.assertEqual(self.upload(second).status_code,200)
        self.assertEqual(self.post('/publish/101',{}).status_code,200)
        self.assertEqual(self.client.get('/feed').data,raw2)
        self.assertTrue((self.public/'releases/100').exists())
        self.assertEqual(len(self.client.get('/update-admin/api/overview').json['releases']),2)

    def test_reject_tampering_zip_traversal_and_duplicate(self):
        self.login()
        for kwargs in [dict(corrupt=True),dict(traversal=True),dict(invalid_signature=True)]:
            with self.subTest(kwargs=kwargs):self.assertEqual(self.upload(self.archive(200,**kwargs)[0]).status_code,400)
        archive,_=self.archive(200)
        output=io.BytesIO(archive)
        with zipfile.ZipFile(output,'a') as z:z.writestr('stable.json',b'{}')
        self.assertEqual(self.upload(output.getvalue()).status_code,400)
        self.assertEqual(self.upload(b'not a zip').status_code,400)
        self.assertFalse((self.root/'escape.txt').exists())

    def test_real_stats_ingested_once(self):
        self.module.ingest_stats()
        self.module.ingest_stats()
        with self.module.db() as c:
            row=c.execute('SELECT * FROM counters WHERE kind="install"').fetchone()
            self.assertEqual(row['requests'],1)
            self.assertEqual(row['bytes'],1024)

    def test_login_rate_limit(self):
        for _ in range(10):self.post('/login',dict(username='admin',password='wrong'),environ_base={'REMOTE_ADDR':'10.0.0.2'})
        r=self.post('/login',dict(username='admin',password='test-secret-123'),environ_base={'REMOTE_ADDR':'10.0.0.2'})
        self.assertEqual(r.status_code,429)
        self.assertGreater(int(r.headers['Retry-After']),0)

    def test_password_login_challenge_after_failures_and_recovery(self):
        self.portal_configure()
        self.post('/logout',{})
        self.csrf=self.client.get('/update-admin/api/session').json['csrf']
        for _ in range(3):
            self.assertEqual(self.post('/login',dict(username='admin',password='wrong')).status_code,401)
        protection=self.client.get('/update-admin/api/login-protection').json
        self.assertTrue(protection['required'])
        self.assertTrue(protection['configured'])
        self.assertNotIn('secret',protection)
        data=dict(username='admin',password='test-secret-123')
        self.assertEqual(self.post('/login',data).status_code,401)
        with patch.object(self.module.download_portal,'verify_turnstile',return_value=True) as verify:
            result=self.post('/login',dict(data,turnstile_token='verified-login-token'))
            self.assertEqual(result.status_code,200,result.json)
            self.assertEqual(verify.call_args.kwargs,dict(action='admin_login'))
        self.assertFalse(self.client.get('/update-admin/api/login-protection').json['required'])

    def test_mobile_import_requires_active_console_user(self):
        path=self.module.STATE/'mobile-import.txt'
        path.write_text('opaque-mobile-config-fixture',encoding='utf-8')
        try:
            for url in ['/downloads/api/mobile-import']:
                self.assertEqual(self.client.get(url).status_code,401)
                with patch.object(self.module.mobile_import,'active_user',return_value=False):
                    r=self.client.get(url,headers={'api-token':'revoked-token'})
                    self.assertEqual(r.status_code,401)
                    self.assertNotIn(b'opaque-mobile-config-fixture',r.data)
                with patch.object(self.module.mobile_import,'active_user',return_value=True):
                    r=self.client.get(url,headers={'api-token':'active-token'})
                    self.assertEqual(r.status_code,200)
                    self.assertEqual(r.json['code'],'opaque-mobile-config-fixture')
                    self.assertIn('no-store',r.headers['Cache-Control'])
                    self.assertEqual(self.client.get(url,headers={'api-token':'active-token','Origin':'https://attacker.example'}).status_code,401)
                with patch.object(self.module.mobile_import,'active_user',side_effect=OSError):
                    self.assertEqual(self.client.get(url,headers={'api-token':'active-token'}).status_code,503)
        finally:
            path.unlink(missing_ok=True)

    def test_mobile_import_uses_live_revocation_check_and_no_redirect(self):
        import mobile_import
        from types import SimpleNamespace
        for code,data,expected in [(0,{'username':'active'},True),(403,None,False),(0,{},False)]:
            opener=SimpleNamespace(open=lambda *args,code=code,data=data,**kw:io.BytesIO(json.dumps(dict(code=code,data=data)).encode()))
            with patch('mobile_import.urllib.request.build_opener',return_value=opener):
                self.assertEqual(self.module.mobile_import.active_user('fixture-token'),expected)

    def test_distributed_failures_require_challenge_without_blocking_passkey_options(self):
        for i in range(20):
            self.assertEqual(self.post('/login',dict(username='admin',password='wrong'),
                environ_base={'REMOTE_ADDR':f'198.51.100.{i+1}'}).status_code,401)
        self.assertTrue(self.client.get('/update-admin/api/login-protection',
            environ_base={'REMOTE_ADDR':'203.0.113.1'}).json['required'])
        self.assertEqual(self.post('/passkeys/login/options',{}).status_code,200)

    def test_host_headers_cookie_flags_and_invalid_csrf(self):
        self.assertEqual(self.client.get('/update-admin/api/session', headers={'Host':'evil.example'}).status_code,400)
        self.assertEqual(self.client.post('/update-admin/api/login', json={}, headers={'X-CSRF-Token':'\u00e9'}).status_code,403)
        response=self.client.get('/update-admin/')
        self.assertEqual(response.headers['X-Frame-Options'],'DENY')
        self.assertIn("object-src 'none'",response.headers['Content-Security-Policy'])
        response.close()
        self.app.config['SESSION_COOKIE_SECURE']=True
        try:
            response=self.app.test_client().get('/update-admin/api/session')
            cookie=response.headers['Set-Cookie']
            for flag in ('Secure','HttpOnly','SameSite=Strict','Path=/update-admin'):
                self.assertIn(flag,cookie)
        finally:
            self.app.config['SESSION_COOKIE_SECURE']=False

    @staticmethod
    def b64(value):
        return base64.urlsafe_b64encode(value).rstrip(b'=').decode()

    def registration(self, options, *, origin='http://localhost', uv=True, rp='localhost'):
        key=ec.generate_private_key(ec.SECP256R1())
        numbers=key.public_key().public_numbers()
        cose=cbor2.dumps({1:2,3:-7,-1:1,-2:numbers.x.to_bytes(32,'big'),-3:numbers.y.to_bytes(32,'big')})
        credential_id=secrets.token_bytes(32)
        auth=hashlib.sha256(rp.encode()).digest()+bytes([0x41|(4 if uv else 0)])+b'\0'*4+b'\0'*16+len(credential_id).to_bytes(2,'big')+credential_id+cose
        client=json.dumps(dict(type='webauthn.create',challenge=options['challenge'],origin=origin,crossOrigin=False)).encode()
        fixture=dict(key=key,id=self.b64(credential_id),user=options['user']['id'])
        credential=dict(id=fixture['id'],rawId=fixture['id'],type='public-key',clientExtensionResults={},response=dict(clientDataJSON=self.b64(client),attestationObject=self.b64(cbor2.dumps(dict(fmt='none',authData=auth,attStmt={}))),transports=['internal']))
        return fixture,credential

    def assertion(self, fixture, options, *, origin='http://localhost', uv=True, rp='localhost', counter=1, signature_valid=True):
        client=json.dumps(dict(type='webauthn.get',challenge=options['challenge'],origin=origin,crossOrigin=False)).encode()
        auth=hashlib.sha256(rp.encode()).digest()+bytes([1|(4 if uv else 0)])+counter.to_bytes(4,'big')
        signature=fixture['key'].sign(auth+hashlib.sha256(client).digest(),ec.ECDSA(hashes.SHA256()))
        if not signature_valid:signature=b'invalid signature'
        return dict(id=fixture['id'],rawId=fixture['id'],type='public-key',clientExtensionResults={},response=dict(clientDataJSON=self.b64(client),authenticatorData=self.b64(auth),signature=self.b64(signature),userHandle=fixture['user']))

    def register_key(self):
        response=self.post('/passkeys/register/options',dict(current_password='test-secret-123',name='Test laptop'))
        self.assertEqual(response.status_code,200,response.json)
        options=response.json
        fixture,credential=self.registration(options['options'])
        response=self.post('/passkeys/register/verify',dict(request_id=options['request_id'],credential=credential))
        self.assertEqual(response.status_code,200,response.json)
        return fixture

    def key_login(self, fixture, **kwargs):
        options=self.post('/passkeys/login/options',{}).json
        response=self.post('/passkeys/login/verify',dict(request_id=options['request_id'],credential=self.assertion(fixture,options['options'],**kwargs)))
        if response.status_code==200:self.csrf=response.json['csrf']
        return response

    def test_account_update_reauth_persistence_and_session_revocation(self):
        self.login()
        old_cookie=self.client.get_cookie('nnu_admin',path='/update-admin').value
        self.assertEqual(self.post('/account',dict(username='新管理员',new_password='new-secret-12345',current_password='wrong')).status_code,400)
        self.assertEqual(self.post('/account',dict(username='newadmin',new_password='short',current_password='test-secret-123')).status_code,400)
        result=self.post('/account',dict(username='新管理员',new_password='new-secret-12345',current_password='test-secret-123'))
        self.assertEqual(result.status_code,200,result.json)
        self.csrf=result.json['csrf']
        self.assertEqual(self.client.get('/update-admin/api/account').json['username'],'新管理员')
        stale=self.app.test_client();stale.set_cookie('nnu_admin',old_cookie,path='/update-admin')
        self.assertEqual(stale.get('/update-admin/api/overview').status_code,401)
        self.assertEqual(self.post('/logout',{}).status_code,200)
        self.csrf=self.client.get('/update-admin/api/session').json['csrf']
        self.assertEqual(self.post('/login',dict(username='admin',password='test-secret-123')).status_code,401)
        self.assertEqual(self.post('/login',dict(username='新管理员',password='new-secret-12345')).status_code,200)
        self.assertEqual(json.loads(self.creds.read_text())['username'],'admin')
        with self.module.db() as c:
            row=c.execute('SELECT * FROM account').fetchone()
            self.assertEqual(row['username'],'新管理员')
            self.assertNotIn('new-secret-12345',row['password_hash'])

    def test_passkey_real_registration_login_replay_and_revocation(self):
        self.login();fixture=self.register_key()
        options=self.post('/passkeys/login/options',{}).json
        credential=self.assertion(fixture,options['options'])
        response=self.post('/passkeys/login/verify',dict(request_id=options['request_id'],credential=credential))
        self.assertEqual(response.status_code,200,response.json);self.csrf=response.json['csrf']
        passkey_cookie=self.client.get_cookie('nnu_admin',path='/update-admin').value
        self.assertEqual(self.post('/passkeys/login/verify',dict(request_id=options['request_id'],credential=credential)).status_code,400)
        self.assertEqual(self.key_login(fixture,counter=1).status_code,400)
        self.assertEqual(self.key_login(fixture,counter=2).status_code,200)
        removed=self.post('/passkeys/'+fixture['id']+'/delete',dict(current_password='test-secret-123'))
        self.assertEqual(removed.status_code,200);self.assertTrue(removed.json['logged_out'])
        stale=self.app.test_client();stale.set_cookie('nnu_admin',passkey_cookie,path='/update-admin')
        self.assertEqual(stale.get('/update-admin/api/overview').status_code,401)
        self.csrf=self.client.get('/update-admin/api/session').json['csrf']
        self.assertEqual(self.key_login(fixture,counter=3).status_code,400)
        self.login()
        self.assertEqual(self.client.get('/update-admin/api/account').json['passkeys'],[])

    def test_passkey_rejects_wrong_origin_rp_signature_user_verification_and_browser(self):
        self.login()
        for kwargs in [dict(origin='https://evil.example'),dict(rp='evil.example'),dict(uv=False)]:
            options=self.post('/passkeys/register/options',dict(current_password='test-secret-123',name='Test')).json
            _,credential=self.registration(options['options'],**kwargs)
            self.assertEqual(self.post('/passkeys/register/verify',dict(request_id=options['request_id'],credential=credential)).status_code,400)
        fixture=self.register_key()
        for kwargs in [dict(origin='https://evil.example'),dict(rp='evil.example'),dict(uv=False),dict(signature_valid=False)]:
            self.assertEqual(self.key_login(fixture,**kwargs).status_code,400)
        options=self.post('/passkeys/login/options',{}).json
        response=dict(request_id=options['request_id'],credential=self.assertion(fixture,options['options']))
        other=self.app.test_client();csrf=other.get('/update-admin/api/session').json['csrf']
        self.assertEqual(other.post('/update-admin/api/passkeys/login/verify',json=response,headers={'X-CSRF-Token':csrf}).status_code,400)
        self.assertEqual(self.post('/passkeys/login/verify',response).status_code,200)

    def test_passkey_challenge_expiry_and_rename_keeps_user_handle(self):
        self.login();fixture=self.register_key()
        options=self.post('/passkeys/login/options',{}).json
        with self.module.db() as c:c.execute('UPDATE challenges SET expires=0 WHERE id=?',(options['request_id'],))
        self.assertEqual(self.post('/passkeys/login/verify',dict(request_id=options['request_id'],credential=self.assertion(fixture,options['options']))).status_code,400)
        result=self.post('/account',dict(username='renamed-admin',new_password='',current_password='test-secret-123'))
        self.assertEqual(result.status_code,200);self.csrf=result.json['csrf']
        self.assertEqual(self.key_login(fixture).status_code,200)
        self.assertEqual(self.client.get('/update-admin/api/account').json['username'],'renamed-admin')


    def test_announcement_lifecycle_never_exposes_drafts(self):
        self.login()
        self.assertIsNone(self.client.get('/update-admin/notices.json').json['announcement'])
        self.assertEqual(self.post('/announcement/save', dict(revision=0, title='维护通知', body='今晚维护')).status_code, 200)
        self.assertIsNone(self.client.get('/update-admin/notices.json').json['announcement'])
        self.assertEqual(self.post('/announcement/publish', dict(revision=1)).status_code, 200)
        self.post('/announcement/save', dict(revision=2, title='未发布草稿', body='请勿公开'))
        live = self.client.get('/update-admin/notices.json').json['announcement']
        self.assertEqual(live['title'], '维护通知')
        self.assertEqual(live['body'], '今晚维护')
        self.assertEqual(self.post('/announcement/withdraw', dict(revision=3)).status_code, 200)
        self.assertIsNone(self.client.get('/update-admin/notices.json').json['announcement'])
        self.assertEqual(self.client.get('/update-admin/api/announcement').json['title'], '未发布草稿')

    def test_announcement_uses_session_csrf_origin_and_conflict_guards(self):
        self.assertEqual(self.client.get('/update-admin/api/announcement').status_code, 401)
        self.assertEqual(self.post('/announcement/publish', dict(revision=0)).status_code, 401)
        self.login()
        path='/update-admin/api/announcement/save'
        self.assertEqual(self.client.post(path, json={}).status_code, 403)
        self.assertEqual(self.client.post(path, json={}, headers={'X-CSRF-Token': self.csrf, 'Origin':'https://evil.example'}).status_code, 403)
        self.assertEqual(self.post('/announcement/save', dict(revision=99,title='标题',body='正文')).status_code, 409)
        self.assertEqual(self.post('/announcement/publish', dict(revision=0)).status_code, 400)

    def test_announcement_plain_text_limits_and_audit(self):
        self.login()
        self.assertEqual(self.post('/announcement/save', dict(revision=0,title='标题',body='长'*2001)).status_code, 400)
        self.assertEqual(self.post('/announcement/save', dict(revision=0,title='标题',body='\x00')).status_code, 400)
        body='<script>alert("x")</script>\n公告纯文本'
        self.assertEqual(self.post('/announcement/save', dict(revision=0,title='标题',body=body)).status_code, 200)
        self.post('/announcement/publish', dict(revision=1))
        response=self.client.get('/update-admin/notices.json')
        self.assertEqual(response.mimetype, 'application/json')
        self.assertEqual(response.json['announcement']['body'], body)
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        with self.module.db() as c:
            self.assertEqual(c.execute('SELECT action FROM events ORDER BY id DESC LIMIT 1').fetchone()['action'], '发布客户端公告')


    def test_announcement_custom_typography_and_colors(self):
        self.login()
        item=dict(id='custom',title='自定义标题',body='磨砂通知',theme='frosted',title_font='serif',title_size=18,title_weight='bold',title_color='#26785b',icon_color='#85510b')
        self.assertEqual(self.post('/announcement/save',dict(revision=0,items=[item])).status_code,200)
        self.assertEqual(self.client.get('/update-admin/api/announcement').json['items'][0]['title_color'],'#26785B')
        self.assertEqual(self.client.get('/update-admin/notices.json?protocol=2').json['announcements'],[])
        self.assertEqual(self.post('/announcement/publish',dict(revision=1)).status_code,200)
        live=self.client.get('/update-admin/notices.json?protocol=2').json['announcements'][0]
        self.assertEqual((live['theme'],live['title_font'],live['title_size'],live['title_weight'],live['icon_color']),('frosted','serif',18,'bold','#85510B'))
        for field,value in [('title_font','https://evil.example/font'),('title_size',200),('title_size',True),('title_weight','999'),('title_color','red;display:none'),('icon_color','#12345678')]:
            self.assertEqual(self.post('/announcement/save',dict(revision=2,items=[dict(item,**{field:value})])).status_code,400)
        self.assertEqual(self.client.get('/update-admin/notices.json').json['announcement']['title'],'自定义标题')

    def test_multi_notice_themes_rotation_and_legacy_feed(self):
        self.login()
        items=[dict(id='a',title='安全提醒',body='保留密码验证',theme='glass',icon='shield',motion='breathe',enabled=True),dict(id='b',title='维护通知',body='后台草稿',theme='titanium',icon='wrench',motion='fade',enabled=False),dict(id='c',title='使用技巧',body='使用 IP 直连',theme='obsidian',icon='network',motion='none',enabled=True)]
        self.assertEqual(self.post('/announcement/save',dict(revision=0,items=items,interval_seconds=10)).status_code,200)
        self.assertEqual(self.client.get('/update-admin/notices.json?protocol=2').json['announcements'],[])
        self.assertEqual(self.post('/announcement/publish',dict(revision=1)).status_code,200)
        feed=self.client.get('/update-admin/notices.json?protocol=2').json
        self.assertEqual([i['id'] for i in feed['announcements']],['a','c'])
        self.assertEqual(feed['interval_seconds'],10)
        self.assertEqual(feed['announcements'][0]['theme'],'glass')
        self.assertEqual(self.client.get('/update-admin/notices.json').json['announcement']['title'],'安全提醒')
        items.reverse();self.post('/announcement/save',dict(revision=2,items=items,interval_seconds=5))
        self.assertEqual(self.client.get('/update-admin/notices.json?protocol=2').json,feed)
        self.assertEqual(self.post('/announcement/save',dict(revision=3,title='旧页面',body='不能覆盖列表')).status_code,409)
        self.assertEqual(self.post('/announcement/withdraw',dict(revision=3)).status_code,200)
        self.assertEqual(self.client.get('/update-admin/notices.json?protocol=2').json['announcements'],[])

    def test_notice_style_validation_and_legacy_migration(self):
        self.login()
        with self.module.db() as c:
            c.execute("UPDATE announcement SET title='已有草稿',body='草稿正文',published_title='已有通知',published_body='原始正文',published_at=123 WHERE id=1")
        self.assertEqual(self.client.get('/update-admin/notices.json?protocol=2').json['announcements'][0]['id'],'legacy')
        self.assertEqual(self.client.get('/update-admin/api/announcement').json['items'][0]['title'],'已有草稿')
        valid=dict(id='test',title='标题',body='正文',theme='glass',icon='bell',motion='fade')
        for invalid in [dict(valid,theme='html'),dict(valid,icon='<svg>'),dict(valid,motion='script'),dict(valid,enabled='yes')]:
            self.assertEqual(self.post('/announcement/save',dict(revision=0,items=[invalid])).status_code,400)
        self.assertEqual(self.post('/announcement/save',dict(revision=0,items=[valid,valid])).status_code,400)
        self.assertEqual(self.post('/announcement/save',dict(revision=0,items=[valid],interval_seconds=1)).status_code,400)
        self.assertEqual(self.post('/announcement/save',dict(revision=0,items=[])).status_code,200)
        self.assertEqual(self.post('/announcement/publish',dict(revision=1)).status_code,400)
        self.assertEqual(self.client.get('/update-admin/notices.json').json['announcement']['title'],'已有通知')


    def test_retention_physically_removes_older_packages_and_keeps_audit(self):
        self.login()
        unrelated=self.public/'unrelated.txt';unrelated.write_text('keep')
        for build in [401,402,403]:
            data,_=self.archive(build)
            self.assertEqual(self.upload(data).status_code,200)
            result=self.post(f'/publish/{build}',{})
            self.assertEqual(result.status_code,200,result.json)
            self.assertEqual(result.json['cleanup']['failed'],[])
        self.assertFalse((self.public/'releases/401').exists())
        self.assertTrue((self.public/'releases/402').is_dir())
        self.assertTrue((self.public/'releases/403').is_dir())
        self.assertEqual(unrelated.read_text(),'keep')
        with self.module.db() as c:
            self.assertIsNone(c.execute('SELECT * FROM releases WHERE build=401').fetchone())
            self.assertTrue(c.execute("SELECT 1 FROM events WHERE build=401 AND action LIKE '物理清理%' ").fetchone())

    def portal_configure(self):
        self.login()
        with self.module.db() as c:
            c.executescript('DELETE FROM download_queue;DELETE FROM download_limits;')
        config=dict(site_key='0x4AAAAAAAA-site-test',secret='private-turnstile-test-secret',concurrency=2,rate_kib=512,queue_limit=40,current_password='test-secret-123')
        result=self.post('/download-settings',config)
        self.assertEqual(result.status_code,200,result.json)
        self.assertNotIn(config['secret'],result.data.decode())
        return config

    def portal_client(self,ip):
        client=self.app.test_client()
        catalog=client.get('/downloads/api/catalog',environ_base={'REMOTE_ADDR':ip})
        self.assertEqual(catalog.status_code,200,catalog.json)
        a=next(a for a in catalog.json['packages'] if a['platform']=='windows')
        headers={'Origin':'http://localhost','X-Download-Token':catalog.json['csrf']}
        return client,a,headers

    def test_portal_a_verification_settings_and_cookie_guards(self):
        config=self.portal_configure()
        client,artifact,headers=self.portal_client('198.51.100.1')
        self.assertEqual(self.client.get('/update-admin/api/download-settings').json['site_key'],config['site_key'])
        self.assertNotIn('secret',self.client.get('/update-admin/api/download-settings').json)
        body=dict(artifact=artifact['id'],token='invalid')
        self.assertEqual(client.post('/downloads/api/join',json=body,environ_base={'REMOTE_ADDR':'198.51.100.1'}).status_code,400)
        with patch.object(self.module.download_portal,'verify_turnstile',return_value=False):
            self.assertEqual(client.post('/downloads/api/join',json=body,headers=headers,environ_base={'REMOTE_ADDR':'198.51.100.1'}).status_code,400)
        from types import SimpleNamespace
        for hostname,action,expected in [('localhost','software_download',True),('attacker.example','software_download',False),('localhost','another_form',False)]:
            opener=SimpleNamespace(open=lambda *args,hostname=hostname,action=action,**kw:io.BytesIO(json.dumps(dict(success=True,hostname=hostname,action=action)).encode()))
            with self.app.test_request_context(), patch('download_portal.urllib.request.build_opener',return_value=opener):
                self.assertEqual(self.module.download_portal.verify_turnstile('fixture',config),expected)
                self.assertFalse(self.module.download_portal.verify_turnstile('fixture',config,action='admin_login'))
        with client.get('/downloads/') as response:
            self.assertEqual(response.status_code,200)
            self.assertIn('https://challenges.cloudflare.com',response.headers['Content-Security-Policy'])
        self.assertEqual(client.post('/downloads/api/join',json={'artifact':{}},headers=headers,environ_base={'REMOTE_ADDR':'198.51.100.1'}).status_code,400)

    def test_portal_b_fifo_stream_completion_and_one_use_ticket(self):
        self.portal_configure()
        visitors=[]
        with patch.object(self.module.download_portal,'verify_turnstile',return_value=True):
            for i in range(3):
                ip=f'198.51.100.{10+i}';client,a,headers=self.portal_client(ip)
                result=client.post('/downloads/api/join',json=dict(artifact=a['id'],token='fixture-token'),headers=headers,environ_base={'REMOTE_ADDR':ip})
                self.assertEqual(result.status_code,200,result.json)
                self.assertEqual(result.json['status'],'ready' if i<2 else 'waiting')
                visitors.append((client,a,headers,ip,result.json))
        client,a,headers,ip,state=visitors[0]
        self.assertEqual(client.get(state['download'],headers={'Range':'bytes=0-1'},environ_base={'REMOTE_ADDR':ip}).status_code,416)
        with client.get(state['download'],environ_base={'REMOTE_ADDR':ip}) as response:
            self.assertEqual(response.status_code,200)
            self.assertEqual(len(response.data),a['size'])
            self.assertEqual(hashlib.sha256(response.data).hexdigest(),a['sha256'])
        self.assertEqual(client.get(state['download'],environ_base={'REMOTE_ADDR':ip}).status_code,400)
        next_client,_,_,next_ip,_=visitors[2]
        self.assertEqual(next_client.get('/downloads/api/status',environ_base={'REMOTE_ADDR':next_ip}).json['status'],'ready')
        thief,_,_=self.portal_client('198.51.100.99')
        self.assertEqual(thief.get(visitors[1][4]['download'],environ_base={'REMOTE_ADDR':'198.51.100.99'}).status_code,400)
        second,_,_,second_ip,second_state=visitors[1]
        response=second.get(second_state['download'],environ_base={'REMOTE_ADDR':second_ip},buffered=False)
        self.assertEqual(response.status_code,200)
        response.close()
        self.assertEqual(second.get('/downloads/api/status',environ_base={'REMOTE_ADDR':second_ip}).json['status'],'interrupted')

    def test_portal_c_expiry_and_cancel_release_queue_slots(self):
        self.portal_configure()
        clients=[]
        with patch.object(self.module.download_portal,'verify_turnstile',return_value=True):
            for i in range(3):
                ip=f'198.51.100.{30+i}';client,a,headers=self.portal_client(ip)
                result=client.post('/downloads/api/join',json=dict(artifact=a['id'],token='fixture'),headers=headers,environ_base={'REMOTE_ADDR':ip})
                self.assertEqual(result.status_code,200,result.json);clients.append((client,headers,ip))
        with self.module.db() as c:c.execute("UPDATE download_queue SET deadline=1 WHERE status='ready'")
        client,headers,ip=clients[-1]
        self.assertEqual(client.get('/downloads/api/status',environ_base={'REMOTE_ADDR':ip}).json['status'],'ready')
        self.assertEqual(client.post('/downloads/api/cancel',json={},headers=headers,environ_base={'REMOTE_ADDR':ip}).status_code,200)
        self.assertEqual(client.get('/downloads/api/status',environ_base={'REMOTE_ADDR':ip}).json['status'],'cancelled')
        client,_,ip=clients[0]
        self.assertEqual(client.get('/downloads/api/status',environ_base={'REMOTE_ADDR':ip}).json['status'],'expired')

if __name__=='__main__':unittest.main()
