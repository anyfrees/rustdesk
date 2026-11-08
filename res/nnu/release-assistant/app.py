import argparse
import ctypes
import json
import os
import queue
import subprocess
import sys
import threading
import traceback
import webbrowser
from pathlib import Path
import signing_vault
from tkinter import filedialog, messagebox

import customtkinter as ctk

from engine import (Builder, BuildError, Settings, environment, load_settings,
                    native_reusable, next_version, package_existing, read_version,
                    save_settings, validate_key, config_path)
from multiplatform import MultiPlatformBuilder, check_local

BLUE = '#315DE6'
INK = '#20252E'
MUTED = '#747D8B'
BG = '#F5F6F8'
LINE = '#E4E8EF'
FONT = 'Microsoft YaHei UI'
ADMIN = 'https://rd.nnu.cn/update-admin/'
APP_ICON = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'assets/assistant.ico'


class Assistant(ctk.CTk):
    def __init__(self):
        ctk.set_appearance_mode('light')
        ctk.set_default_color_theme('blue')
        super().__init__()
        self.iconbitmap(str(APP_ICON))
        self.iconbitmap(default=str(APP_ICON))
        self.title('RUSTDESK版本发布助手')
        self.geometry('880x820')
        self.minsize(800, 780)
        self.configure(fg_color=BG)
        self.settings = load_settings()
        self.password = ''
        self.force_full = False
        self.busy = False
        self.result = None
        self.engine = None
        self.events = queue.Queue()
        self.steps = []
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)
        header = ctk.CTkFrame(self, height=68, fg_color='white', corner_radius=0,
                              border_width=0)
        header.grid(row=0, column=0, sticky='ew')
        header.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(header, text='RUSTDESK', text_color=INK,
                     font=(FONT, 23, 'bold')).grid(row=0, column=0, padx=(30, 18), pady=17)
        ctk.CTkLabel(header, text='版本发布助手', text_color=MUTED,
                     font=(FONT, 14)).grid(row=0, column=1, sticky='w')
        self.settings_button = self.button(header, '设置', self.open_settings, secondary=True, width=72)
        self.settings_button.grid(row=0, column=2, padx=(0, 24))
        content = ctk.CTkFrame(self, fg_color='transparent')
        content.grid(row=1, column=0, sticky='nsew', padx=30, pady=(26, 18))
        content.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(content, text='构建新版本', font=(FONT, 27, 'bold'),
                     text_color=INK).grid(row=0, column=0, sticky='w')
        self.current_label = ctk.CTkLabel(content, text='', font=(FONT, 12), text_color=MUTED)
        self.current_label.grid(row=1, column=0, sticky='w', pady=(4, 18))
        self.upstream_button=self.button(content,'拉取官方新版',self.update_upstream,secondary=True,width=140)
        self.upstream_button.grid(row=0,column=0,sticky='e')
        form = ctk.CTkFrame(content, fg_color='white', corner_radius=14, border_width=1, border_color=LINE)
        form.grid(row=2, column=0, sticky='ew')
        form.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(form, text='版本名称', font=(FONT, 13), text_color=INK).grid(row=0, column=0, sticky='w', padx=22, pady=(18, 6))
        self.version = ctk.CTkEntry(form, height=42, font=(FONT, 14), border_color=LINE,
                                    fg_color='white', text_color=INK, corner_radius=8)
        self.version.grid(row=1, column=0, sticky='ew', padx=22)
        ctk.CTkLabel(form, text='更新说明', font=(FONT, 13), text_color=INK).grid(row=2, column=0, sticky='w', padx=22, pady=(16, 6))
        self.notes = ctk.CTkTextbox(form, height=110, font=(FONT, 13), border_width=1,
                                  border_color=LINE, fg_color='white', text_color=INK,
                                  corner_radius=8, wrap='word')
        self.notes.grid(row=3, column=0, sticky='ew', padx=22)
        platforms = ctk.CTkFrame(form, fg_color='transparent')
        platforms.grid(row=4, column=0, sticky='ew', padx=22, pady=(16, 0))
        self.platforms = {}
        for column, (key, title) in enumerate([('windows', 'Windows x64'), ('android', 'Android · 三种架构'), ('linux', 'Linux x64')]):
            platforms.grid_columnconfigure(column, weight=1)
            checkbox = ctk.CTkCheckBox(platforms, text=title, font=(FONT, 12), text_color=INK,
                                      checkbox_width=19, checkbox_height=19, fg_color=BLUE,
                                      command=self.refresh_platform_hint)
            checkbox.grid(row=0, column=column, sticky='w')
            if key == 'windows': checkbox.select()
            self.platforms[key] = checkbox
        self.build_label = ctk.CTkLabel(form, text='', font=(FONT, 11), text_color=MUTED)
        self.build_label.grid(row=5, column=0, sticky='w', padx=22, pady=(8, 14))
        self.status = ctk.CTkLabel(content, text='准备就绪', font=(FONT, 14, 'bold'), text_color=INK)
        self.status.grid(row=3, column=0, sticky='w', pady=(21, 10))
        stepbar = ctk.CTkFrame(content, fg_color='transparent')
        stepbar.grid(row=4, column=0, sticky='ew')
        for i, title in enumerate(['准备', '检查', '编译', '安装包', '升级包']):
            stepbar.grid_columnconfigure(i, weight=1)
            label = ctk.CTkLabel(stepbar, text=f'{i+1}  {title}', height=31, font=(FONT, 12),
                                 fg_color='#EAEDF2', text_color=MUTED, corner_radius=6)
            label.grid(row=0, column=i, sticky='ew', padx=(0 if i==0 else 5, 0))
            self.steps.append(label)
        self.progress = ctk.CTkProgressBar(content, height=5, progress_color=BLUE, fg_color=LINE)
        self.progress.grid(row=5, column=0, sticky='ew', pady=(12, 10))
        self.progress.set(0)
        self.detail = ctk.CTkLabel(content, text='自动生成 EXE、MSI、ZIP 和后台升级发布包', font=(FONT, 12),
                                  text_color=MUTED, anchor='w', justify='left', wraplength=780)
        self.detail.grid(row=6, column=0, sticky='ew')
        actions = ctk.CTkFrame(content, fg_color='transparent')
        actions.grid(row=7, column=0, sticky='ew', pady=(20, 0))
        actions.grid_columnconfigure(1, weight=1)
        self.log_button = self.button(actions, '查看日志', self.show_log, secondary=True, width=100)
        self.log_button.grid(row=0, column=0, sticky='w')
        self.start_button = self.button(actions, '开始构建', self.start, width=150)
        self.start_button.grid(row=0, column=2)
        self.results = ctk.CTkFrame(content, fg_color='transparent')
        self.results.grid(row=8, column=0, sticky='ew', pady=(14, 0))
        self.folder_button = self.button(self.results, '打开安装包', self.open_output, secondary=True, width=130)
        self.folder_button.pack(side='left')
        self.bundle_button = self.button(self.results, '定位升级包', self.select_bundle, secondary=True, width=130)
        self.bundle_button.pack(side='left', padx=10)
        self.admin_button = self.button(self.results, '打开发布后台', lambda: webbrowser.open(ADMIN), secondary=True, width=140)
        self.admin_button.pack(side='right')
        for button in (self.folder_button, self.bundle_button):
            button.configure(state='disabled')
        previous=config_path().with_name('last-result.json')
        if previous.exists():
            try:
                result=json.loads(previous.read_text(encoding='utf-8'))
                if Path(result['bundle']).is_file():
                    self.result=result
                    self.folder_button.configure(state='normal');self.bundle_button.configure(state='normal')
                    if result.get('platform_bundle'):
                        self.bundle_button.configure(text='定位多平台发布包')
                    elif result.get('distribution_only') and not result.get('windows_bundle'):
                        self.bundle_button.configure(text='定位安装包合集')
            except (ValueError,KeyError,OSError):
                pass
        self.log_window = None
        self.logs = []
        self.refresh_version()
        self.protocol('WM_DELETE_WINDOW', self.close)
        self.after(100, self.poll)

    def refresh_platform_hint(self):
        if not hasattr(self, 'detail') or self.busy: return
        selected = [k for k, checkbox in self.platforms.items() if checkbox.get()]
        descriptions = {'windows': 'Windows：EXE、MSI、ZIP 和签名升级包',
                        'android': 'Android：三种架构 APK、通用 APK、AAB',
                        'linux': 'Linux：DEB、RPM、AppImage、tar.gz'}
        self.detail.configure(text='；'.join(descriptions[k] for k in selected) or '请选择至少一个构建平台。')

    def button(self, parent, label, action, secondary=False, width=110):
        return ctk.CTkButton(parent, text=label, command=action, width=width, height=40,
                             font=(FONT, 13), anchor='center', corner_radius=8,
                             fg_color='white' if secondary else BLUE,
                             hover_color='#EDF1FA' if secondary else '#244DD0',
                             border_width=1 if secondary else 0, border_color=LINE,
                             text_color=INK if secondary else 'white')

    def refresh_version(self):
        try:
            current, version = read_version(self.settings.source)
            self.build_number, suggested = next_version(self.settings.source)
            self.current_label.configure(text=f'当前 {version}  ·  Build {current}')
            self.build_label.configure(text=f'内部版本号 {self.build_number} · 自动递增')
            self.version.delete(0, 'end')
            self.version.insert(0, suggested)
        except Exception as exc:
            self.build_number = None
            self.current_label.configure(text='请在设置中选择客户端源码目录')
            self.build_label.configure(text='')

    def report(self, kind, payload):
        self.events.put((kind, payload))

    def work(self, action):
        try:
            action()
        except Exception as exc:
            if self.engine and self.engine.logfile and not self.engine.logfile.closed:
                self.engine.log(traceback.format_exc())
            self.report('error', str(exc))

    def start(self):
        if self.busy:
            return
        if not self.notes.get('1.0', 'end').strip():
            self.status.configure(text='请填写本次更新说明', text_color='#BE3B3B')
            self.notes.focus_set()
            return
        try:
            targets = tuple(k for k, checkbox in self.platforms.items() if checkbox.get())
            if not targets: raise BuildError('请选择至少一个构建平台。')
            if 'windows' in targets: environment(self.settings)
            if any(t != 'windows' for t in targets): check_local()
            if self.build_number is None:
                raise BuildError('请先设置源码目录。')
            if 'windows' in targets and (self.force_full or not native_reusable(self.settings)) and not (self.password or os.environ.get('NNU_PORTABLE_PASSWORD')):
                raise BuildError('原生核心已变更，需要完整构建。请在设置中填写便携版预设密码。')
        except Exception as exc:
            self.status.configure(text=str(exc), text_color='#BE3B3B')
            return
        version, notes, build = self.version.get().strip(), self.notes.get('1.0', 'end').strip(), self.build_number
        password, full, settings = self.password, self.force_full, self.settings
        self.set_busy(True)
        self.result = None
        self.logs = []
        self.engine = MultiPlatformBuilder(settings, self.report)
        self.folder_button.configure(state='disabled')
        self.bundle_button.configure(state='disabled')
        threading.Thread(target=self.work, args=(lambda: self.engine.build(build, version, notes, password, full, targets),), daemon=True).start()

    def set_busy(self, busy):
        self.busy = busy
        self.start_button.configure(state='disabled' if busy else 'normal', text='正在构建…' if busy else '开始构建')
        self.settings_button.configure(state='disabled' if busy else 'normal')
        self.upstream_button.configure(state='disabled' if busy else 'normal')
        self.version.configure(state='disabled' if busy else 'normal')
        self.notes.configure(state='disabled' if busy else 'normal')
        for checkbox in self.platforms.values(): checkbox.configure(state='disabled' if busy else 'normal')
        if busy:
            self.progress.configure(mode='indeterminate')
            self.progress.start()
        else:
            self.progress.stop()
            self.progress.configure(mode='determinate')

    def poll(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == 'log':
                    self.logs.append(payload)
                    self.logs = self.logs[-1500:]
                    if self.log_window and self.log_window.winfo_exists():
                        self.log_text.configure(state='normal')
                        self.log_text.insert('end', payload + '\n')
                        self.log_text.see('end')
                        self.log_text.configure(state='disabled')
                elif kind == 'phase':
                    number, label = payload
                    self.status.configure(text=label, text_color=INK)
                    self.detail.configure(text='正在本机构建所选平台；首次使用会自动下载并校验工具链。')
                    for i, step in enumerate(self.steps):
                        step.configure(fg_color=BLUE if i + 1 == number else '#E7EDF9' if i + 1 < number else '#EAEDF2',
                                       text_color='white' if i + 1 == number else INK if i + 1 < number else MUTED)
                elif kind == 'done':
                    self.result = payload
                    self.set_busy(False)
                    self.progress.set(1)
                    self.status.configure(text='构建完成', text_color='#237451')
                    cross = payload.get('distribution_only', False)
                    self.detail.configure(text='多平台安装包和签名发布包已生成；在后台导入多平台发布包，预览后发布。' if cross else '安装包和签名升级包已就绪。打开后台，导入升级包并确认发布。')
                    self.bundle_button.configure(text='定位多平台发布包' if payload.get('platform_bundle') else '定位安装包合集' if cross and not payload.get('windows_bundle') else '定位升级包')
                    for step in self.steps:
                        step.configure(fg_color='#E7EDF9', text_color=INK)
                    self.folder_button.configure(state='normal')
                    self.bundle_button.configure(state='normal')
                    self.refresh_version()
                elif kind == 'error':
                    self.set_busy(False)
                    self.progress.set(0)
                    self.status.configure(text='构建未完成', text_color='#BE3B3B')
                    self.detail.configure(text=payload)
                    self.logs.append(payload)
                    self.refresh_version()
                elif kind == 'environment_done':
                    self.set_busy(False);self.progress.set(1)
                    self.status.configure(text='构建环境已就绪',text_color='#237451')
                    self.detail.configure(text='可以填写更新说明并开始构建。')
                    self.refresh_version()
                elif kind == 'upstream_current':
                    self.set_busy(False);self.progress.set(1)
                    self.status.configure(text='当前已是官方最新稳定版',text_color='#237451')
                    self.detail.configure(text=f"官方 {payload['version']} · 保留当前 NNU 样式、参数与源码。")
                elif kind == 'upstream_ready':
                    self.settings.source=payload['source'];save_settings(self.settings)
                    self.set_busy(False);self.refresh_version();self.progress.set(1)
                    self.status.configure(text='官方新版已套用 NNU 定制',text_color='#237451')
                    self.detail.configure(text=f"官方 {payload['version']} 的独立源码已准备，界面和配置检查通过。填写说明后开始构建。")
        except queue.Empty:
            pass
        self.after(100, self.poll)

    def open_output(self):
        if self.result:
            folder = Path(self.result['folder']) / '安装包'
            os.startfile(folder if folder.exists() else Path(self.result['folder']))

    def select_bundle(self):
        if self.result:
            subprocess.Popen(['explorer.exe', '/select,', self.result.get('platform_bundle') or self.result.get('windows_bundle') or self.result['bundle']])

    def show_log(self):
        if self.log_window and self.log_window.winfo_exists():
            self.log_window.lift(); return
        self.log_window = ctk.CTkToplevel(self)
        self.log_window.iconbitmap(str(APP_ICON))
        self.log_window.title('构建日志')
        self.log_window.geometry('900x520')
        self.log_text = ctk.CTkTextbox(self.log_window, font=('Consolas', 12), wrap='word')
        self.log_text.pack(fill='both', expand=True, padx=16, pady=16)
        self.log_text.insert('end', '\n'.join(self.logs) or '尚未开始构建。')
        self.log_text.configure(state='disabled')

    def open_settings(self):
        dialog = ctk.CTkToplevel(self)
        dialog.iconbitmap(str(APP_ICON))
        dialog.title('构建设置')
        dialog.geometry('750x690')
        dialog.resizable(False, False)
        dialog.configure(fg_color='white')
        dialog.transient(self)
        dialog.grab_set()
        dialog.grid_columnconfigure(1, weight=1)
        entries = {}
        for row, (name, title) in enumerate([('source', '客户端源码'), ('tools', '构建工具'), ('output', '产物目录'), ('key', '签名密钥'), ('visual_studio', 'Visual Studio')]):
            ctk.CTkLabel(dialog, text=title, text_color=INK, font=(FONT, 12)).grid(row=row, column=0, padx=(24, 16), pady=(22 if row==0 else 12, 0), sticky='w')
            entry = ctk.CTkEntry(dialog, height=36, font=(FONT, 12), border_color=LINE, fg_color='white')
            entry.grid(row=row, column=1, pady=(22 if row==0 else 12, 0), sticky='ew')
            entry.insert(0, '已内置 · 当前 Windows 账户加密' if name=='key' and self.settings.key=='builtin' else getattr(self.settings, name))
            if name=='key':
                entry.configure(state='readonly')
            entries[name] = entry
            def choose(entry=entry, name=name):
                path = filedialog.askopenfilename(parent=dialog, title='选择签名密钥', filetypes=[('PEM 密钥', '*.pem')]) if name=='key' else filedialog.askdirectory(parent=dialog)
                if path:
                    if name=='key':
                        try:
                            candidate=Settings(**{**vars(self.settings),'key':path})
                            validate_key(candidate)
                            signing_vault.store(Path(path).read_bytes())
                            self.settings.key='builtin'
                            save_settings(self.settings)
                            entry.configure(state='normal');entry.delete(0,'end')
                            entry.insert(0,'已内置 · 当前 Windows 账户加密');entry.configure(state='readonly')
                        except Exception as exc:
                            messagebox.showerror('密钥未导入',str(exc),parent=dialog)
                        return
                    entry.delete(0, 'end'); entry.insert(0, path)
            self.button(dialog, '选择', choose, secondary=True, width=60).grid(row=row, column=2, padx=(10, 24), pady=(22 if row==0 else 12, 0))
        ctk.CTkLabel(dialog, text='完整构建', text_color=INK, font=(FONT, 12)).grid(row=5, column=0, padx=24, pady=(22, 0), sticky='w')
        full = ctk.CTkCheckBox(dialog, text='强制重新编译原生核心', font=(FONT, 12), text_color=INK, fg_color=BLUE)
        full.grid(row=5, column=1, pady=(22, 0), sticky='w')
        if self.force_full:
            full.select()
        ctk.CTkLabel(dialog, text='便携版密码', text_color=INK, font=(FONT, 12)).grid(row=6, column=0, padx=24, pady=(20, 0), sticky='w')
        password = ctk.CTkEntry(dialog, show='●', height=36, font=(FONT, 12), border_color=LINE,
                                 placeholder_text='仅完整构建需要，不保存到磁盘', fg_color='white')
        password.grid(row=6, column=1, columnspan=2, pady=(20, 0), padx=(0, 24), sticky='ew')
        password.insert(0, self.password)
        ctk.CTkLabel(dialog, text='密钥已集成；换电脑前请导出一份带密码的备份。', font=(FONT, 11), text_color=MUTED).grid(row=7, column=0, columnspan=3, padx=24, pady=(18, 0), sticky='w')
        result = ctk.CTkLabel(dialog, text='', font=(FONT, 12), text_color=MUTED, wraplength=700, justify='left')
        result.grid(row=8, column=0, columnspan=3, padx=24, pady=(16, 0), sticky='w')
        def values():
            return Settings(**{name: self.settings.key if name=='key' else entry.get().strip() for name, entry in entries.items()})
        def check():
            try:
                environment(values())
                result.configure(text='构建环境已就绪', text_color='#237451')
            except Exception as exc:
                result.configure(text=str(exc), text_color='#BE3B3B')
        def save():
            self.settings = values(); self.password = password.get(); self.force_full = bool(full.get())
            save_settings(self.settings); self.refresh_version(); dialog.destroy()
        row = ctk.CTkFrame(dialog, fg_color='transparent')
        row.grid(row=9, column=0, columnspan=3, sticky='ew', padx=24, pady=22)
        self.button(row, '检查环境', check, secondary=True, width=100).pack(side='left')
        self.button(row, '检查并补全', lambda: self.provision(values(),dialog), secondary=True, width=110).pack(side='left', padx=10)
        self.button(row, '已有安装包', lambda: self.repack(dialog), secondary=True, width=100).pack(side='left')
        self.button(row, '保存设置', save, width=120).pack(side='right')
        keys=ctk.CTkFrame(dialog,fg_color='transparent')
        keys.grid(row=10,column=0,columnspan=3,sticky='ew',padx=24,pady=(0,16))
        self.button(keys,'导出密钥备份',lambda:self.key_backup(dialog),secondary=True,width=130).pack(side='left')
        self.button(keys,'恢复密钥',lambda:self.key_backup(dialog,True),secondary=True,width=110).pack(side='left',padx=10)
        dialog.after(100, dialog.lift)

    def key_backup(self,parent,restore=False):
        dialog=ctk.CTkToplevel(self)
        dialog.iconbitmap(str(APP_ICON))
        dialog.title('恢复签名密钥' if restore else '导出签名密钥备份')
        dialog.geometry('460x310');dialog.resizable(False,False)
        dialog.transient(parent);dialog.grab_set()
        ctk.CTkLabel(dialog,text='输入备份密码' if restore else '设置备份密码（至少 12 个字符）',font=(FONT,14),text_color=INK).pack(anchor='w',padx=24,pady=(24,10))
        password=ctk.CTkEntry(dialog,show='●',height=38,font=(FONT,13));password.pack(fill='x',padx=24)
        confirm=None
        if not restore:
            confirm=ctk.CTkEntry(dialog,show='●',height=38,font=(FONT,13),placeholder_text='再次输入备份密码');confirm.pack(fill='x',padx=24,pady=10)
        status=ctk.CTkLabel(dialog,text='',font=(FONT,12),wraplength=412,text_color=MUTED);status.pack(fill='x',padx=24,pady=10)
        def perform():
            try:
                secret=password.get()
                if restore:
                    path=filedialog.askopenfilename(parent=dialog,filetypes=[('NNU 密钥备份','*.nnu-key')])
                    if not path:return
                    raw=signing_vault.restore_backup(path,secret)
                    from cryptography.hazmat.primitives import serialization
                    from engine import PUBLIC_KEY
                    import base64
                    key=serialization.load_pem_private_key(raw,password=None)
                    if key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)!=base64.b64decode(PUBLIC_KEY):
                        raise BuildError('备份密钥与此客户端不匹配。')
                    signing_vault.restore_android_backup(path,secret)
                    signing_vault.store(raw);self.settings.key='builtin';save_settings(self.settings)
                    messagebox.showinfo('密钥已恢复','签名密钥已恢复到当前 Windows 账户。',parent=dialog)
                else:
                    if secret!=confirm.get():raise BuildError('两次输入的备份密码不一致。')
                    if not 12<=len(secret)<=128:raise BuildError('备份密码需为 12–128 个字符。')
                    path=filedialog.asksaveasfilename(parent=dialog,defaultextension='.nnu-key',initialfile='NNU签名密钥备份.nnu-key',filetypes=[('NNU 密钥备份','*.nnu-key')])
                    if not path:return
                    signing_vault.export_backup(path,secret)
                    messagebox.showinfo('备份已保存','请将备份保存在另一处，并记住备份密码。',parent=dialog)
                password.delete(0,'end');dialog.destroy()
            except Exception as exc:status.configure(text=str(exc),text_color='#BE3B3B')
        self.button(dialog,'恢复' if restore else '导出备份',perform,width=130).pack(anchor='e',padx=24,pady=8)
        dialog.protocol('WM_DELETE_WINDOW',dialog.destroy)
        password.focus_set()

    def provision(self,settings,dialog):
        from provision import complete_environment
        self.settings=settings;save_settings(settings)
        dialog.destroy();self.set_busy(True);self.logs=[];self.show_log()
        def run():
            complete_environment(settings,self.report)
            self.report('environment_done',None)
        threading.Thread(target=self.work,args=(run,),daemon=True).start()

    def update_upstream(self):
        from upstream import prepare_latest
        self.set_busy(True);self.logs=[]
        self.status.configure(text='正在检查官方稳定版',text_color=INK)
        threading.Thread(target=self.work,args=(lambda:prepare_latest(self.settings,self.report),),daemon=True).start()

    def repack(self, dialog):
        folder = filedialog.askdirectory(parent=dialog, title='选择含 BUILD-INFO.json 的完整安装包目录')
        if not folder:
            return
        dialog.destroy()
        self.set_busy(True)
        self.logs = []
        threading.Thread(target=self.work, args=(lambda: package_existing(self.settings, folder, self.report),), daemon=True).start()

    def close(self):
        if self.busy:
            messagebox.showinfo('正在构建', '请等待本次构建完成，避免留下不完整安装包。', parent=self)
            return
        self.password = ''
        self.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--repack', type=Path)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--platforms', nargs='+', choices=('windows', 'android', 'linux'), default=['windows'])
    parser.add_argument('--complete-environment', action='store_true')
    parser.add_argument('--official-source', action='store_true')
    parser.add_argument('--verify-recipe', action='store_true')
    parser.add_argument('--authorize-external-key')
    parser.add_argument('--certificate-output', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--notes', type=Path)
    args = parser.parse_args()
    if args.check or args.repack or args.build or args.complete_environment or args.official_source or args.verify_recipe or args.authorize_external_key:
        settings = load_settings()
        def report(kind, payload):
            if sys.stdout:
                print(kind, json.dumps(payload, ensure_ascii=False) if isinstance(payload, (dict, tuple)) else payload, flush=True)
        if args.authorize_external_key:
            if not args.certificate_output: parser.error('--authorize-external-key requires --certificate-output')
            from external_certificate import authorize
            authorize(settings, args.authorize_external_key, args.certificate_output)
            report('ready', '已签发公开授权证书，主私钥未导出。')
        elif args.official_source or args.verify_recipe:
            from upstream import prepare_latest
            prepare_latest(settings,report,force=args.verify_recipe)
        elif args.complete_environment:
            from provision import complete_environment
            complete_environment(settings,report)
        elif args.check:
            if 'windows' in args.platforms: environment(settings)
            if any(p != 'windows' for p in args.platforms): check_local()
            report('ready', {'platforms': args.platforms, 'native_reusable': native_reusable(settings) if 'windows' in args.platforms else False, 'next': next_version(settings.source)})
        elif args.repack:
            package_existing(settings, args.repack, report)
        else:
            if not args.version or not args.notes:
                parser.error('--build requires --version and --notes')
            build, _ = next_version(settings.source)
            MultiPlatformBuilder(settings, report).build(build, args.version, args.notes.read_text(encoding='utf-8'), targets=args.platforms)
    else:
        if os.name == 'nt':
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID('NNU.ReleaseAssistant')
        Assistant().mainloop()


if __name__ == '__main__':
    main()
