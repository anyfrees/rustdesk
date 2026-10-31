"""Adapt the archived upstream bridge to the unchanged 1.5.0 FFI signatures.

Source: rustdesk/rustdesk Actions artifact 13021968585 (run 41149005952),
commit 33a154a5d7502419381dc601aff1e4b0c660054d, Flutter 3.22.3 / FRB 1.80.1.
The original 1.5.0 artifacts have expired. No code generator is run locally.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
extra = ('main_reload_keyboard_shortcuts', 'main_get_default_keyboard_shortcuts',
         'main_renew_trusted_devices')
for filename in ('bridge_generated.rs', 'bridge_generated.io.rs'):
    path = root / 'src' / filename
    text = path.read_text(encoding='utf-8')
    for name in extra:
        if filename.endswith('.io.rs'):
            pattern = r'#\[no_mangle\]\npub extern "C" fn wire_' + name + r'\b.*?\n}\n'
        else:
            pattern = r'fn wire_' + name + r'_impl\b.*?\n}\n'
        text = re.sub(pattern, '', text, flags=re.S)
    if filename == 'bridge_generated.rs':
        for name in ('main_set_option', 'main_set_options', 'main_get_trusted_devices',
                     'main_remove_trusted_devices', 'main_clear_trusted_devices'):
            pattern = r'(move \|task_callback\| )' + name + r'\(([^\n]*)\)(,?)\n'
            text = re.sub(pattern, r'\1Ok(' + name + r'(\2))\3\n', text)
    path.write_text(text, encoding='utf-8')
