"""Private WSL key operation. Caller captures stdout; never log the JSON."""
import argparse,base64,json,os,pathlib,secrets,subprocess,sys

def main():
 p=argparse.ArgumentParser();p.add_argument('--import-key',action='store_true');p.add_argument('--root',default='/build/private/nnu-android');args=p.parse_args()
 root=pathlib.Path(args.root);root.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(root,0o700)
 meta=root/'key.json';keystore=root/'release.p12';os.umask(0o077)
 if args.import_key:
  raw=sys.stdin.buffer.read(262145)
  if len(raw)>262144:raise ValueError('Invalid key size')
  data=json.loads(raw);blob=base64.b64decode(data['keystore'],validate=True)
  if data['alias']!='nnu-android' or not 12<=len(data['password'])<=128 or len(blob)>131072:raise ValueError('Invalid Android key')
  pending=root/'release.next';pending.write_bytes(blob);os.replace(pending,keystore)
  meta.write_text(json.dumps(data));os.chmod(meta,0o600);print('Android signing identity restored to private build storage')
  return
 if not meta.exists():
  if keystore.exists():raise ValueError('Existing keystore has no password metadata; refusing to replace it')
  password=secrets.token_urlsafe(36)
  env=dict(os.environ,LANG='C.UTF-8',LC_ALL='C.UTF-8',NNU_ANDROID_STORE_PASSWORD=password)
  command=['/usr/lib/jvm/java-17-openjdk-amd64/bin/keytool','-genkeypair','-keystore',str(keystore),'-storetype','PKCS12','-storepass:env','NNU_ANDROID_STORE_PASSWORD','-keypass:env','NNU_ANDROID_STORE_PASSWORD','-alias','nnu-android','-keyalg','RSA','-keysize','4096','-sigalg','SHA256withRSA','-validity','10000','-dname','CN=NNU Android Release,O=NNU,C=CN']
  result=subprocess.run(command,env=env,cwd=root,capture_output=True)
  if result.returncode:raise RuntimeError('Android signing identity generation failed')
  data={'keystore':base64.b64encode(keystore.read_bytes()).decode(),'password':password,'alias':'nnu-android'}
  meta.write_text(json.dumps(data));os.chmod(meta,0o600);os.chmod(keystore,0o600)
 sys.stdout.write(meta.read_text())

if __name__=='__main__':main()
