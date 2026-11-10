import ctypes
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
import sys
from unittest.mock import patch

if not sys.platform.startswith('linux'):
    raise unittest.SkipTest('Linux desktop launcher integration')

spec = importlib.util.spec_from_file_location('shortcut', Path(__file__).with_name('linux_desktop_shortcut.py'))
shortcut = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shortcut)


class DesktopShortcutTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / '.config').mkdir()
        (self.home / '.config/user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/桌面 工作区"\n')
        self.desktop = self.home / '桌面 工作区'
        self.env = patch.dict(os.environ, dict(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                             XDG_STATE_HOME=str(self.home / '.local/state'), XDG_DATA_HOME=str(self.home / '.local/share')))
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_portable_launcher_opens_exact_quoted_path_and_is_not_duplicated(self):
        executable = self.home / '便携版 $user % test "quoted".sh'
        proof = self.home / 'launched'
        executable.write_text('#!/bin/sh\nprintf ok > "' + str(proof) + '"\n')
        executable.chmod(0o755)
        self.assertTrue(shortcut.ensure_shortcut(executable, first_run=True))
        target = self.desktop / 'RustDesk-Portable.desktop'
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        shortcut.ensure_shortcut(executable, first_run=True)
        self.assertEqual(len(list(self.desktop.glob('*.desktop'))), 1)
        gio = ctypes.CDLL('libgio-2.0.so.0')
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_info_launch.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        app = gio.g_desktop_app_info_new_from_filename(os.fsencode(target))
        self.assertTrue(app, target.read_text())
        self.assertTrue(gio.g_app_info_launch(app, None, None, None))
        gio.g_object_unref.argtypes = [ctypes.c_void_p]
        gio.g_object_unref(app)
        for _ in range(30):
            if proof.exists():
                break
            time.sleep(.05)
        self.assertEqual(proof.read_text(), 'ok')
        target.unlink()
        self.assertFalse(shortcut.ensure_shortcut(executable, first_run=True))
        self.assertFalse(target.exists())

    def test_install_remove_keeps_unrelated_shortcuts(self):
        self.assertTrue(shortcut.ensure_shortcut(Path('/usr/bin/rustdesk'), installed=True))
        unrelated = self.desktop / 'other.desktop'
        unrelated.write_text('user shortcut')
        shortcut.remove_installed()
        self.assertFalse((self.desktop / 'RustDesk.desktop').exists())
        self.assertEqual(unrelated.read_text(), 'user shortcut')
        target = self.desktop / 'RustDesk.desktop'
        target.write_text('user-customized shortcut')
        self.assertFalse(shortcut.ensure_shortcut(Path('/usr/bin/rustdesk'), installed=True))
        shortcut.remove_installed()
        self.assertEqual(target.read_text(), 'user-customized shortcut')

    def test_disabled_desktop_does_not_create_a_launcher(self):
        (self.home / '.config/user-dirs.dirs').write_text('XDG_DESKTOP_DIR="$HOME/"\n')
        self.assertFalse(shortcut.ensure_shortcut(Path('/usr/bin/rustdesk'), installed=True))
        self.assertFalse((self.home / 'RustDesk.desktop').exists())


if __name__ == '__main__':
    unittest.main()
