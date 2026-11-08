import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'nnu_announcement_model.dart';
import 'nnu_announcement_carousel.dart';
import 'nnu_announcement_style.dart';
export 'nnu_announcement_model.dart';
export 'nnu_announcement_carousel.dart';

class NnuAnnouncementFeed extends StatefulWidget {
  const NnuAnnouncementFeed({super.key});
  @override
  State<NnuAnnouncementFeed> createState() => _NnuAnnouncementFeedState();
}

class _NnuAnnouncementFeedState extends State<NnuAnnouncementFeed> {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  Timer? _timer;
  NnuAnnouncementBatch _batch = const NnuAnnouncementBatch([]);
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_loading) {
      return;
    }
    _loading = true;
    var batch = const NnuAnnouncementBatch([]);
    try {
      final request = await _client
          .getUrl(Uri.parse(
              'https://rd.nnu.cn/update-admin/notices.json?protocol=2'))
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw const HttpException('Announcement unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 131072) {
          throw const FormatException('Announcement list too large');
        }
      }
      batch = NnuAnnouncementBatch.parse(utf8.decode(bytes));
    } catch (_) {
      // The existing compact empty state also covers an unavailable public feed.
    } finally {
      _loading = false;
    }
    if (mounted) {
      setState(() => _batch = batch);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NnuAnnouncementCarousel(
      notices: _batch.notices, intervalSeconds: _batch.intervalSeconds);
}

class NnuAnnouncementBar extends StatelessWidget {
  final NnuAnnouncement? notice;
  const NnuAnnouncementBar({super.key, this.notice});
  @override
  Widget build(BuildContext context) {
    final message = notice;
    if (message == null) {
      return const SizedBox.shrink();
    }
    return NnuStyledAnnouncement(
        notice: message, onOpen: () => showNnuAnnouncement(context, message));
  }
}
