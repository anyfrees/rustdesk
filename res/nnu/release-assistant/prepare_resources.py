"""Collect public build helpers and an account-encrypted key for local packaging."""
import json
import os
import shutil
import zipfile
from pathlib import Path

from engine import load_settings, save_settings, sha, source_files, validate_key
import signing_vault
from upstream import export_recipe


def prepare():
    settings=load_settings()
    validate_key(settings)
    if settings.key!='builtin':
        signing_vault.store(Path(settings.key).read_bytes())
        settings.key='builtin';save_settings(settings)
    root=Path(os.environ['LOCALAPPDATA'])/'NNU/ReleaseAssistant/packaging-assets'
    root.mkdir(parents=True,exist_ok=True)
    resources=root/'resources';resources.mkdir(exist_ok=True)
    tools=Path(settings.tools)
    names=['nuget.exe','llvm/bin/libclang.dll','driver-sha256sums','usbmmidd_v2.zip',
           'rustdesk_printer_driver_v4-1.4.zip','printer_driver_adapter.zip',
           'RustDeskTempTopMostWindow/WindowInjection/x64/Release/WindowInjection.dll',
           'RustDeskTempTopMostWindow/LICENSE']
    manifest={}
    for name in names:
        source=tools/name
        if not source.is_file():raise ValueError('Missing local build helper: '+name)
        target=resources/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target);manifest[name]=sha(target)
    with zipfile.ZipFile(resources/'source-snapshot.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for path,relative in source_files(settings.source):z.write(path,relative.as_posix())
    manifest['source-snapshot.zip']=sha(resources/'source-snapshot.zip')
    (resources/'manifest.json').write_text(json.dumps(manifest,indent=2))
    export_recipe(settings.source,resources/'diy-recipe')
    shutil.copy2(signing_vault.vault_path(),root/'signing-key.dpapi')
    embedded='ENCRYPTED_KEY = bytes.fromhex('+repr(signing_vault.vault_path().read_bytes().hex())+')\n'
    import android_signing
    if android_signing.available():
        encrypted=signing_vault.protect(android_signing.read())
        embedded+='ENCRYPTED_ANDROID_KEY = bytes.fromhex('+repr(encrypted.hex())+')\n'
    (root/'embedded_signing_key.py').write_text(embedded,encoding='utf-8')
    print(root)
    return root


if __name__=='__main__':prepare()
