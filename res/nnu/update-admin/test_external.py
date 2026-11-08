import base64
import hashlib
import io
import json
import tempfile
import sys
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import external_download
import release
from delegation import ExternalSigner
import test_admin


class RedirectTests(unittest.TestCase):
    def inspect(self, replies, dns):
        connections = []
        class Connection:
            def __init__(self, host, address, timeout):
                connections.append((host, address))
            def request(self, *args, **kwargs): pass
            def getresponse(self):
                status, headers, body = replies.pop(0)
                response = io.BytesIO(body)
                response.status = status
                response.getheader = lambda name, default=None: headers.get(name, default)
                return response
            def close(self): pass
        with patch.object(external_download, 'PinnedHTTPS', Connection), patch.object(external_download.socket, 'getaddrinfo', side_effect=dns):
            result = external_download.inspect_download('https://drive.example/download?id=123', 'portable')
        return result, connections

    def test_redirect_download_hashes_real_installer_and_keeps_stable_entry_url(self):
        body = b'MZ' + b'fixture executable' * 10
        result, connections = self.inspect([(302, {'Location': 'https://cdn.example/file?temporary=abc'}, b''),
            (200, {'Content-Type': 'application/octet-stream', 'Content-Length': str(len(body))}, body)],
            lambda host, *a, **k: [(2, 1, 6, '', ('8.8.8.8', 443))])
        self.assertEqual(result, {'size': len(body), 'sha256': hashlib.sha256(body).hexdigest(), 'mirrors': ['https://drive.example/download?id=123']})
        self.assertEqual(connections, [('drive.example', '8.8.8.8'), ('cdn.example', '8.8.8.8')])

    def test_private_redirect_downgrade_and_share_page_are_rejected(self):
        for destination in ('http://cdn.example/file', 'https://private.example/file'):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                self.inspect([(302, {'Location': destination}, b'')], lambda host, *a, **k:
                    [(2, 1, 6, '', ('127.0.0.1' if host == 'private.example' else '8.8.8.8', 443))])
        for mime, body in [('text/html', b'<html>login</html>'), ('application/octet-stream', b'not an executable')]:
            with self.subTest(mime=mime), self.assertRaises(ValueError):
                self.inspect([(200, {'Content-Type': mime}, body)], lambda *a, **k: [(2, 1, 6, '', ('8.8.8.8', 443))])


class ExternalPublicationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.modules.pop('app', None)
        test_admin.AdminTest.setUpClass()

    @classmethod
    def tearDownClass(cls):
        test_admin.AdminTest.tearDownClass()

    def test_web_external_release_is_certified_and_legacy_feed_keeps_bootstrap(self):
        fixture = test_admin.AdminTest(); fixture.setUp(); fixture.login()
        app = fixture.module
        with tempfile.TemporaryDirectory() as temp:
            public = Path(temp) / 'public'; public.mkdir(); (public / 'releases').mkdir()
            staging = public / '.admin-staging'; staging.mkdir()
            signer = ExternalSigner(Path(temp))
            claims = json.dumps(dict(schema=1, purpose='nnu-external-updates', origin='https://rd.nnu.cn', public_key=signer.public_key())).encode()
            certificate = dict(payload=base64.b64encode(claims).decode(), signature=base64.b64encode(fixture.key.sign(claims)).decode())
            signer.certificate_path.write_text(json.dumps(certificate))
            with patch.object(app, 'PUBLIC', public), patch.object(app, 'STAGING', staging), patch.object(app, 'external_signer', signer):
                local, raw = fixture.archive(91200)
                fixture.assertEqual(fixture.upload(local).status_code, 200)
                fixture.assertEqual(fixture.post('/publish/91200', {}).status_code, 200)
                urls = {kind: f'https://drive.example/{kind}' for kind in ('portable', 'install', 'msi', 'zip')}
                def inspect(url, kind): return dict(size=100, sha256='a' * 64, mirrors=[url])
                with patch.object(app, 'inspect_download', side_effect=inspect):
                    response = fixture.post('/external', dict(build=91201, version='NNU external', notes='测试外链', urls=urls))
                fixture.assertEqual(response.status_code, 200, response.json)
                fixture.assertEqual(fixture.post('/publish/91201', {}).status_code, 200)
                fixture.assertEqual(fixture.client.get('/feed').data, raw)
                external = fixture.client.get('/feed?protocol=2').data
                fixture.assertEqual(release.verify_manifest(external)['delivery'], 'external')
                fixture.assertFalse((public / 'releases/91201').exists())
                fixture.assertEqual(fixture.client.get('/update-admin/api/overview').json['current']['build'], 91201)
                tampered = json.loads(external); tampered['certificate']['signature'] = base64.b64encode(b'0' * 64).decode()
                with fixture.assertRaises(ValueError): release.verify_manifest(json.dumps(tampered).encode())


if __name__ == '__main__': unittest.main()
