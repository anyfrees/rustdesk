"""A separate persistent APK identity, protected with the Windows account vault."""
import base64,json,os
from pathlib import Path
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.hazmat.primitives import hashes
import signing_vault

def vault_path():
    return signing_vault.vault_path().with_name('android-signing.dpapi')

def embedded():
    try:
        from embedded_signing_key import ENCRYPTED_ANDROID_KEY
        return ENCRYPTED_ANDROID_KEY
    except ImportError:return None

def available():return vault_path().is_file() or bool(embedded())

def validate(raw):
    data=json.loads(raw)
    blob=base64.b64decode(data['keystore'],validate=True)
    if len(blob)>131072 or not 12<=len(data['password'])<=128 or data['alias']!='nnu-android':raise ValueError('安卓签名密钥格式无效')
    key,cert,_=pkcs12.load_key_and_certificates(blob,data['password'].encode())
    if not key or not cert or key.key_size<3072 or key.public_key().public_numbers()!=cert.public_key().public_numbers():raise ValueError('安卓签名证书与私钥不匹配')
    fingerprint=cert.fingerprint(hashes.SHA256()).hex()
    if data.get('certificate_sha256',fingerprint)!=fingerprint:raise ValueError('安卓签名证书摘要不匹配')
    data['certificate_sha256']=fingerprint
    return json.dumps(data).encode()

def read():
    data=vault_path().read_bytes() if vault_path().is_file() else embedded()
    if not data:raise ValueError('安卓发布签名尚未初始化')
    return validate(signing_vault.protect(data,True))

def store(raw):
    raw=validate(raw)
    if available() and json.loads(read())['certificate_sha256']!=json.loads(raw)['certificate_sha256']:
        raise ValueError('安卓签名与现有应用不匹配，已保留原密钥')
    encrypted=signing_vault.protect(raw);path=vault_path();path.parent.mkdir(parents=True,exist_ok=True)
    pending=path.with_suffix('.next');pending.write_bytes(encrypted);os.replace(pending,path)
