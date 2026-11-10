#!/usr/bin/python3
"""Install user-owned launchers without evaluating user configuration as root."""
import argparse
import os
from pathlib import Path
import pwd
import shlex
import shutil
import subprocess
import sys


MARKER = 'X-NNU-Managed=true\n'


def desktop_directory(home):
    config = Path(os.environ.get('XDG_CONFIG_HOME', str(home / '.config'))) / 'user-dirs.dirs'
    if config.is_file():
        for line in config.read_text(encoding='utf8').splitlines():
            if line.strip().startswith('XDG_DESKTOP_DIR='):
                values = shlex.split(line.strip(), comments=True)
                if len(values) != 1:
                    return None
                value = values[0].split('=', 1)[1].replace('${HOME}', str(home)).replace('$HOME', str(home))
                path = Path(value)
                return path if path.is_absolute() and path != home else None
    return next((home / name for name in ('Desktop', '桌面') if (home / name).is_dir()), None)


def exec_path(path):
    value = str(path)
    if any(character in value for character in ('\n', '\r', '=')):
        raise ValueError('Unsupported desktop launcher path')
    value = value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
    return '"' + value.replace('\\', '\\\\').replace('%', '%%') + '"'


def ensure_shortcut(executable, installed=False, first_run=False):
    home = Path.home()
    desktop = desktop_directory(home)
    if desktop is None:
        return False
    mode = 'installed' if installed else 'portable'
    filename = 'RustDesk.desktop' if installed else 'RustDesk-Portable.desktop'
    target = desktop / filename
    state = Path(os.environ.get('XDG_STATE_HOME', str(home / '.local/state'))) / 'nnu-rustdesk' / ('desktop-' + mode)
    if target.is_symlink():
        return False
    if target.exists() and MARKER not in target.read_text(encoding='utf8'):
        return False
    if first_run and not target.exists() and state.is_file() and state.read_text(encoding='utf8') == str(executable):
        return False
    icon = 'rustdesk'
    if not installed:
        source_icon = Path(__file__).parent / 'rustdesk.png'
        data = Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
        icon_file = data / 'icons/hicolor/256x256/apps/nnu-rustdesk-portable.png'
        if source_icon.is_file():
            icon_file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_icon, icon_file)
            icon = str(icon_file).replace('\\', '\\\\')
    name = 'RustDesk VIP支持专业版' + ('' if installed else '（便携版）')
    command = ('' if installed else '/usr/bin/env -- ') + exec_path(executable)
    content = ('[Desktop Entry]\nType=Application\nName=' + name + '\nExec=' + command
               + ' %u\nIcon=' + icon + '\nTerminal=false\nStartupNotify=true\nStartupWMClass=rustdesk\n'
               + 'Categories=Network;RemoteAccess;\n' + MARKER)
    desktop.mkdir(parents=True, exist_ok=True)
    if not target.exists() or target.read_text(encoding='utf8') != content:
        with open(target, 'w', encoding='utf8', opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW, 0o755)) as output:
            output.write(content)
        target.chmod(0o755)
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(str(executable), encoding='utf8')
    gio = shutil.which('gio')
    if gio:
        result = subprocess.run([gio, 'set', '-t', 'boolean', str(target), 'metadata::trusted', 'true'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
        if result.returncode:
            print('Desktop metadata unavailable: ' + result.stderr.decode(errors='replace').strip(), file=sys.stderr)
    return True


def remove_installed():
    desktop = desktop_directory(Path.home())
    if desktop is None:
        return
    target = desktop / 'RustDesk.desktop'
    if target.is_file() and not target.is_symlink() and MARKER in target.read_text(encoding='utf8'):
        target.unlink()


def all_users(remove):
    for user in pwd.getpwall():
        if user.pw_uid != 0 and not 1000 <= user.pw_uid < 65534:
            continue
        if not Path(user.pw_dir).is_dir():
            continue
        env = dict(PATH='/usr/local/bin:/usr/bin:/bin', HOME=user.pw_dir, USER=user.pw_name, LOGNAME=user.pw_name)
        bus = Path('/run/user') / str(user.pw_uid) / 'bus'
        if bus.is_socket() and bus.stat().st_uid == user.pw_uid:
            env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(bus)
        def drop_privileges():
            os.initgroups(user.pw_name, user.pw_gid)
            os.setgid(user.pw_gid)
            os.setuid(user.pw_uid)
        action = '--remove-installed' if remove else '--installed'
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), action], env=env,
                                preexec_fn=drop_privileges, timeout=15)
        if result.returncode:
            print('Desktop launcher action failed for uid ' + str(user.pw_uid), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--all-users', action='store_true')
    parser.add_argument('--installed', action='store_true')
    parser.add_argument('--remove-installed', action='store_true')
    parser.add_argument('--executable')
    args = parser.parse_args()
    if args.all_users:
        if os.geteuid() != 0:
            parser.error('All-user installation requires root')
        all_users(args.remove_installed)
    elif args.remove_installed:
        remove_installed()
    else:
        executable = Path(args.executable or '/usr/bin/rustdesk')
        installed = args.installed or executable.resolve() == Path('/usr/share/rustdesk/rustdesk')
        if not installed and os.environ.get('APPIMAGE'):
            executable = Path(os.environ['APPIMAGE'])
        if not executable.is_absolute() or not executable.is_file():
            parser.error('Launcher executable does not exist')
        ensure_shortcut(executable, installed, first_run=not args.installed)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Could not create desktop launcher: ' + str(error), file=sys.stderr)
        sys.exit(1)
