"""Emergency recovery from a trusted server terminal; never prints the password."""
import argparse
import getpass
import os
import re
import sqlite3
from pathlib import Path

from werkzeug.security import generate_password_hash


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--username')
    parser.add_argument('--revoke-passkeys', action='store_true')
    args = parser.parse_args()
    if args.username is not None and not re.fullmatch(r'[\w.@+-]{3,64}', args.username):
        parser.error('Username must contain 3–64 letters, digits or . _ @ + -')
    password = getpass.getpass('New password (12–128 characters): ')
    if not 12 <= len(password) <= 128 or password != getpass.getpass('Confirm password: '):
        parser.error('Passwords must match and contain 12–128 characters')
    password_hash = generate_password_hash(password)
    del password
    path = Path(os.environ.get('NNU_STATE', '/state')) / 'admin.sqlite'
    with sqlite3.connect(path) as c:
        c.execute('BEGIN IMMEDIATE')
        if args.username is None:
            c.execute('UPDATE account SET password_hash=?,revision=revision+1 WHERE id=1', (password_hash,))
        else:
            c.execute('UPDATE account SET username=?,password_hash=?,revision=revision+1 WHERE id=1',
                      (args.username, password_hash))
        c.execute('DELETE FROM sessions')
        c.execute('DELETE FROM challenges')
        if args.revoke_passkeys:
            c.execute('DELETE FROM passkeys')
    print('Account recovered; existing sessions revoked.')
