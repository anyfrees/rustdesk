import base64
import importlib.util
import json
import tempfile
import sys
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import engine
import signing_vault


class ReleaseAssistantTests(unittest.TestCase):
    def test_platform_bundle_roundtrips_through_the_backend_validator(self):
        import platform_bundle
        repo=Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);job=root/'output';job.mkdir();packages=job/'installers';packages.mkdir()
            build=2026110207
            for _,(folder,arch,ext) in platform_bundle.KINDS.items():
                name=f'RustDesk-NNU-{build}-android-{arch}.{ext}' if folder=='Android' else f'RustDesk-NNU-{build}-linux-x86_64.{ext}'
                file=packages/folder/name;file.parent.mkdir(exist_ok=True);file.write_bytes(('fixture '+name).encode())
            key=Ed25519PrivateKey.generate();keyfile=root/'private.pem'
            keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
            settings=engine.Settings(str(repo),str(root/'tools'),str(job),str(keyfile))
            bundle=Path(platform_bundle.create(settings,job,packages,build,'test','notes'))
            validator=engine.load_module(repo/'res/nnu/update-admin/release.py','platform_windows_validator')
            validator.PUBLIC_KEY=base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
            with patch.dict(sys.modules,{'release':validator}):
                catalog=engine.load_module(repo/'res/nnu/update-admin/platform_release.py','platform_catalog_validator')
            _,manifest=catalog.unpack(bundle,root/'unpacked')
            self.assertEqual(set(manifest['artifacts']),set(platform_bundle.KINDS))
            for artifact in manifest['artifacts'].values():
                self.assertEqual((root/'unpacked'/artifact['path']).read_bytes(),(packages/artifact['path']).read_bytes())

    def test_windows_line_endings_keep_built_version_and_metadata_consistent(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source';tools=root/'tools';output=root/'output'
            tools.mkdir();output.mkdir()
            version=source/engine.VERSION_FILE;version.parent.mkdir(parents=True)
            version.write_bytes(b'const nnuClientBuild = 10;\r\nconst nnuClientVersion = "old";\r\n')
            settings=engine.Settings(str(source),str(tools),str(output),'builtin')
            observed=[]
            def stop_after_preparation(*args,**kwargs):
                observed.append(engine.read_version(source))
                raise engine.BuildError('Stop before tool execution')
            with patch.object(engine,'environment'),patch.object(engine,'native_reusable',return_value=False),patch.object(engine.Builder,'run',side_effect=stop_after_preparation):
                with self.assertRaises(engine.BuildError):
                    engine.Builder(settings).build(11,'new version','notes','fixture password')
            self.assertEqual(observed,[(11,'new version')])

    def test_version_and_core_changes_select_native_rebuild(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            source=root/'source'; path=source/engine.VERSION_FILE;path.parent.mkdir(parents=True)
            path.write_text("const nnuClientBuild = 2026103105;\nconst nnuClientVersion = '1.5.0 NNU UI5';\n")
            core=source/'src';core.mkdir();(core/'main.rs').write_bytes(b'fn main() {}\r\n')
            old=engine.core_fingerprint(source)
            (core/'main.rs').write_bytes(b'fn main() {}\n')
            self.assertEqual(old,engine.core_fingerprint(source))
            (core/'version.rs').write_text('generated time')
            self.assertEqual(old,engine.core_fingerprint(source))
            path.write_text(path.read_text().replace('UI5','UI6'))
            self.assertEqual(old,engine.core_fingerprint(source))
            (core/'main.rs').write_text('fn main() { change(); }')
            self.assertNotEqual(old,engine.core_fingerprint(source))
            previous=engine.core_fingerprint(source)
            helper=source/'res/nnu/apply-portable-update.ps1';helper.parent.mkdir(parents=True)
            helper.write_text('update helper changed')
            self.assertNotEqual(previous,engine.core_fingerprint(source))
            build,version=engine.next_version(source)
            self.assertGreater(build,2026103105)
            self.assertEqual(version,'1.5.0 NNU UI7')

    def test_source_export_excludes_private_files_and_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for name in ['main.rs','.env','secret.pem','credentials.json','private/secret.txt',
                         'signing-key.dpapi','backup.nnu-key','android-release.jks','release.keystore','flutter/android/key.properties','target/core.dll','res/nnu/update-admin/wheels/binary.whl','flutter/build/app.so','notes.md']:
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
            actual={r.as_posix() for _,r in engine.source_files(root)}
            self.assertEqual(actual,{'main.rs','notes.md'})

    def test_real_signed_bundle_matches_all_generated_installer_bytes(self):
        repo=Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);packages=root/'packages';packages.mkdir();destination=root/'output';destination.mkdir()
            key=Ed25519PrivateKey.generate()
            keyfile=root/'private.pem';keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
            for name in engine.ARTIFACTS:(packages/name).write_bytes(b'installer fixture '+name.encode())
            (packages/'README.md').write_bytes(b'build and source instructions')
            public=base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
            settings=engine.Settings(str(repo),str(root/'tools'),str(destination),str(keyfile))
            original=engine.load_module
            def load(path,name):
                module=original(path,name)
                if name=='nnu_release_validator':module.PUBLIC_KEY=public
                return module
            with patch.object(engine,'PUBLIC_KEY',public),patch.object(engine,'load_module',side_effect=load):
                output=engine.release_bundle(settings,packages,destination,2026103106,'1.5.0 NNU UI6','新增发布助手')
                verifier=original(repo/'res/nnu/update-admin/release.py','fixture_verifier');verifier.PUBLIC_KEY=public
                raw=(destination/'signed/stable.json').read_bytes();manifest=verifier.verify_manifest(raw)
                self.assertEqual(manifest['build'],2026103106)
                verifier.unpack_bundle(output,destination/'unpacked')
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read('releases/2026103106/README.md'),b'build and source instructions')
                for kind,a in manifest['artifacts'].items():
                    original_name=engine.ARTIFACTS[['portable','install','msi','zip'].index(kind)]
                    self.assertEqual((destination/'unpacked'/a['name']).read_bytes(),(packages/original_name).read_bytes())

    def test_windows_key_vault_and_password_backup_restore(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            key=Ed25519PrivateKey.generate()
            raw=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
            with patch.object(signing_vault,'vault_path',return_value=root/'vault.dpapi'):
                signing_vault.store(raw)
                self.assertNotIn(raw,(root/'vault.dpapi').read_bytes())
                self.assertEqual(signing_vault.read(),raw)
                backup=root/'backup.nnu-key'
                signing_vault.export_backup(backup,'test-backup-password')
                self.assertNotIn(b'BEGIN PRIVATE KEY',backup.read_bytes())
                with self.assertRaises(ValueError):signing_vault.restore_backup(backup,'wrong')
                restored=signing_vault.restore_backup(backup,'test-backup-password')
                self.assertEqual(restored,raw)

    def test_combined_backup_restores_both_release_signing_identities(self):
        import android_signing
        from datetime import datetime, timedelta, timezone
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import pkcs12
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            raw = Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
            key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
            name = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, 'NNU test')])
            now = datetime.now(timezone.utc)
            cert = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now).not_valid_after(now + timedelta(days=1)).sign(key, hashes.SHA256())
            password = 'test-android-password'
            blob = pkcs12.serialize_key_and_certificates(b'nnu-android', key, cert, None, serialization.BestAvailableEncryption(password.encode()))
            android = json.dumps({'keystore': base64.b64encode(blob).decode(), 'password': password, 'alias': 'nnu-android'}).encode()
            with patch.object(signing_vault, 'vault_path', return_value=root / 'vault.dpapi'), patch.object(android_signing, 'embedded', return_value=None):
                signing_vault.store(raw); android_signing.store(android)
                expected = android_signing.read()
                backup = root / 'both.nnu-key'
                signing_vault.export_backup(backup, 'combined-backup-password')
                self.assertNotIn(password.encode(), backup.read_bytes())
                with self.assertRaises(ValueError): signing_vault.restore_backup(backup, 'wrong')
                android_signing.vault_path().unlink()
                signing_vault.restore_android_backup(backup, 'combined-backup-password')
                self.assertEqual(android_signing.read(), expected)
                self.assertEqual(signing_vault.restore_backup(backup, 'combined-backup-password'), raw)


if __name__=='__main__':unittest.main()
