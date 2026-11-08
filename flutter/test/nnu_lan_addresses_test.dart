import 'package:flutter_hbb/desktop/widgets/nnu_lan_addresses.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'keeps connected LAN and overlay addresses, removes proxy and internal networks',
      () {
    expect(
        nnuSelectLanAddresses(const [
          NnuLanAddress('10.10.10.100', 'home',
              description: 'home Tunnel', interfaceType: 131),
          NnuLanAddress('172.17.12.7', '以太网', interfaceType: 6),
          NnuLanAddress('172.17.12.7', 'duplicate', interfaceType: 6),
          NnuLanAddress('172.23.176.1', 'vEthernet (WSL (Hyper-V firewall))'),
          NnuLanAddress('172.24.160.1', 'vEthernet (Default Switch)'),
          NnuLanAddress('198.18.0.1', 'Meta'),
          NnuLanAddress('192.168.10.1', 'Clash'),
          NnuLanAddress('192.168.20.1', 'VMware Network Adapter VMnet8'),
          NnuLanAddress('192.168.1.9', 'WLAN', active: false),
          NnuLanAddress('192.168.1.10', 'Ethernet', preferred: false),
          NnuLanAddress('169.254.1.9', 'Ethernet'),
          NnuLanAddress('127.0.0.1', 'Loopback'),
          NnuLanAddress('0.0.0.0', 'Ethernet'),
          NnuLanAddress('239.1.1.1', 'Ethernet'),
          NnuLanAddress('::1', 'Ethernet'),
        ]),
        ['172.17.12.7', '10.10.10.100']);
    expect(
        nnuSelectLanAddresses(const [
          NnuLanAddress('10.1.1.2', 'vEthernet (External)',
              description: 'Hyper-V Virtual Ethernet Adapter',
              interfaceType: 6),
          NnuLanAddress('10.8.0.2', 'WireGuard Tunnel', interfaceType: 131),
          NnuLanAddress('100.64.0.2', 'Tailscale', interfaceType: 131),
          NnuLanAddress('172.17.0.1', 'docker0'),
          NnuLanAddress('172.18.0.1', 'br-a64f'),
        ]),
        ['10.1.1.2', '10.8.0.2', '100.64.0.2']);
  });
}
