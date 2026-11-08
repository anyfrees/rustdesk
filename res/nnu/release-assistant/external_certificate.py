"""Authorize only a public server publishing key; never export the root private key."""
import base64
import json
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from engine import signing_material, validate_key


def authorize(settings, public_key, destination):
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('服务器发布公钥长度不正确')
    validate_key(settings)
    key = serialization.load_pem_private_key(signing_material(settings), password=None)
    payload = json.dumps({'schema': 1, 'purpose': 'nnu-external-updates',
                          'origin': 'https://rd.nnu.cn', 'public_key': public_key}, separators=(',', ':')).encode()
    certificate = {'payload': base64.b64encode(payload).decode(), 'signature': base64.b64encode(key.sign(payload)).decode()}
    with Path(destination).open('x', encoding='utf-8') as output:
        json.dump(certificate, output, separators=(',', ':'))
    return certificate
