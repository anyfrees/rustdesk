import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart'
    show Ed25519, Signature, SimplePublicKey, KeyPairType;
import 'package:path_provider/path_provider.dart';
import 'nnu_update_service.dart' show nnuUpdatePublicKey, nnuUpdateBase;

const nnuPlatformKinds = {
  'android-arm64': 'android-arm64-v8a.apk',
  'android-armv7': 'android-armeabi-v7a.apk',
  'android-x64': 'android-x86_64.apk',
  'android-universal': 'android-universal.apk',
  'android-aab': 'android-release.aab',
  'linux-deb': 'linux-x86_64.deb',
  'linux-rpm': 'linux-x86_64.rpm',
  'linux-appimage': 'linux-x86_64.AppImage',
  'linux-tar': 'linux-x86_64.tar.gz',
};

class NnuPlatformArtifact {
  final String name, digest;
  final int size;
  final Uri url;
  NnuPlatformArtifact(Map<String, dynamic> data, int build, String kind)
      : name = data['name'] as String,
        digest = data['sha256'] as String,
        size = data['size'] as int,
        url = Uri.parse(data['url'] as String) {
    final folder = kind.startsWith('android-') ? 'Android' : 'Linux';
    final expected = 'RustDesk-NNU-$build-${nnuPlatformKinds[kind]}';
    if (!nnuPlatformKinds.containsKey(kind) ||
        name != expected ||
        data['path'] != '$folder/$expected' ||
        url.toString() != '${nnuUpdateBase}releases/$build/$folder/$expected' ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('平台更新包信息不符合要求');
    }
  }
}

class NnuPlatformRelease {
  final int build;
  final String version, notes;
  final Map<String, NnuPlatformArtifact> artifacts;
  NnuPlatformRelease._(this.build, this.version, this.notes, this.artifacts);

  static Future<NnuPlatformRelease> verify(String envelope,
      {String publicKey = nnuUpdatePublicKey}) async {
    if (utf8.encode(envelope).length > 131072)
      throw const FormatException('更新清单过大');
    final data = jsonDecode(envelope) as Map<String, dynamic>;
    final payload = base64Decode(data['payload'] as String);
    final signature = Signature(base64Decode(data['signature'] as String),
        publicKey: SimplePublicKey(base64Decode(publicKey),
            type: KeyPairType.ed25519));
    if (!await Ed25519().verify(payload, signature: signature))
      throw const FormatException('更新清单签名校验失败');
    final manifest = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    final build = manifest['build'] as int;
    final version = manifest['version'] as String;
    final notes = manifest['notes'] as String;
    if (manifest['schema'] != 1 ||
        manifest['type'] != 'nnu-platform-release' ||
        build <= 0 ||
        build > 2100000000 ||
        version.isEmpty ||
        version.length > 80 ||
        notes.length > 8000) {
      throw const FormatException('平台更新清单格式不正确');
    }
    final artifacts = (manifest['artifacts'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key,
            NnuPlatformArtifact(value as Map<String, dynamic>, build, key)));
    if (artifacts.isEmpty) throw const FormatException('没有平台安装包');
    for (final group in ['android-', 'linux-']) {
      final selected = artifacts.keys.where((k) => k.startsWith(group)).length;
      if (selected != 0 &&
          selected !=
              nnuPlatformKinds.keys.where((k) => k.startsWith(group)).length) {
        throw const FormatException('平台安装包不完整');
      }
    }
    return NnuPlatformRelease._(build, version, notes, artifacts);
  }
}

class NnuPlatformUpdateService {
  final _client = HttpClient()..autoUncompress = false;
  void close() => _client.close(force: true);

  Future<NnuPlatformRelease> check(String platform) async {
    if (platform != 'android' && platform != 'linux')
      throw ArgumentError('不支持的平台');
    final request = await _client
        .getUrl(Uri.parse(
            'https://rd.nnu.cn/update-admin/platforms/$platform/stable.json'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode == 204 || response.statusCode == 404)
      throw const HttpException('此平台暂未提供更新');
    if (response.statusCode != 200)
      throw HttpException('更新服务返回 ${response.statusCode}');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 131072) throw const FormatException('更新清单过大');
    }
    return NnuPlatformRelease.verify(utf8.decode(bytes));
  }

  Future<File> download(
      NnuPlatformArtifact artifact, void Function(double) progress,
      {void Function()? onVerifying}) async {
    final cache = await getTemporaryDirectory();
    final parent = Directory('${cache.path}/nnu-updates');
    await parent.create(recursive: true);
    final directory = await parent.createTemp('release-');
    final partial = File('${directory.path}/${artifact.name}.part');
    final output = partial.openWrite();
    try {
      final request = await _client
          .getUrl(artifact.url)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 ||
          (response.contentLength >= 0 &&
              response.contentLength != artifact.size)) {
        await response.listen((_) {}).cancel();
        throw const HttpException('下载服务响应或文件大小不符');
      }
      var written = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        written += chunk.length;
        if (written > artifact.size) throw const FormatException('下载文件过大');
        output.add(chunk);
        progress(written / artifact.size);
      }
      await output.close();
      onVerifying?.call();
      if (written != artifact.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              artifact.digest) {
        throw const FormatException('更新包完整性校验失败');
      }
      return await partial.rename('${directory.path}/${artifact.name}');
    } catch (_) {
      await output.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }
}
