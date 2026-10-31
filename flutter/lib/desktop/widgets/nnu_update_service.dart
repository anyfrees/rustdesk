import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart'
    show Ed25519, KeyPairType, Signature, SimplePublicKey;

const nnuClientBuild = 2026103104;
const nnuClientVersion = '1.5.0 · NNU UI4';
const nnuUpdateBase = 'https://rd.nnu.cn/client-updates/';
const nnuUpdatePublicKey = '1umorhoB3pej9Cu4Jlvi/n1JHPdLd6XxcdxDSFaWYGQ=';

class NnuUpdateArtifact {
  final String name;
  final String digest;
  final int size;
  final Uri url;

  NnuUpdateArtifact(Map<String, dynamic> data, int build)
      : name = data['name'] as String,
        digest = data['sha256'] as String,
        size = data['size'] as int,
        url = Uri.parse(data['url'] as String) {
    if (!RegExp(r'^[a-zA-Z0-9._-]+\.(exe|msi|zip)$').hasMatch(name) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        url.toString() != '${nnuUpdateBase}releases/$build/$name') {
      throw const FormatException('更新包信息不符合要求');
    }
  }
}

class NnuRelease {
  final int build;
  final String version;
  final String notes;
  final Map<String, NnuUpdateArtifact> artifacts;

  NnuRelease._(this.build, this.version, this.notes, this.artifacts);

  static Future<NnuRelease> verify(String envelope,
      {String publicKey = nnuUpdatePublicKey}) async {
    if (utf8.encode(envelope).length > 65536)
      throw const FormatException('更新清单过大');
    final data = jsonDecode(envelope) as Map<String, dynamic>;
    final payload = base64Decode(data['payload'] as String);
    final signature = Signature(base64Decode(data['signature'] as String),
        publicKey: SimplePublicKey(base64Decode(publicKey),
            type: KeyPairType.ed25519));
    if (!await Ed25519().verify(payload, signature: signature)) {
      throw const FormatException('更新清单签名校验失败');
    }
    final manifest = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    final build = manifest['build'] as int;
    final version = manifest['version'] as String;
    final notes = manifest['notes'] as String;
    if (manifest['schema'] != 1 ||
        manifest['channel'] != 'stable' ||
        build <= 0 ||
        version.isEmpty ||
        version.length > 80 ||
        notes.length > 8000) {
      throw const FormatException('更新清单格式不正确');
    }
    final artifacts = (manifest['artifacts'] as Map<String, dynamic>).map((key,
            value) =>
        MapEntry(key, NnuUpdateArtifact(value as Map<String, dynamic>, build)));
    if (!artifacts.containsKey('portable') || !artifacts.containsKey('msi')) {
      throw const FormatException('更新清单缺少 Windows 安装包');
    }
    return NnuRelease._(build, version, notes, artifacts);
  }
}

class NnuUpdateService {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  void close() => _client.close(force: true);

  Future<NnuRelease> check() async {
    final request = await _client
        .getUrl(Uri.parse('${nnuUpdateBase}stable.json'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw HttpException('更新服务返回 ${response.statusCode}');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) throw const FormatException('更新清单过大');
    }
    return NnuRelease.verify(utf8.decode(bytes));
  }

  Future<File> download(
      NnuUpdateArtifact artifact, void Function(double) onProgress) async {
    final directory = await Directory.systemTemp.createTemp('nnu-update-');
    final partial =
        File('${directory.path}${Platform.pathSeparator}${artifact.name}.part');
    final output = partial.openWrite();
    var written = 0;
    try {
      final request = await _client
          .getUrl(artifact.url)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw HttpException('下载服务返回 ${response.statusCode}');
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        written += chunk.length;
        if (written > artifact.size) throw const FormatException('更新包大小超出清单');
        output.add(chunk);
        onProgress(written / artifact.size);
      }
      await output.close();
      if (written != artifact.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              artifact.digest) {
        throw const FormatException('更新包完整性校验失败，请重试');
      }
      return partial
          .rename('${directory.path}${Platform.pathSeparator}${artifact.name}');
    } catch (_) {
      await output.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }
}
