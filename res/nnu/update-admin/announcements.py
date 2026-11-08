"""Plain-text announcements; legacy feed remains compatible with older clients."""
import json
import re
import secrets
import time
from flask import Response, jsonify, request

THEMES = ('clean', 'safety', 'capsule', 'editorial', 'rotation', 'obsidian', 'titanium', 'glass', 'frosted')
ICONS = ('auto', 'megaphone', 'shield', 'bell', 'warning', 'info', 'wrench', 'sparkles', 'calendar', 'support', 'network', 'none')
MOTIONS = ('auto', 'fade', 'sway', 'breathe', 'none')
TITLE_FONTS = ('auto', 'sans', 'serif', 'mono')
TITLE_WEIGHTS = ('auto', 'normal', 'medium', 'bold')
MAX_NOTICES = 10


def normalize_items(items):
    if not isinstance(items, list) or len(items) > MAX_NOTICES:
        raise ValueError('最多保存 10 条公告')
    result, ids = [], set()
    for item in items:
        if not isinstance(item, dict):
            raise ValueError('公告格式不正确')
        title, body = item.get('title'), item.get('body')
        if (not isinstance(title, str) or not isinstance(body, str) or len(title) > 80 or len(body) > 2000
                or any(ord(ch) < 32 and ch not in '\n\t' for ch in title + body)):
            raise ValueError('标题最多 80 字、正文最多 2000 字，请使用纯文本')
        identity = item.get('id') or secrets.token_hex(8)
        if not isinstance(identity, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,40}', identity) or identity in ids:
            raise ValueError('公告标识无效或重复')
        ids.add(identity)
        theme, icon, motion = item.get('theme', 'clean'), item.get('icon', 'auto'), item.get('motion', 'auto')
        if theme not in THEMES or icon not in ICONS or motion not in MOTIONS or type(item.get('enabled', True)) is not bool:
            raise ValueError('请选择有效的主题、图标、动效和启用状态')
        appearance = dict(title_font=item.get('title_font', 'auto'), title_weight=item.get('title_weight', 'auto'),
                          title_size=item.get('title_size', 0), title_color=item.get('title_color', ''), icon_color=item.get('icon_color', ''))
        if (appearance['title_font'] not in TITLE_FONTS or appearance['title_weight'] not in TITLE_WEIGHTS
                or type(appearance['title_size']) is not int or appearance['title_size'] not in (0, 12, 13, 14, 16, 18)
                or any(not isinstance(appearance[key], str) or (appearance[key] and not re.fullmatch(r'#[0-9a-fA-F]{6}', appearance[key])) for key in ('title_color', 'icon_color'))):
            raise ValueError('请选择有效的标题字体、字号、字重和六位十六进制颜色')
        appearance.update({key: appearance[key].upper() for key in ('title_color', 'icon_color')})
        result.append(dict(id=identity, title=title.strip(), body=body.strip(), theme=theme,
                           icon=icon, motion=motion, enabled=item.get('enabled', True), **appearance))
    return result


def register_announcements(app, db, event, base):
    with db() as c:
        c.executescript('''CREATE TABLE IF NOT EXISTS announcement(
            id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL DEFAULT 0,
            title TEXT NOT NULL DEFAULT '',body TEXT NOT NULL DEFAULT '',
            published_title TEXT,published_body TEXT,published_at REAL);
            INSERT OR IGNORE INTO announcement(id) VALUES(1);''')
        columns = {r['name'] for r in c.execute('PRAGMA table_info(announcement)')}
        for name, definition in [('draft_items', 'TEXT'), ('published_items', 'TEXT'),
                                 ('interval_seconds', 'INTEGER NOT NULL DEFAULT 8'),
                                 ('published_interval', 'INTEGER NOT NULL DEFAULT 8')]:
            if name not in columns:
                c.execute(f'ALTER TABLE announcement ADD COLUMN {name} {definition}')

    def published(row):
        if row['published_at'] is None:
            return None
        return dict(title=row['published_title'], body=row['published_body'], published_at=row['published_at'])

    def items_for(row, live=False):
        saved = row['published_items' if live else 'draft_items']
        if saved is not None:
            return json.loads(saved)
        legacy = published(row) if live else dict(title=row['title'], body=row['body'])
        if legacy is None or not (legacy['title'] or legacy['body']):
            return []
        return [dict(id='legacy', title=legacy['title'], body=legacy['body'],
                     theme='clean', icon='auto', motion='auto', enabled=True)]

    @app.get(base + '/notices.json')
    def announcement_feed():
        with db() as c:
            row = c.execute('SELECT * FROM announcement WHERE id=1').fetchone()
        if request.args.get('protocol') == '2':
            notices = [dict(item, published_at=row['published_at']) for item in items_for(row, True)]
            return Response(json.dumps(dict(schema=2, announcements=notices,
                interval_seconds=row['published_interval']), ensure_ascii=False), mimetype='application/json')
        return jsonify(schema=1, announcement=published(row))

    @app.get(base + '/api/announcement')
    def announcement_info():
        with db() as c:
            row = c.execute('SELECT * FROM announcement WHERE id=1').fetchone()
        return jsonify(revision=row['revision'], title=row['title'], body=row['body'],
            published=published(row), items=items_for(row), published_items=items_for(row, True),
            interval_seconds=row['interval_seconds'], published_interval=row['published_interval'])

    @app.post(base + '/api/announcement/<action>')
    def announcement_change(action):
        if action not in ('save', 'publish', 'withdraw'):
            return jsonify(error='公告操作不存在'), 404
        data = request.get_json(silent=True)
        if not isinstance(data, dict) or type(data.get('revision')) is not int:
            return jsonify(error='公告请求格式不正确'), 400
        if action == 'save':
            try:
                items = normalize_items(data['items'] if 'items' in data else
                    [dict(id='legacy', title=data.get('title'), body=data.get('body'))])
                interval = data.get('interval_seconds', 8)
                if type(interval) is not int or not 5 <= interval <= 60:
                    raise ValueError('轮播间隔应为 5–60 秒')
            except (ValueError, TypeError) as error:
                return jsonify(error=str(error)), 400
        with db() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT * FROM announcement WHERE id=1').fetchone()
            if row['revision'] != data['revision']:
                return jsonify(error='公告已被其他页面修改，请刷新后重试'), 409
            if action == 'save':
                if 'items' not in data and len(items_for(row)) > 1:
                    return jsonify(error='公告管理页面已更新，请刷新后管理多条公告'), 409
                first = items[0] if items else dict(title='', body='')
                c.execute('UPDATE announcement SET title=?,body=?,draft_items=?,interval_seconds=?,revision=revision+1 WHERE id=1',
                    (first['title'], first['body'], json.dumps(items, ensure_ascii=False), interval))
            elif action == 'publish':
                notices = [item for item in items_for(row) if item.get('enabled', True)]
                if not notices or any(not item['title'] or not item['body'] for item in notices):
                    return jsonify(error='请至少启用一条标题和正文完整的公告'), 400
                first = notices[0]
                c.execute('''UPDATE announcement SET published_title=?,published_body=?,published_items=?,
                    published_interval=interval_seconds,published_at=?,revision=revision+1 WHERE id=1''',
                    (first['title'], first['body'], json.dumps(notices, ensure_ascii=False), time.time()))
            else:
                c.execute('''UPDATE announcement SET published_title=NULL,published_body=NULL,
                    published_items='[]',published_at=NULL,revision=revision+1 WHERE id=1''')
            event(c, {'save': '保存公告草稿', 'publish': '发布客户端公告', 'withdraw': '撤下客户端公告'}[action])
        return jsonify(ok=True)
