"""Share an opaque mobile setup code only with active console users."""
import json
import re
import threading
import urllib.request

from flask import jsonify, request
from werkzeug.exceptions import TooManyRequests


class MobileImport:
    def __init__(self, app, portal, state, origin):
        self.portal, self.origin = portal, origin
        self.path = state / 'mobile-import.txt'
        self.checks = threading.BoundedSemaphore(2)
        app.add_url_rule('/downloads/api/mobile-import', 'mobile_import', self.get)

    def active_user(self, token):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        req = urllib.request.Request(self.origin + '/api/admin/user/current',
                                     headers={'api-token': token, 'Accept': 'application/json'})
        with opener.open(req, timeout=4) as response:
            result = json.loads(response.read(65536))
        return (isinstance(result, dict) and result.get('code') == 0
                and isinstance(result.get('data'), dict)
                and isinstance(result['data'].get('username'), str)
                and bool(result['data']['username']))

    def get(self):
        response = self.read()
        response[0].headers['Cache-Control'] = 'private, no-store'
        return response

    def read(self):
        token = request.headers.get('api-token', '')
        if (not token or len(token) > 4096 or not token.isascii()
                or request.headers.get('Origin') not in (None, self.origin)):
            return jsonify(error='请先登录'), 401
        self.portal.limit('mobile-import', self.portal.digest(request.remote_addr), 30)
        if not self.checks.acquire(blocking=False):
            raise TooManyRequests('请求繁忙，请稍后重试')
        try:
            try:
                valid = self.active_user(token)
            except (OSError, ValueError):
                return jsonify(error='登录验证暂不可用，请稍后重试'), 503
            if not valid:
                return jsonify(error='登录已失效，请重新登录'), 401
            try:
                with self.path.open('r', encoding='utf-8-sig') as stream:
                    code = stream.read(4097).strip()
                if not re.fullmatch(r'[A-Za-z0-9+/=_:-]{1,4096}', code):
                    raise ValueError('Invalid setup code')
            except (OSError, ValueError):
                return jsonify(error='手机配置暂不可用'), 503
            return jsonify(code=code), 200
        finally:
            self.checks.release()
