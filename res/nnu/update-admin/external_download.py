"""Bounded HTTPS checks with DNS pinning and redirect validation on every hop."""
import hashlib
import http.client
import ipaddress
import socket
import ssl
import time
from urllib.parse import urljoin, urlsplit

MAX_PACKAGE = 512 * 1024 * 1024


def validate_url(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 4096 or any(ord(c) <= 32 or c == '\\' for c in value):
        raise ValueError('请填写有效的 HTTPS 下载地址')
    try:
        url = urlsplit(value)
        if (url.scheme != 'https' or not url.hostname or url.port not in (None, 443)
                or url.username is not None or url.password is not None or url.fragment):
            raise ValueError()
        hostname = url.hostname.encode('idna').decode('ascii')
        if hostname.lower() == 'localhost' or hostname.endswith('.'):
            raise ValueError()
        return url, hostname
    except (ValueError, UnicodeError) as exc:
        raise ValueError('仅支持无账号密码、无片段标识的 HTTPS 443 下载链接') from exc


def public_addresses(hostname):
    try:
        addresses = list(dict.fromkeys(item[4][0] for item in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)))
    except OSError as exc:
        raise ValueError('下载域名解析失败，请检查地址') from exc
    if not addresses:
        raise ValueError('下载域名没有可用地址')
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if not ip.is_global or ip.is_multicast or ip.is_unspecified or getattr(ip, 'ipv4_mapped', None):
            raise ValueError('下载链接不能指向内网、本机或保留地址')
    return addresses


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, hostname, address, timeout):
        super().__init__(hostname, timeout=timeout, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, 443), timeout=self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except Exception:
            raw.close()
            raise


def inspect_download(value, kind):
    current = value
    started = time.monotonic()
    magic = {'portable': b'MZ', 'install': b'MZ', 'msi': bytes.fromhex('d0cf11e0a1b11ae1'), 'zip': b'PK\x03\x04'}[kind]
    for hop in range(6):
        url, hostname = validate_url(current)
        addresses = public_addresses(hostname)
        connection = None
        response = None
        try:
            for address in addresses[:3]:
                connection = PinnedHTTPS(hostname, address, 10)
                try:
                    target = (url.path or '/') + ('?' + url.query if url.query else '')
                    connection.request('GET', target, headers={'Accept-Encoding': 'identity', 'User-Agent': 'NNU-Release-Verification/1'})
                    response = connection.getresponse()
                    break
                except (OSError, http.client.HTTPException):
                    connection.close()
            if response is None:
                raise ValueError('无法连接下载地址，请确认外网可直接访问且证书有效')
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader('Location')
                if not location or hop == 5:
                    raise ValueError('下载跳转缺少地址或次数过多')
                current = urljoin(current, location)
                continue
            if response.status != 200:
                raise ValueError(f'下载地址返回 HTTP {response.status}，请使用无需登录的直链')
            mime = response.getheader('Content-Type', '').split(';')[0].strip().lower()
            if mime in ('text/html', 'application/xhtml+xml', 'application/json') or response.getheader('Content-Encoding', 'identity') not in ('identity', ''):
                raise ValueError('链接返回网页或接口数据，请填写可跳转到安装文件的地址')
            length = response.getheader('Content-Length')
            if length and (not length.isdigit() or not 0 < int(length) <= MAX_PACKAGE):
                raise ValueError('下载文件为空或超过 512 MB')
            digest = hashlib.sha256()
            size = 0
            prefix = b''
            while True:
                if time.monotonic() - started > 120:
                    raise ValueError('下载校验超过两分钟，请检查网盘速度或稍后重试')
                block = response.read(1024 * 1024)
                if not block:
                    break
                size += len(block)
                if size > MAX_PACKAGE:
                    raise ValueError('安装包超过 512 MB')
                prefix = (prefix + block[:8])[:8]
                if size == len(block) and not prefix.startswith(magic):
                    raise ValueError('下载内容与安装包类型不符，不能使用网页、登录页或错误页面')
                digest.update(block)
            if not size or length and size != int(length):
                raise ValueError('文件下载不完整，请重新校验')
            return {'size': size, 'sha256': digest.hexdigest(), 'mirrors': [value]}
        except (OSError, http.client.HTTPException, UnicodeError) as exc:
            raise ValueError('下载校验失败，请确认网盘链接有效且可从公网访问') from exc
        finally:
            if response is not None:
                response.close()
            if connection is not None:
                connection.close()
    raise ValueError('下载跳转次数过多')
