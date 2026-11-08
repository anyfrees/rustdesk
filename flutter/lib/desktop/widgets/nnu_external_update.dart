import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Uri nnuExternalUri(String value) {
  final uri = Uri.parse(value);
  if (value.length > 4096 ||
      value.contains(RegExp(r'[\s\\]')) ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.host.toLowerCase() == 'localhost' ||
      uri.host.endsWith('.')) {
    throw const FormatException('外部下载地址必须是有效的 HTTPS 公网链接');
  }
  final literal = InternetAddress.tryParse(uri.host);
  if (literal != null && !nnuPublicAddress(literal)) {
    throw const FormatException('外部下载地址不能指向本机或内网');
  }
  return uri;
}

bool nnuPublicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) return false;
  final b = address.rawAddress;
  if (b.length == 4) {
    return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
        b[0] == 100 && b[1] >= 64 && b[1] <= 127 ||
        b[0] == 169 && b[1] == 254 ||
        b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
        b[0] == 192 && (b[1] == 168 || b[1] == 0 || b[1] == 2) ||
        b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100) ||
        b[0] == 203 && b[1] == 0 && b[2] == 113);
  }
  return b.length == 16 && b[0] >= 0x20 && b[0] <= 0x3f &&
      !(b[0] == 0x20 && b[1] == 0x02) &&
      !(b[0] == 0x20 && b[1] == 0x01 &&
          (b[2] == 0 || b[2] == 0x0d && b[3] == 0xb8));
}

Future<SimplePublicKey> nnuCertifiedUpdateKey(
    Map<String, dynamic> certificate, String root) async {
  if (utf8.encode(jsonEncode(certificate)).length > 4096) {
    throw const FormatException('发布签名证书过大');
  }
  final payload = base64Decode(certificate['payload'] as String);
  final valid = await Ed25519().verify(payload,
      signature: Signature(base64Decode(certificate['signature'] as String),
          publicKey: SimplePublicKey(base64Decode(root), type: KeyPairType.ed25519)));
  if (!valid) throw const FormatException('发布签名证书校验失败');
  final claims = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
  if (claims['schema'] != 1 || claims['purpose'] != 'nnu-external-updates' ||
      claims['origin'] != 'https://rd.nnu.cn') {
    throw const FormatException('发布签名证书用途不正确');
  }
  final key = base64Decode(claims['public_key'] as String);
  if (key.length != 32) throw const FormatException('发布公钥长度不正确');
  return SimplePublicKey(key, type: KeyPairType.ed25519);
}

class NnuExternalDownload {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  NnuExternalDownload() {
    _client.findProxy = (_) => 'DIRECT';
    _client.connectionFactory = (uri, proxyHost, proxyPort) async {
      nnuExternalUri(uri.toString());
      final resolved = await InternetAddress.lookup(uri.host)
          .timeout(const Duration(seconds: 15));
      // TUN clients use 198.18/15 as DNS routing addresses. TLS still verifies
      // the signed hostname; literal reserved-IP URLs remain forbidden.
      bool tunnelAddress(InternetAddress address) {
        final b = address.rawAddress;
        return b.length == 4 && b[0] == 198 && (b[1] == 18 || b[1] == 19);
      }
      final addresses = resolved.where((a) => nnuPublicAddress(a) || tunnelAddress(a)).toList();
      if (addresses.isEmpty) {
        throw const FormatException('下载域名指向本机、内网或保留地址');
      }
      final address = addresses.firstWhere(
          (a) => a.type == InternetAddressType.IPv4, orElse: () => addresses.first);
      return SecureSocket.startConnect(address, uri.port, supportedProtocols: ['http/1.1']);
    };
  }

  void close() => _client.close(force: true);

  Future<HttpClientResponse> open(Uri uri) async {
    for (var hop = 0; hop <= 5; hop++) {
      nnuExternalUri(uri.toString());
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || hop == 5) {
          throw const FormatException('下载跳转地址无效或次数过多');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.listen((_) {}).cancel();
        throw HttpException('网盘下载返回 ${response.statusCode}');
      }
      final contentType = response.headers.contentType?.mimeType;
      if (['text/html', 'application/xhtml+xml', 'application/json'].contains(contentType) ||
          (response.headers.value(HttpHeaders.contentEncodingHeader) ?? 'identity') != 'identity') {
        await response.listen((_) {}).cancel();
        throw const FormatException('下载链接返回网页，请联系管理员更新网盘直链');
      }
      return response;
    }
    throw const FormatException('下载跳转次数过多');
  }
}
