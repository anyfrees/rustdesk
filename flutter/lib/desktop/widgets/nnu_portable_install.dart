import 'package:flutter/material.dart';

class NnuPortableInstallCard extends StatefulWidget {
  const NnuPortableInstallCard({
    super.key,
    required this.description,
    required this.installLabel,
    required this.install,
  });

  final String description;
  final String installLabel;
  final Future<String> Function() install;

  @override
  State<NnuPortableInstallCard> createState() => _NnuPortableInstallCardState();
}

class _NnuPortableInstallCardState extends State<NnuPortableInstallCard> {
  bool _busy = false;
  bool _installed = false;
  String? _message;

  Future<void> _install() async {
    if (_busy || _installed) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    String result;
    try {
      result = await widget.install();
    } catch (_) {
      result = 'failed';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _installed = result == 'installed';
      _message = result == 'busy'
          ? '远程连接中，请结束连接后再安装。'
          : result == 'disabled'
              ? '此客户端已禁用安装。'
              : _installed
                  ? null
                  : '安装未完成或已取消授权，请重试。';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_installed) return const SizedBox.shrink();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color.fromARGB(255, 226, 66, 188),
            Color.fromARGB(255, 244, 114, 124)
          ],
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.description,
              style: const TextStyle(
                  height: 1.5,
                  color: Colors.white,
                  fontWeight: FontWeight.normal,
                  fontSize: 13)),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: _busy ? null : _install,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(112, 36),
                padding: const EdgeInsets.all(8),
                foregroundColor: Colors.white,
                backgroundColor: Colors.transparent,
                disabledBackgroundColor: Colors.transparent,
                disabledForegroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.normal),
                enabledMouseCursor: SystemMouseCursors.click,
              ),
              child: Text(_busy ? '正在安装…' : widget.installLabel,
                  textAlign: TextAlign.center),
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(
                color: Colors.white,
                backgroundColor: Colors.white24,
                minHeight: 2),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class NnuInstallPlacement extends StatelessWidget {
  const NnuInstallPlacement(
      {super.key, required this.connection, required this.notice});

  final Widget connection;
  final Widget notice;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >=
          480 * MediaQuery.textScalerOf(context).scale(13) / 13) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: (constraints.maxWidth * 0.53).clamp(240, 360),
                child: connection),
            const SizedBox(width: 16),
            Flexible(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: notice)),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          connection,
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: notice),
        ],
      );
    });
  }
}

class NnuPortableConnectionBody extends StatelessWidget {
  const NnuPortableConnectionBody({
    super.key,
    required this.connection,
    required this.notice,
    required this.peers,
  });

  final Widget connection;
  final Widget notice;
  final Widget peers;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 22, right: 12),
          child: NnuInstallPlacement(connection: connection, notice: notice),
        ),
      ),
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 12, right: 12),
          child: Divider(),
        ),
      ),
      SliverLayoutBuilder(
        builder: (context, constraints) => SliverToBoxAdapter(
          child: SizedBox(
            height: (constraints.viewportMainAxisExtent -
                    constraints.precedingScrollExtent)
                .clamp(240.0, double.infinity),
            child: peers,
          ),
        ),
      ),
    ]);
  }
}
