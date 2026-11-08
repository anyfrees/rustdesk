"""Custom-ID acceptance against isolated localhost staging only."""
import base64,json,os,secrets,socket,struct,sys,time
from pathlib import Path
from nacl.signing import SigningKey,VerifyKey
from test_protocol import field,fields,send_frame,receive_frame,staged_connection,TOKEN,PUBLIC
STATE=Path('/qa-state/state.json')
def message(old,new,uuid,ts):
    return b'NNU-ID-CHANGE-V1\0'+b''.join(struct.pack('<I',len(x))+x for x in [old.encode(),new.encode(),uuid])+struct.pack('<Q',ts)
def claim(old,new,uuid,key,ts=None,signature=None):
    ts=int(time.time()) if ts is None else ts
    proof=struct.pack('<Q',ts)+(key.sign(message(old,new,uuid,ts)).signature if signature is None else signature)
    with staged_connection(32176) as connection:
        send_frame(connection,field(15,field(1,new)+field(2,uuid)+field(3,proof)+field(4,old)))
        return fields(fields(receive_frame(connection))[16]).get(1,0)
def register(identity,uuid,key):
    peer=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);peer.settimeout(5);peer.connect(('127.0.0.1',32176))
    peer.send(field(15,field(1,identity)+field(2,uuid)+field(3,bytes(key.verify_key))))
    result=fields(fields(peer.recv(65536))[16]).get(1,0)
    return peer,result

def probe_signed(identity,peer,key):
    with staged_connection(32176) as controller:
        send_frame(controller,field(8,field(1,identity)+field(3,base64.b64encode(PUBLIC).decode())+field(6,'1.5.0')))
        request=fields(peer.recv(65536))
        if 12 in request:
            address=fields(request[12])[1];reply=field(13,field(1,address)+field(2,address)+field(4,identity)+field(5,'1.5.0'))
        else:
            address=fields(request[9])[1];reply=field(10,field(1,address)+field(2,identity)+field(5,'1.5.0'))
        with staged_connection(32176) as response:
            send_frame(response,reply);signed=fields(fields(receive_frame(controller))[11])[2]
        data=fields(VerifyKey(PUBLIC).verify(signed));assert data[1].decode()==identity and data[2]==bytes(key.verify_key)

def main():
    if sys.argv[1]=='initial':
        with staged_connection(32186) as disabled:
            send_frame(disabled,field(15,b''))
            assert fields(fields(receive_frame(disabled))[16]).get(1,0)==6
        a=SigningKey.generate();b=SigningKey.generate();uid_a=secrets.token_bytes(32);uid_b=secrets.token_bytes(32)
        old=str(991000000+secrets.randbelow(1000000));new='nnu'+secrets.token_hex(5);other='nnu'+secrets.token_hex(5)
        pa,result=register(old,uid_a,a);assert result==0
        pb,result=register(other,uid_b,b);assert result==0
        try:
            assert claim(old,'12',uid_a,a)==5
            assert claim(old,new,uid_a,b)==2
            assert claim(old,new,uid_b,a)==2
            assert claim(old,new,uid_a,a,ts=int(time.time())-300)==2
            assert claim(old,other,uid_a,a)==3
            assert claim(old,other.upper(),uid_a,a)==3
            probe_signed(old,pa,a)
            print('PASS: malformed IDs, forged ownership, stale proofs and occupied names rejected without changing the device',flush=True)
            assert claim(old,new,uid_a,a)==0
            probe_signed(new,pa,a)
            assert claim(new,'nnu'+secrets.token_hex(5),uid_a,a)==4
            stale,result=register(old,uid_a,a);stale.close();assert result==2
            assert claim(old,new,uid_a,a)==2
            print('PASS: signed rename preserves peer identity; old registration and replay rejected; cooldown enforced',flush=True)
            STATE.write_text(json.dumps({'old':old,'new':new,'other':other,'uid_a':uid_a.hex(),'uid_b':uid_b.hex(),'a':bytes(a).hex(),'b':bytes(b).hex()}));STATE.chmod(0o600)
        finally:pa.close();pb.close()
    else:
        state=json.loads(STATE.read_text());a=SigningKey(bytes.fromhex(state['a']));b=SigningKey(bytes.fromhex(state['b']));ua=bytes.fromhex(state['uid_a']);ub=bytes.fromhex(state['uid_b'])
        p,result=register(state['new'],ua,a);p.close();assert result==0
        p,result=register(state['old'],ua,a);p.close();assert result==2
        next_id='nnu'+secrets.token_hex(5);assert claim(state['new'],next_id,ua,a)==0
        assert claim(state['other'],state['new'],ub,b)==3
        p,result=register(state['new'],ub,b);p.close();assert result==2
        print('PASS: restart preserves the new ID and ownership history; retired aliases cannot be claimed by another device',flush=True)
if __name__=='__main__':main()
