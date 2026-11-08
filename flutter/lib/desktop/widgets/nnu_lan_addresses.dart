import 'dart:io';
import 'dart:isolate';

import 'nnu_lan_windows.dart';

class NnuLanAddress {
  final String address, name, description;
  final bool active, preferred;
  final int interfaceType;

  const NnuLanAddress(this.address, this.name,
      {this.description = '',
      this.active = true,
      this.preferred = true,
      this.interfaceType = 0});
}

List<String> nnuSelectLanAddresses(Iterable<NnuLanAddress> candidates) {
  final usable = candidates.where((entry) {
    final ip = InternetAddress.tryParse(entry.address);
    if (!entry.active ||
        !entry.preferred ||
        entry.interfaceType == 24 ||
        ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        ip.isLoopback ||
        ip.isLinkLocal ||
        ip.isMulticast) return false;
    final bytes = ip.rawAddress;
    if (bytes[0] == 0 ||
        bytes[0] >= 224 ||
        (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19))) return false;
    final identity = '${entry.name} ${entry.description}'.toLowerCase();
    return !RegExp(
      r'\b(clash|mihomo|docker\d*|wsl|vmnet[18]|host.only|loopback)\b|^meta(?:\s|$)|\bmeta tunnel\b|\bvethernet\s*\(default switch\)|^veth[0-9a-f]+(?:\s|$)|^br-[0-9a-f]+(?:\s|$)',
    ).hasMatch(identity);
  }).toList()
    ..sort((a, b) {
      int priority(NnuLanAddress entry) =>
          entry.interfaceType == 6 || entry.interfaceType == 71 ? 0 : 1;
      final order = priority(a).compareTo(priority(b));
      if (order != 0) return order;
      final left = InternetAddress(a.address).rawAddress;
      final right = InternetAddress(b.address).rawAddress;
      for (var index = 0; index < 4; index++) {
        final order = left[index].compareTo(right[index]);
        if (order != 0) return order;
      }
      return 0;
    });
  return usable.map((entry) => entry.address).toSet().toList();
}

Future<List<String>> nnuLoadLanAddresses() async {
  if (Platform.isWindows) {
    return Isolate.run(() => nnuSelectLanAddresses(nnuWindowsLanAddresses()));
  }
  final interfaces =
      await NetworkInterface.list(type: InternetAddressType.IPv4);
  return nnuSelectLanAddresses([
    for (final interface in interfaces)
      for (final address in interface.addresses)
        NnuLanAddress(address.address, interface.name),
  ]);
}
