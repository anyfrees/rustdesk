import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:win32/winsock2.dart' show ADDRESS_FAMILY;

import 'nnu_lan_addresses.dart';

List<NnuLanAddress> nnuWindowsLanAddresses() {
  const flags = GET_ADAPTERS_ADDRESSES_FLAGS.GAA_FLAG_SKIP_ANYCAST |
      GET_ADAPTERS_ADDRESSES_FLAGS.GAA_FLAG_SKIP_MULTICAST |
      GET_ADAPTERS_ADDRESSES_FLAGS.GAA_FLAG_SKIP_DNS_SERVER;
  final size = calloc<Uint32>()..value = 15 * 1024;
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (size.value > 1024 * 1024) {
        throw StateError('Adapter address buffer exceeds limit');
      }
      final buffer = calloc<Uint8>(size.value);
      try {
        final head = buffer.cast<IP_ADAPTER_ADDRESSES_LH>();
        final result =
            GetAdaptersAddresses(ADDRESS_FAMILY.AF_INET, flags, nullptr, head, size);
        if (result == WIN32_ERROR.ERROR_BUFFER_OVERFLOW) continue;
        if (result == WIN32_ERROR.ERROR_NO_DATA) return [];
        if (result != WIN32_ERROR.ERROR_SUCCESS) {
          throw StateError('GetAdaptersAddresses failed: $result');
        }
        final addresses = <NnuLanAddress>[];
        for (var adapter = head;
            adapter != nullptr;
            adapter = adapter.ref.Next) {
          final entry = adapter.ref;
          final name = entry.FriendlyName == nullptr
              ? ''
              : entry.FriendlyName.toDartString();
          final description = entry.Description == nullptr
              ? ''
              : entry.Description.toDartString();
          for (var address = entry.FirstUnicastAddress;
              address != nullptr;
              address = address.ref.Next) {
            final unicast = address.ref;
            final socket = unicast.Address;
            if (socket.lpSockaddr == nullptr ||
                socket.iSockaddrLength < 16 ||
                socket.lpSockaddr.ref.sa_family != ADDRESS_FAMILY.AF_INET) continue;
            final raw = socket.lpSockaddr.cast<Uint8>();
            addresses.add(NnuLanAddress(
              [for (var offset = 4; offset < 8; offset++) raw[offset]]
                  .join('.'),
              name,
              description: description,
              active: entry.OperStatus == IF_OPER_STATUS.IfOperStatusUp &&
                  (entry.Flags & 8) == 0,
              preferred: unicast.DadState == NL_DAD_STATE.IpDadStatePreferred &&
                  unicast.ValidLifetime != 0,
              interfaceType: entry.IfType,
            ));
          }
        }
        return addresses;
      } finally {
        calloc.free(buffer);
      }
    }
    throw StateError('Adapter addresses kept changing during enumeration');
  } finally {
    calloc.free(size);
  }
}
