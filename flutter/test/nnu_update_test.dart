import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(String, String)> signManifest({String? url}) async {
    final key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    final public = await key.extractPublicKey();
    final build = nnuClientBuild + 1;
    Map<String, dynamic> artifact(String kind, String extension) => {
          'name': 'update-$kind.$extension',
          'sha256': List.filled(64, 'a').join(),
          'size': 100,
          'url':
              url ?? '${nnuUpdateBase}releases/$build/update-$kind.$extension',
        };
    final payload = utf8.encode(jsonEncode({
      'schema': 1,
      'channel': 'stable',
      'build': build,
      'version': '1.5.0 UI5',
      'notes': '更新说明',
      'artifacts': {
        'portable': artifact('portable', 'exe'),
        'msi': artifact('msi', 'msi')
      },
    }));
    final signature = await Ed25519().sign(payload, keyPair: key);
    return (
      jsonEncode({
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes)
      }),
      base64Encode(public.bytes)
    );
  }

  test(
      'signed release is accepted; tampered manifest and wrong key are rejected',
      () async {
    final (envelope, publicKey) = await signManifest();
    final release = await NnuRelease.verify(envelope, publicKey: publicKey);
    expect(release.build, nnuClientBuild + 1);
    expect(release.notes, '更新说明');
    final modified = jsonDecode(envelope) as Map<String, dynamic>;
    final payload =
        jsonDecode(utf8.decode(base64Decode(modified['payload'] as String)))
            as Map<String, dynamic>;
    payload['notes'] = '被修改';
    modified['payload'] = base64Encode(utf8.encode(jsonEncode(payload)));
    await expectLater(
        NnuRelease.verify(jsonEncode(modified), publicKey: publicKey),
        throwsFormatException);
    await expectLater(NnuRelease.verify(envelope), throwsFormatException);
  });

  test(
      'even a signed release cannot redirect downloads outside the update service',
      () async {
    final (envelope, publicKey) =
        await signManifest(url: 'https://example.com/update.exe');
    await expectLater(NnuRelease.verify(envelope, publicKey: publicKey),
        throwsFormatException);
  });
}
