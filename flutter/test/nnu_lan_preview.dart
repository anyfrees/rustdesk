import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_announcement.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_lan_card.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_support.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_action_button.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  runApp(const Preview());
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(1000, 720), minimumSize: Size(580, 480),
      title: 'NNU UI15 · 独立组件预览'), () async {
      await windowManager.show();
      await windowManager.setOpacity(1);
    });
}

class Preview extends StatefulWidget {
  const Preview({super.key});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  bool empty = false, dark = false, custom = false, large = false;
  String noticeTheme = 'frosted';
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light, colorSchemeSeed: const Color(0xff007bff), fontFamily: 'Microsoft YaHei'),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(large ? 1.6 : 1)), child: child!),
    home: Scaffold(body: Builder(builder: (context) => Row(children: [
      Container(width: 200, color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.4), child: Column(children: [
        const Padding(padding: EdgeInsets.fromLTRB(20, 24, 20, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('你的桌面', style: TextStyle(fontSize: 24)), SizedBox(height: 16), Text('你的桌面可以通过下面的 ID 和密码访问。'), SizedBox(height: 16), Text('ID'), Text('本地预览', style: TextStyle(fontSize: 22)), SizedBox(height: 18), Text('一次性密码'), Text('••••••', style: TextStyle(fontSize: 22)),
        ])),
        Expanded(child: SingleChildScrollView(child: NnuLanCard(enabled: true, port: custom ? 32100 : 21118, addresses: const ['192.168.1.20', '10.20.30.40']))),
        Padding(padding: const EdgeInsets.all(16), child: NnuActionButton(label: '检查更新', outlined: true, onPressed: () {})),
      ])),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const NnuSupportTitle(),
          const SizedBox(height: 24),
          const TextField(decoration: InputDecoration(border: OutlineInputBorder(), hintText: '输入远程 ID 或 IP')),
          const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: NnuActionButton(label: '连接', primary: true, onPressed: () {})),
          const SizedBox(height: 32),
          Wrap(spacing: 8, runSpacing: 8, children: [
            NnuActionButton(label: empty ? '显示公告' : '无公告', onPressed: () => setState(() => empty = !empty)),
            NnuActionButton(label: '深浅色', onPressed: () => setState(() => dark = !dark)),
            NnuActionButton(label: custom ? '默认端口' : '自定义端口', onPressed: () => setState(() => custom = !custom)),
            NnuActionButton(label: large ? '100% 文字' : '160% 文字', onPressed: () => setState(() => large = !large)),
          ]),
          Wrap(spacing: 4, runSpacing: 4, children: [for (final entry in nnuNoticeThemes.entries) NnuActionButton(label: entry.value, outlined: noticeTheme == entry.key, onPressed: () => setState(() => noticeTheme = entry.key))]),
          const SizedBox(height: 20), const Text('独立组件预览 · 模拟服务器未连接\n未启动远控服务，不读写在用客户端配置。', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ]))),
        NnuAnnouncementCarousel(notices: empty ? const [] : [NnuAnnouncement('nnu.cn 提醒您：请先核实身份', '接受远程协助前请确认对方身份，不要向陌生人提供连接码或访问权限。',id:'safety',theme:noticeTheme,icon:'shield',titleFont:'serif',titleWeight:'bold',titleSize:16,titleColor:'#26785B',iconColor:'#85510B'),NnuAnnouncement('局域网连接提示','同一局域网内可尝试使用 IP 直连，仍需原有密码或批准验证。',id:'network',theme:noticeTheme,icon:'network')]),
        NnuSupportFooter(showNotice: false, status: const Padding(padding: EdgeInsets.all(12), child: Text('●  暂未连接服务器')), onDismissNotice: () {}, onOpenSupport: () {}),
      ])),
    ]))),
  );
}
