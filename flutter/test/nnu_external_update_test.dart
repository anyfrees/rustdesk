import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_external_update.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('certified external release accepts mirrors and rejects a forged certificate', () async {
    final root = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    final online = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i + 1));
    final rootPublic = base64Encode((await root.extractPublicKey()).bytes);
    final certificatePayload = utf8.encode(jsonEncode({'schema': 1, 'purpose': 'nnu-external-updates',
      'origin': 'https://rd.nnu.cn', 'public_key': base64Encode((await online.extractPublicKey()).bytes)}));
    final certificate = {'payload': base64Encode(certificatePayload),
      'signature': base64Encode((await Ed25519().sign(certificatePayload, keyPair: root)).bytes)};
    final build = nnuClientBuild + 1;
    final payload = utf8.encode(jsonEncode({'schema': 1, 'channel': 'stable', 'delivery': 'external',
      'build': build, 'version': 'NNU external', 'notes': '自建网盘', 'artifacts': {
        for (final kind in ['portable', 'msi']) kind: {'name': 'update-$kind.${kind == 'msi' ? 'msi' : 'exe'}',
          'size': 100, 'sha256': List.filled(64, 'a').join(),
          'url': '${nnuUpdateBase}releases/$build/update-$kind.${kind == 'msi' ? 'msi' : 'exe'}',
          'mirrors': ['https://drive.example/download?id=$kind']}}}));
    final envelope = {'payload': base64Encode(payload), 'signature': base64Encode((await Ed25519().sign(payload, keyPair: online)).bytes), 'certificate': certificate};
    final release = await NnuRelease.verify(jsonEncode(envelope), publicKey: rootPublic);
    expect(release.artifacts['portable']!.mirrors.single.host, 'drive.example');
    certificate['signature'] = base64Encode(List.filled(64, 0));
    await expectLater(NnuRelease.verify(jsonEncode(envelope), publicKey: rootPublic), throwsFormatException);
  });

  test('external download policy blocks private destinations and HTTPS downgrades', () {
    for (final value in ['http://drive.example/file', 'https://127.0.0.1/file', 'https://192.168.1.1/file',
      'https://[::1]/file', 'https://198.18.0.1/file', 'https://[::ffff:127.0.0.1]/file', 'https://user:password@drive.example/file',
      'https://drive.example:8443/file', 'https://drive.example/file#fragment']) {
      expect(() => nnuExternalUri(value), throwsFormatException, reason: value);
    }
    expect(nnuPublicAddress(InternetAddress('8.8.8.8')), isTrue);
    expect(nnuPublicAddress(InternetAddress('2606:4700:4700::1111')), isTrue);
    expect(nnuPublicAddress(InternetAddress('100.64.0.1')), isFalse);
    expect(nnuExternalUri('https://drive.example/download?token=abc').query, 'token=abc');
  });
}
