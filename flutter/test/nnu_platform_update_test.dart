import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_platform_update_service.dart';

void main() {
  test(
      'root signed platform release exposes complete Android and Linux packages',
      () async {
    final key = await Ed25519().newKeyPair();
    final public = base64Encode((await key.extractPublicKey()).bytes);
    final artifacts = <String, dynamic>{};
    const build = 2026110207;
    for (final entry in nnuPlatformKinds.entries) {
      final name = 'RustDesk-NNU-$build-${entry.value}';
      final path =
          '${entry.key.startsWith('android-') ? 'Android' : 'Linux'}/$name';
      artifacts[entry.key] = {
        'name': name,
        'path': path,
        'size': 42,
        'sha256': List.filled(64, 'a').join(),
        'url': 'https://rd.nnu.cn/client-updates/releases/$build/$path'
      };
    }
    Future<String> signed() async {
      final payload = utf8.encode(jsonEncode({
        'schema': 1,
        'type': 'nnu-platform-release',
        'build': build,
        'version': 'NNU test',
        'notes': '更新说明',
        'artifacts': artifacts
      }));
      return jsonEncode({
        'payload': base64Encode(payload),
        'signature':
            base64Encode((await Ed25519().sign(payload, keyPair: key)).bytes)
      });
    }

    final envelope = await signed();
    final release =
        await NnuPlatformRelease.verify(envelope, publicKey: public);
    expect(release.artifacts.length, 9);
    expect(release.artifacts['android-universal']!.name,
        endsWith('universal.apk'));
    final tampered = jsonDecode(envelope) as Map<String, dynamic>;
    tampered['signature'] = base64Encode(List.filled(64, 0));
    await expectLater(
        NnuPlatformRelease.verify(jsonEncode(tampered), publicKey: public),
        throwsFormatException);
    artifacts['linux-deb']['url'] = 'https://attacker.example/update.deb';
    await expectLater(
        NnuPlatformRelease.verify(await signed(), publicKey: public),
        throwsFormatException);
  });

  test('signed package paths, hashes and platform completeness are enforced',
      () async {
    final key = await Ed25519().newKeyPair();
    final public = base64Encode((await key.extractPublicKey()).bytes);
    const build = 10;
    final artifacts = <String, dynamic>{};
    for (final e
        in nnuPlatformKinds.entries.where((e) => e.key.startsWith('linux-'))) {
      final name = 'RustDesk-NNU-$build-${e.value}';
      artifacts[e.key] = {
        'name': name,
        'path': 'Linux/$name',
        'size': 1,
        'sha256': List.filled(64, 'b').join(),
        'url': 'https://rd.nnu.cn/client-updates/releases/$build/Linux/$name'
      };
    }
    Future<NnuPlatformRelease> verify() async {
      final bytes = utf8.encode(jsonEncode({
        'schema': 1,
        'type': 'nnu-platform-release',
        'build': build,
        'version': 'test',
        'notes': '',
        'artifacts': artifacts
      }));
      return NnuPlatformRelease.verify(
          jsonEncode({
            'payload': base64Encode(bytes),
            'signature':
                base64Encode((await Ed25519().sign(bytes, keyPair: key)).bytes)
          }),
          publicKey: public);
    }

    expect((await verify()).artifacts.length, 4);
    artifacts['linux-deb']['path'] = '../update.deb';
    await expectLater(verify(), throwsFormatException);
    artifacts['linux-deb']['path'] = 'Linux/RustDesk-NNU-10-linux-x86_64.deb';
    artifacts['linux-deb']['sha256'] = 'invalid';
    await expectLater(verify(), throwsFormatException);
    artifacts.remove('linux-deb');
    await expectLater(verify(), throwsFormatException);
  });
}
