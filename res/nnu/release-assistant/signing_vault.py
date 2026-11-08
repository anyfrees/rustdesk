"""Private signing material encrypted for the current Windows account."""
import ctypes
import os
import sys
from ctypes import wintypes
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]


def protect(data, decrypt=False):
    if os.name != 'nt':
        raise ValueError('内置密钥库仅适用于 Windows。')
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    output = Blob()
    crypt = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if decrypt:
        function = crypt.CryptUnprotectData
        function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        result = function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output))
    else:
        function = crypt.CryptProtectData
        function.argtypes = [ctypes.POINTER(Blob), wintypes.LPCWSTR, ctypes.c_void_p,
                             ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        result = function(ctypes.byref(source), 'NNU release signing key', None, None, None, 1, ctypes.byref(output))
    try:
        if not result:
            raise ValueError('无法解密本机密钥。更换 Windows 账户或电脑后，请通过密钥备份恢复。' if decrypt else '无法将密钥保存到 Windows 加密库。')
        return ctypes.string_at(output.data, output.size)
    finally:
        ctypes.memset(buffer, 0, len(data))
        if output.data:
            ctypes.memset(output.data, 0, output.size)
            kernel.LocalFree(ctypes.cast(output.data, ctypes.c_void_p))


def vault_path():
    return Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'NNU/ReleaseAssistant/signing-key.dpapi'


def embedded_path():
    return Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'signing-key.dpapi'


def available():
    return vault_path().is_file() or bool(embedded_blob())


def embedded_blob():
    try:
        from embedded_signing_key import ENCRYPTED_KEY
        return ENCRYPTED_KEY
    except ImportError:
        return embedded_path().read_bytes() if embedded_path().is_file() else None


def read():
    encrypted = vault_path().read_bytes() if vault_path().is_file() else embedded_blob()
    if not encrypted:
        raise ValueError('没有内置签名密钥，请在设置中导入或恢复密钥。')
    return protect(encrypted, decrypt=True)


def store(pem):
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError('请选择 Ed25519 签名密钥。')
    raw = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    encrypted = protect(raw)
    path = vault_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix('.next')
    pending.write_bytes(encrypted)
    os.replace(pending, path)


def export_backup(path, password):
    if not 12 <= len(password) <= 128:
        raise ValueError('备份密码需为 12–128 个字符。')
    key = serialization.load_pem_private_key(read(), password=None)
    import android_signing
    if android_signing.available():
        import base64,json
        from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        salt=os.urandom(16);nonce=os.urandom(12)
        derived=Scrypt(salt=salt,length=32,n=32768,r=8,p=1).derive(password.encode('utf-8'))
        payload=json.dumps({'update':base64.b64encode(read()).decode(),'android':base64.b64encode(android_signing.read()).decode()}).encode()
        content=b'NNU-KEYS-V2\0'+salt+nonce+AESGCM(derived).encrypt(nonce,payload,b'NNU-KEYS-V2')
    else:
        content = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.BestAvailableEncryption(password.encode('utf-8')))
    with Path(path).open('xb') as f:
        f.write(content)


def restore_backup(path, password):
    try:
        data=Path(path).read_bytes()
        if data.startswith(b'NNU-KEYS-V2\0'):
            payload=read_combined_backup(path,password)
            key=serialization.load_pem_private_key(payload['update'],password=None)
        else:
            key = serialization.load_pem_private_key(data, password=password.encode('utf-8'))
    except Exception as exc:
        raise ValueError('无法读取备份，请检查文件和备份密码。') from exc
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def read_combined_backup(path,password):
    import base64,json
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    data=Path(path).read_bytes();prefix=b'NNU-KEYS-V2\0'
    if len(data)>262144 or not data.startswith(prefix):raise ValueError('多平台密钥备份格式无效')
    offset=len(prefix);salt=data[offset:offset+16];nonce=data[offset+16:offset+28]
    derived=Scrypt(salt=salt,length=32,n=32768,r=8,p=1).derive(password.encode('utf-8'))
    payload=json.loads(AESGCM(derived).decrypt(nonce,data[offset+28:],b'NNU-KEYS-V2'))
    return {name:base64.b64decode(value,validate=True) for name,value in payload.items()}


def restore_android_backup(path,password):
    if Path(path).read_bytes().startswith(b'NNU-KEYS-V2\0'):
        import android_signing
        android_signing.store(read_combined_backup(path,password)['android'])


class PrivateKeySource:
    def __init__(self, raw):
        self.raw = raw

    def read_bytes(self):
        return self.raw
