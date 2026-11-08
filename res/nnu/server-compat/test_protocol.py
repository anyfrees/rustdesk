"""Exercise staged RustDesk servers only; never touches production device records."""
import base64
import os
import secrets
import socket
import time
import uuid

from nacl.public import PrivateKey, Box
from nacl.secret import SecretBox
from nacl.signing import SigningKey, VerifyKey
from nacl.exceptions import BadSignatureError

TOKEN = os.environ['NNU_TEST_TOKEN']
PUBLIC = base64.b64decode(os.environ['NNU_SIGNING_PUBLIC_KEY'])


def varint(n):
    result = bytearray()
    while n > 127:
        result.append((n & 127) | 128); n >>= 7
    result.append(n)
    return bytes(result)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str): value = value.encode()
    return varint(number << 3 | 2) + varint(len(value)) + value


def fields(data):
    position = 0; result = {}
    def read():
        nonlocal position
        value = 0; shift = 0
        while True:
            byte = data[position]; position += 1
            value |= (byte & 127) << shift
            if byte < 128: return value
            shift += 7
    while position < len(data):
        tag = read(); number, wire = tag >> 3, tag & 7
        if wire == 0: result[number] = read()
        elif wire == 2:
            length = read(); result[number] = data[position:position+length]; position += length
        else: raise AssertionError('Unexpected staged protocol wire type')
    return result


def send_frame(connection, payload):
    for size in range(1, 5):
        if len(payload) < 1 << (size * 8 - 2):
            connection.sendall(((len(payload) << 2) | (size-1)).to_bytes(size,'little')+payload)
            return
    raise AssertionError('Test payload too large')


def receive_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length-len(result))
        if not chunk: raise AssertionError('Unexpected EOF from staged server')
        result.extend(chunk)
    return bytes(result)


def receive_frame(connection):
    first = receive_exact(connection,1); size = (first[0] & 3)+1
    length = int.from_bytes(first+receive_exact(connection,size-1),'little') >> 2
    assert length <= 65536
    return receive_exact(connection,length)


def staged_connection(port):
    assert port in (32176,32177,32186), 'Production endpoint forbidden in protocol tests'
    source = None
    if port == 32177:
        # Upstream hbbr reserves loopback clients for its text command socket.
        # Bind the local interface address while keeping the destination local.
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as probe:
            probe.connect(('192.0.2.1',9))
            source = (probe.getsockname()[0],0)
        assert not source[0].startswith('127.'), 'Relay test requires a local non-loopback interface'
    connection = socket.create_connection(('127.0.0.1',port),timeout=5,source_address=source)
    connection.settimeout(5)
    return connection


def signed_peer(port, version, suffix, controller_key=None):
    assert port in (32176,32186)
    identity = str(991000000 + secrets.randbelow(1000000))
    signing = SigningKey.generate()
    peer = socket.socket(socket.AF_INET,socket.SOCK_DGRAM); peer.settimeout(5)
    peer.connect(('127.0.0.1',port))
    try:
        peer.send(field(15,field(1,identity)+field(2,secrets.token_bytes(16))+field(3,bytes(signing.verify_key))))
        registered = fields(fields(peer.recv(65536))[16])
        assert registered.get(1,0) == 0,'Legacy public-key registration rejected'
        with staged_connection(port) as controller:
            send_frame(controller,field(8,field(1,identity)+field(3,TOKEN if controller_key is None else controller_key)+field(6,version)))
            request = fields(peer.recv(65536))
            if 12 in request:
                address = fields(request[12])[1]
                reply = field(13,field(1,address)+field(2,address)+field(4,identity)+field(5,version))
            elif 9 in request:
                address = fields(request[9])[1]
                reply = field(10,field(1,address)+field(2,identity)+field(5,version))
            else: raise AssertionError('Legacy punch request format changed')
            with staged_connection(port) as peer_response:
                send_frame(peer_response, reply)
                response = fields(fields(receive_frame(controller))[11])
            return identity,signing,response.get(2,b'')
    finally: peer.close()


def relay_pair(left_key=None, right_key=None):
    left,right = staged_connection(32177),staged_connection(32177)
    name = str(uuid.uuid4())
    for connection,key in [(left,left_key),(right,right_key)]:
        send_frame(connection,field(18,field(2,name)+field(6,TOKEN if key is None else key)))
        # Model the separate peers' rendezvous round trip. Sending both relay
        # requests simultaneously on loopback can race upstream PEERS insertion.
        time.sleep(0.05)
    return left,right


