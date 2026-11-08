import 'dart:convert';

const nnuNoticeThemes = <String, String>{
  'clean': '清爽细栏',
  'safety': '安全提示',
  'capsule': '悬浮胶囊',
  'editorial': '双层卡片',
  'rotation': '多主题轮播',
  'obsidian': '曜石黑',
  'titanium': '钛金黑',
  'glass': '液态玻璃',
  'frosted': '磨砂材质',
};
const nnuNoticeIcons = <String, String>{
  'auto': '跟随主题',
  'megaphone': '扩音器',
  'shield': '安全盾牌',
  'bell': '铃铛',
  'warning': '警示',
  'info': '信息',
  'wrench': '维护工具',
  'sparkles': '星光',
  'calendar': '日程',
  'support': '技术支持',
  'network': '网络',
  'none': '无图标',
};
const nnuNoticeMotions = ['auto', 'fade', 'sway', 'breathe', 'none'];
const nnuNoticeTitleFonts = ['auto', 'sans', 'serif', 'mono'];
const nnuNoticeTitleWeights = ['auto', 'normal', 'medium', 'bold'];
const nnuNoticeTitleSizes = [0, 12, 13, 14, 16, 18];

class NnuAnnouncement {
  final String title, body, id, theme, icon, motion;
  final String titleFont, titleWeight, titleColor, iconColor;
  final int titleSize;
  const NnuAnnouncement(this.title, this.body,
      {this.id = 'legacy',
      this.theme = 'clean',
      this.icon = 'auto',
      this.motion = 'auto',
      this.titleFont = 'auto',
      this.titleWeight = 'auto',
      this.titleSize = 0,
      this.titleColor = '',
      this.iconColor = ''});

  bool get hasCustomTitle =>
      titleFont != 'auto' ||
      titleWeight != 'auto' ||
      titleSize != 0 ||
      titleColor.isNotEmpty;

  String get summary =>
      '${title.trim()} ${body.trim().replaceAll(RegExp(r'\s+'), ' ')}';
  String get effectiveMotion => motion != 'auto'
      ? motion
      : (theme == 'safety' || theme == 'glass' ? 'breathe' : 'fade');

  static NnuAnnouncement fromJson(dynamic notice) {
    if (notice is! Map<String, dynamic> ||
        notice['title'] is! String ||
        notice['body'] is! String ||
        notice['published_at'] is! num) {
      throw const FormatException('Invalid announcement');
    }
    final title = notice['title'] as String, body = notice['body'] as String;
    final id = notice['id'] ?? 'legacy';
    if (title.trim().isEmpty ||
        body.trim().isEmpty ||
        title.runes.length > 80 ||
        body.runes.length > 2000 ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(id)) {
      throw const FormatException('Invalid announcement');
    }
    return NnuAnnouncement(title, body,
        id: id,
        theme: nnuNoticeThemes.containsKey(notice['theme'])
            ? notice['theme']
            : 'clean',
        icon: nnuNoticeIcons.containsKey(notice['icon'])
            ? notice['icon']
            : 'auto',
        motion: nnuNoticeMotions.contains(notice['motion'])
            ? notice['motion']
            : 'auto',
        titleFont: nnuNoticeTitleFonts.contains(notice['title_font'])
            ? notice['title_font']
            : 'auto',
        titleWeight: nnuNoticeTitleWeights.contains(notice['title_weight'])
            ? notice['title_weight']
            : 'auto',
        titleSize: notice['title_size'] is int &&
                nnuNoticeTitleSizes.contains(notice['title_size'])
            ? notice['title_size']
            : 0,
        titleColor: _color(notice['title_color']),
        iconColor: _color(notice['icon_color']));
  }

  static String _color(dynamic value) =>
      value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)
          ? value.toUpperCase()
          : '';

  static NnuAnnouncement? parse(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    if (data['schema'] != 1) {
      throw const FormatException('Unsupported announcement');
    }
    return data['announcement'] == null ? null : fromJson(data['announcement']);
  }
}

class NnuAnnouncementBatch {
  final List<NnuAnnouncement> notices;
  final int intervalSeconds;
  const NnuAnnouncementBatch(this.notices, {this.intervalSeconds = 8});

  static NnuAnnouncementBatch parse(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    if (data['schema'] == 1) {
      final notice = NnuAnnouncement.parse(source);
      return NnuAnnouncementBatch(notice == null ? [] : [notice]);
    }
    final items = data['announcements'], interval = data['interval_seconds'];
    if (data['schema'] != 2 ||
        items is! List ||
        items.length > 10 ||
        interval is! int ||
        interval < 5 ||
        interval > 60) {
      throw const FormatException('Invalid announcement list');
    }
    final notices = items.map(NnuAnnouncement.fromJson).toList();
    if (notices.map((item) => item.id).toSet().length != notices.length) {
      throw const FormatException('Duplicate announcement');
    }
    return NnuAnnouncementBatch(notices, intervalSeconds: interval);
  }
}
