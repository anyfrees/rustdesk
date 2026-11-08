"""Only the external publisher key is online; the root update key stays offline."""
import base64
import json
import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.exceptions import InvalidSignature


def certified_key(certificate, root):
    encoded = json.dumps(certificate).encode()
    if len(encoded) > 4096:
        raise ValueError('外链发布签名证书过大')
    payload = base64.b64decode(certificate['payload'], validate=True)
    signature = base64.b64decode(certificate['signature'], validate=True)
    Ed25519PublicKey.from_public_bytes(base64.b64decode(root, validate=True)).verify(signature, payload)
    claims = json.loads(payload)
    if (claims.get('schema') != 1 or claims.get('purpose') != 'nnu-external-updates'
            or claims.get('origin') != 'https://rd.nnu.cn'):
        raise ValueError('外链发布签名证书用途不正确')
    return Ed25519PublicKey.from_public_bytes(base64.b64decode(claims['public_key'], validate=True))


class ExternalSigner:
    def __init__(self, state):
        self.path = Path(state) / 'external-signing-key.pem'
        self.certificate_path = Path(state) / 'external-certificate.json'
        if not self.path.exists():
            key = Ed25519PrivateKey.generate()
            data = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
            descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(data)
        os.chmod(self.path, 0o600)
        self.key = serialization.load_pem_private_key(self.path.read_bytes(), password=None)
        if not isinstance(self.key, Ed25519PrivateKey):
            raise ValueError('外链发布签名密钥类型错误')

    def public_key(self):
        return base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()

    def certificate(self, root):
        certificate = json.loads(self.certificate_path.read_text())
        verified = certified_key(certificate, root)
        if verified.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw) != self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw):
            raise ValueError('外链发布证书与密钥不匹配')
        return certificate

    def ready(self, root):
        try:
            self.certificate(root)
            return True
        except (ValueError, KeyError, OSError, InvalidSignature):
            return False

    def sign(self, manifest, root):
        certificate = self.certificate(root)
        payload = json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode()
        return json.dumps({'payload': base64.b64encode(payload).decode(),
                           'signature': base64.b64encode(self.key.sign(payload)).decode(),
                           'certificate': certificate}, separators=(',', ':')).encode()