def main():
    _,_,unsigned = signed_peer(32186,'1.2.3','01')
    assert not unsigned,'Feature-off server changed legacy signing behavior'
    print('PASS: signing disabled preserves original legacy response',flush=True)
    identity,peer_signing,signed = signed_peer(32176,'1.2.3','02')
    signed_identity = fields(VerifyKey(PUBLIC).verify(signed))
    assert signed_identity[1].decode() == identity and signed_identity[2] == bytes(peer_signing.verify_key)
    modern,_,modern_signed = signed_peer(32176,'1.5.0','03')
    assert fields(VerifyKey(PUBLIC).verify(modern_signed))[1].decode() == modern
    print('PASS: old/new client registration and punch formats accept unchanged access token; identities have valid server signatures',flush=True)
    try: VerifyKey(bytes(SigningKey.generate().verify_key)).verify(signed)
    except BadSignatureError: pass
    else: raise AssertionError('Wrong trust root accepted')
    with staged_connection(32176) as controller:
        send_frame(controller,field(8,field(1,identity)+field(3,'wrong-test-token')+field(6,'1.2.3')))
        assert fields(fields(receive_frame(controller))[11])[3] == 3
    print('PASS: invalid access token and incorrect signing root rejected',flush=True)
    alias = os.environ.get('NNU_TEST_PUBLIC_ALIAS') == 'Y'
    public_text = base64.b64encode(PUBLIC).decode()
    if alias:
        identity,peer_signing,signed = signed_peer(32176,'1.5.1','ios',public_text)
        signed_identity = fields(VerifyKey(PUBLIC).verify(signed))
        assert signed_identity[1].decode() == identity
        with staged_connection(32186) as controller:
            send_frame(controller,field(8,field(1,identity)+field(3,public_text)+field(6,'1.5.1')))
            assert fields(fields(receive_frame(controller))[11])[3] == 3
        with staged_connection(32177) as invalid:
            send_frame(invalid,field(18,field(2,str(uuid.uuid4()))+field(6,'wrong-test-token')))
            assert invalid.recv(1)==b''
        left,right = relay_pair(public_text,public_text)
        try:
            left.sendall(b'phone-to-phone');assert receive_exact(right,14)==b'phone-to-phone'
        finally:left.close();right.close()
        print('PASS: stock-mobile public key accepted only when enabled; default-off and wrong relay keys rejected; public/public relay paired',flush=True)
    left,right = relay_pair()
    try:
        left.sendall(b'legacy-controller');assert receive_exact(right,17)==b'legacy-controller'
        right.sendall(b'legacy-peer');assert receive_exact(left,11)==b'legacy-peer'
    finally:left.close();right.close()
    print('PASS: original relay protocol and access token pair both directions',flush=True)
    left,right = relay_pair(public_text,TOKEN) if alias else relay_pair()
    try:
        ephemeral_peer = PrivateKey.generate()
        hello = peer_signing.sign(field(1,identity)+field(2,bytes(ephemeral_peer.public_key)))
        send_frame(right,bytes(hello))
        verified = VerifyKey(signed_identity[2]).verify(receive_frame(left))
        assert fields(verified)[1].decode() == identity
        controller_key = PrivateKey.generate(); session_key = secrets.token_bytes(32)
        sealed = Box(controller_key,ephemeral_peer.public_key).encrypt(session_key,b'\0'*24).ciphertext
        send_frame(left,field(1,bytes(controller_key.public_key))+field(2,sealed))
        key_exchange = fields(receive_frame(right))
        from nacl.public import PublicKey
        recovered = Box(ephemeral_peer,PublicKey(key_exchange[1])).decrypt(key_exchange[2],b'\0'*24)
        assert recovered == session_key
        for sender,receiver,data in [(left,right,b'new controller to old peer'),(right,left,b'old peer to new controller')]:
            nonce=(1).to_bytes(8,'little')+b'\0'*16
            ciphertext = SecretBox(session_key).encrypt(data,nonce).ciphertext
            assert data not in ciphertext
            send_frame(sender,ciphertext)
            assert SecretBox(recovered).decrypt(receive_frame(receiver),nonce)==data
    finally:left.close();right.close()
    print('PASS: server-anchored peer identity, legacy X25519 key exchange and encrypted relay payloads round-trip',flush=True)


if __name__ == '__main__': main()
