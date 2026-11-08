"""Create a root-signed multi-platform administration bundle from local build outputs."""
import base64
import hashlib
import json
from pathlib import Path
import zipfile
from cryptography.hazmat.primitives import serialization
from engine import signing_material

KINDS = {
 'android-arm64': ('Android','arm64-v8a','apk'), 'android-armv7': ('Android','armeabi-v7a','apk'),
 'android-x64': ('Android','x86_64','apk'), 'android-universal': ('Android','universal','apk'),
 'android-aab': ('Android','release','aab'), 'linux-deb': ('Linux','x86_64','deb'),
 'linux-rpm': ('Linux','x86_64','rpm'), 'linux-appimage': ('Linux','x86_64','AppImage'),
 'linux-tar': ('Linux','x86_64','tar.gz'),
}

def descriptor(file, path):
    with file.open('rb') as stream:
        digest = hashlib.file_digest(stream,'sha256').hexdigest()
    return dict(path=path,size=file.stat().st_size,sha256=digest)

def create(settings, job, packages, build, version, notes, windows_bundle=''):
    job, packages = Path(job), Path(packages)
    entries, artifacts, sources = {}, {}, {}
    for key,(folder,arch,extension) in KINDS.items():
        name = f'RustDesk-NNU-{build}-android-{arch}.{extension}' if folder=='Android' else f'RustDesk-NNU-{build}-linux-x86_64.{extension}'
        file=packages/folder/name
        if not file.is_file(): continue
        path=f'{folder}/{name}';entries[path]=file
        artifacts[key]=dict(descriptor(file,path),name=name,url=f'https://rd.nnu.cn/client-updates/releases/{build}/{path}')
    for kind,file in [('CrossPlatform',job/'RustDesk-NNU-CrossPlatform-Source.zip'),('Windows',packages/'Windows/RustDesk-NNU-1.5.0-Source.zip')]:
        if file.is_file():
            path=f'Sources/RustDesk-NNU-{kind}-Source.zip';entries[path]=file;sources[kind]=descriptor(file,path)
    manifest=dict(schema=1,type='nnu-platform-release',build=build,version=version,notes=notes,artifacts=artifacts,sources=sources)
    if windows_bundle:
        file=Path(windows_bundle);entries['windows-update.zip']=file
        manifest['windows']=descriptor(file,'windows-update.zip')
    if not artifacts:raise ValueError('No Android/Linux installers available')
    payload=json.dumps(manifest,ensure_ascii=False,separators=(',',':'),sort_keys=True).encode('utf-8')
    key=serialization.load_pem_private_key(signing_material(settings),password=None)
    raw=json.dumps(dict(payload=base64.b64encode(payload).decode(),signature=base64.b64encode(key.sign(payload)).decode()),separators=(',',':')).encode()
    output=job/f'NNU-{build}-多平台发布包.zip'
    with zipfile.ZipFile(output,'w',zipfile.ZIP_STORED) as archive:
        archive.writestr('platform-release.json',raw)
        for path,file in entries.items():archive.write(file,path)
    return str(output)
