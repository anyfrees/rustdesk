import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'nnu_lan_addresses.dart';
import 'nnu_lan_card.dart';

class NnuLanInfo extends StatefulWidget {
  const NnuLanInfo({super.key});

  @override
  State<NnuLanInfo> createState() => _NnuLanInfoState();
}

class _NnuLanInfoState extends State<NnuLanInfo> {
  Timer? _timer;
  bool _enabled = false, _stopped = false, _loading = false;
  int _port = nnuDefaultDirectPort;
  List<String> _addresses = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final enabled = await bind.mainGetOption(key: 'direct-server') == 'Y';
      final stopped = await bind.mainGetOption(key: 'stop-service') == 'Y';
      final configured =
          int.tryParse(await bind.mainGetOption(key: 'direct-access-port')) ??
              0;
      final addresses = await nnuLoadLanAddresses();
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _stopped = stopped;
          _port = configured <= 0 ? nnuDefaultDirectPort : configured;
          _addresses = addresses;
        });
      }
    } catch (error) {
      debugPrint('Unable to refresh LAN addresses: ${error.runtimeType}');
      if (mounted) setState(() => _addresses = []);
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NnuLanCard(
      enabled: _enabled, stopped: _stopped, port: _port, addresses: _addresses);
}
