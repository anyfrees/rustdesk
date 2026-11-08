"""Build signed Android packages inside the private local WSL workspace."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import zipfile

from linux_packages import run, native_version

ABIS = ('armeabi-v7a', 'arm64-v8a', 'x86_64')


def package(source, root, output, build, version, env):
    source, root, output = Path(source), Path(root), Path(output)
    if not 1 <= int(build) <= 2100000000:
        raise ValueError('Android versionCode must be between 1 and 2100000000')
    for abi in ABIS:
        for name in ('librustdesk.so', 'libc++_shared.so'):
            if not (source / 'flutter/android/app/src/main/jniLibs' / abi / name).is_file():
                raise RuntimeError('Missing Android native library: ' + abi + '/' + name)
    output.mkdir(parents=True, exist_ok=True)
    gradle = source / 'flutter/android/app/build.gradle'
    text = gradle.read_text().replace('applicationId "com.carriez.flutter_hbb"', 'applicationId "cn.nnu.rustdesk"')
    if 'applicationId "cn.nnu.rustdesk"' not in text:
        raise RuntimeError('Cannot apply NNU Android application identifier')
    text = re.sub(r'\n// NNU: preserve the same build number across all APK variants\.[\s\S]*$', '', text)
    if '// NNU: restrict native libraries to the requested standalone APK architecture.' not in text:
        text += '''
// NNU: restrict native libraries to the requested standalone APK architecture.
def nnuAbiNames = ['android-arm':'armeabi-v7a', 'android-arm64':'arm64-v8a', 'android-x64':'x86_64']
def nnuTargets = (project.findProperty('target-platform') ?: 'android-arm,android-arm64,android-x64').split(',')
android.defaultConfig.ndk.abiFilters.clear()
android.defaultConfig.ndk.abiFilters.addAll(nnuTargets.collect { nnuAbiNames[it] })
'''
    gradle.write_text(text)
    pubspec = source / 'flutter/pubspec.yaml'
    assets = pubspec.read_text().replace('family: GestureIcons', 'family: gestureicons')
    if not re.search(r'^  cupertino_icons:', assets, re.M):
        assets = assets.replace('dependencies:\n', 'dependencies:\n  cupertino_icons: 1.0.8\n', 1)
    pubspec.write_text(assets)
    manifest = source / 'flutter/android/app/src/main/AndroidManifest.xml'
    manifest.write_text(re.sub(r'android:label="(?:RustDesk|RustDesk NNU|RustDesk VIP支持专业版)"', 'android:label="RustDesk VIP支持专业版"', manifest.read_text()))
    wrapper = source / 'flutter/android/gradle/wrapper/gradle-wrapper.properties'
    wrapper.write_text(wrapper.read_text().replace('-all.zip', '-bin.zip'))
    gradle_properties = source / 'flutter/android/gradle.properties'
    properties_text = gradle_properties.read_text()
    properties_text = re.sub(r'^org.gradle.jvmargs=.*$', 'org.gradle.jvmargs=-Xmx6G -XX:MaxMetaspaceSize=1G -XX:ActiveProcessorCount=6', properties_text, flags=re.M)
    properties_text = re.sub(r'^org.gradle.workers.max=.*\n?', '', properties_text, flags=re.M)
    properties_text = re.sub(r'^kotlin.daemon.jvmargs=.*\n?', '', properties_text, flags=re.M)
    gradle_properties.write_text(properties_text.rstrip() + '\norg.gradle.workers.max=4\nkotlin.daemon.jvmargs=-Xmx2G\n')
    secret = json.loads(Path('/build/private/nnu-android/key.json').read_text())
    keystore = Path('/build/private/nnu-android/release.p12')
    properties = source / 'flutter/android/key.properties'
    signing_properties = ('storeFile=' + str(keystore) + '\nstorePassword=' + secret['password'] +
                          '\nkeyPassword=' + secret['password'] + '\nkeyAlias=' + secret['alias'] + '\n')
    if properties.exists() and properties.read_text() != signing_properties:
        raise RuntimeError('Refusing to overwrite an existing Android signing configuration')
    with os.fdopen(os.open(properties, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as signing:
        signing.write(signing_properties)
    android = root / 'android-sdk'
    env = dict(env, JAVA_HOME='/usr/lib/jvm/java-17-openjdk-amd64', ANDROID_HOME=str(android),
               ANDROID_SDK_ROOT=str(android), ANDROID_NDK_HOME=str(android / 'ndk/28.2.13676358'))
    env['PATH'] = env['JAVA_HOME'] + '/bin:' + env['PATH']
    base = ['flutter', 'build']
    flags = ['--release', '--build-name', native_version(source), '--build-number', str(build)]
    all_platforms = ['--target-platform', 'android-arm,android-arm64,android-x64']
    prefix = f'RustDesk-NNU-{build}-android-'
    try:
        for abi, target in zip(ABIS, ('android-arm', 'android-arm64', 'android-x64')):
            run(base + ['apk'] + flags + ['--target-platform', target], cwd=source / 'flutter', env=env)
            shutil.copy2(source / 'flutter/build/app/outputs/flutter-apk/app-release.apk', output / (prefix + abi + '.apk'))
        run(base + ['apk'] + flags + all_platforms, cwd=source / 'flutter', env=env)
        shutil.copy2(source / 'flutter/build/app/outputs/flutter-apk/app-release.apk', output / (prefix + 'universal.apk'))
        run(base + ['appbundle'] + flags + all_platforms, cwd=source / 'flutter', env=env)
        shutil.copy2(source / 'flutter/build/app/outputs/bundle/release/app-release.aab', output / (prefix + 'release.aab'))
    finally:
        properties.unlink()
    verify(output, root, build, env)
    print('Signed Android APKs and AAB built and verified', flush=True)


def verify(output, root, build, env):
    output, root = Path(output), Path(root)
    android = root / 'android-sdk'
    secret = json.loads(Path('/build/private/nnu-android/key.json').read_text())
    keystore = Path('/build/private/nnu-android/release.p12')
    prefix = f'RustDesk-NNU-{build}-android-'
    env = dict(env, JAVA_HOME='/usr/lib/jvm/java-17-openjdk-amd64')
    apksigner = android / 'build-tools/36.0.0/apksigner'
    zipalign = android / 'build-tools/36.0.0/zipalign'
    cert = subprocess.check_output([env['JAVA_HOME'] + '/bin/keytool', '-exportcert', '-keystore', str(keystore),
                                    '-storepass:env', 'NNU_ANDROID_VERIFY_PASSWORD', '-alias', secret['alias']],
                                   env=dict(env, NNU_ANDROID_VERIFY_PASSWORD=secret['password']), stderr=subprocess.PIPE)
    fingerprint = hashlib.sha256(cert).hexdigest()
    checks = []
    expected_apks = {prefix + abi + '.apk' for abi in ABIS} | {prefix + 'universal.apk'}
    if {p.name for p in output.glob(prefix + '*.apk')} != expected_apks:
        raise RuntimeError('Android installer collection is incomplete')
    for path in sorted(output.glob(prefix + '*.apk')):
        result = subprocess.check_output([str(apksigner), 'verify', '--verbose', '--print-certs', str(path)], env=env, text=True)
        if fingerprint not in result.lower():
            raise RuntimeError('Unexpected APK signing identity: ' + path.name)
        run([zipalign, '-c', '-P', '16', '-v', '4', path], stdout=subprocess.DEVNULL)
        with zipfile.ZipFile(path) as archive:
            abis = sorted({Path(name).parts[1] for name in archive.namelist() if name.startswith('lib/') and name.endswith('/librustdesk.so')})
            expected = sorted(ABIS) if path.name.endswith('universal.apk') else [next(abi for abi in ABIS if path.name.endswith(abi + '.apk'))]
            if abis != expected: raise RuntimeError('APK architecture set is incomplete: ' + path.name)
            for name in archive.namelist():
                if not name.startswith('lib/') or not name.endswith('.so'): continue
                data = archive.read(name); abi = Path(name).parts[1]
                if data[:4] != b'\x7fELF' or data[5] != 1:
                    raise RuntimeError('Invalid Android ELF: ' + name)
                machine = struct.unpack_from('<H', data, 18)[0]
                if machine != {'armeabi-v7a': 40, 'arm64-v8a': 183, 'x86_64': 62}[abi]:
                    raise RuntimeError('Android ELF architecture does not match its ABI: ' + name)
                if data[4] == 2:
                    offset = struct.unpack_from('<Q', data, 32)[0]
                    size, count = struct.unpack_from('<HH', data, 54)
                    for index in range(count):
                        position = offset + index * size
                        if struct.unpack_from('<I', data, position)[0] == 1 and struct.unpack_from('<Q', data, position + 48)[0] < 16384:
                            raise RuntimeError('64-bit native library lacks 16KB page support: ' + name)
        badging = subprocess.check_output([str(android / 'build-tools/36.0.0/aapt2'), 'dump', 'badging', str(path)], text=True, env=env)
        if "name='cn.nnu.rustdesk'" not in badging or f"versionCode='{build}'" not in badging:
            raise RuntimeError('Android package identity or version is incorrect: ' + path.name)
        if "application-label:'RustDesk VIP支持专业版'" not in badging:
            raise RuntimeError('Android application display name is incorrect: ' + path.name)
        checks.append({'file': path.name, 'abis': abis, 'certificate_sha256': fingerprint, 'signature_verified': True,
                       'zip_alignment_16k': True, 'elf_architectures_verified': True, 'elf_64bit_16k_pages_verified': True,
                       'package': 'cn.nnu.rustdesk', 'version_code': build, 'display_name': 'RustDesk VIP支持专业版'})
    aab = output / (prefix + 'release.aab')
    with zipfile.ZipFile(aab) as archive:
        aab_abis = sorted({Path(n).parts[2] for n in archive.namelist() if n.startswith('base/lib/') and n.endswith('/librustdesk.so')})
    if aab_abis != sorted(ABIS): raise RuntimeError('AAB architecture set is incomplete')
    verify = subprocess.check_output([env['JAVA_HOME'] + '/bin/jarsigner', '-verify', str(aab)], env=dict(env, LANG='C.UTF-8'), text=True)
    if 'jar verified.' not in verify: raise RuntimeError('AAB signature could not be verified')
    aab_certificate = subprocess.check_output([env['JAVA_HOME'] + '/bin/keytool', '-printcert', '-jarfile', str(aab)], env=env, text=True)
    if fingerprint not in aab_certificate.replace(':', '').lower():
        raise RuntimeError('AAB signing identity does not match the APKs')
    checks.append({'file': aab.name, 'abis': aab_abis, 'jar_signature_verified': True, 'certificate_sha256': fingerprint})
    (output / 'ANDROID-VERIFICATION.json').write_text(json.dumps(checks, indent=2))
    print('Android signatures, package versions, ABIs and 16KB compatibility verified', flush=True)
