#!/usr/bin/env python3
"""Opt-in, per-user wallpaper edits; never execute manage() as root."""
import argparse
import base64
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

XFCE = '.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml'
STATE = '.config/cream-wallpaper/state.json'
XF_KEYS = {'image-path', 'last-image', 'image-style', 'image-show', 'backdrop-cycle-enable'}
STYLES = dict(zoom='5', scaled='4', centered='1', stretched='3', spanned='6', wallpaper='2')
PM_MODES = dict(zoom='crop', scaled='fit', centered='center', stretched='stretch', spanned='screen', wallpaper='tile')
QT_MODES = dict(zoom='zoom', scaled='fit', centered='center', stretched='stretch', spanned='stretch', wallpaper='tile')


def safe(home, rel):
    home = Path(home)
    if not home.is_dir() or home.is_symlink():
        raise ValueError('unsafe home')
    p = Path(rel)
    if p.is_absolute() or '..' in p.parts:
        raise ValueError('unsafe relative path')
    cur = home
    for part in p.parts:
        cur /= part
        if cur.is_symlink():
            raise ValueError('symlink in user path')
    return cur


def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.cream-wallpaper.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def xml_properties(root):
    result = {}
    def walk(parent, prefix):
        for child in parent.findall('property'):
            key = prefix + '/' + child.get('name', '')
            result[key] = child
            walk(child, key)
    walk(root, '')
    return result


def owned(key):
    return key.startswith('/backdrop/') and key.rsplit('/', 1)[-1] in XF_KEYS


def parse_xml(raw):
    return ET.fromstring(raw, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))


def xml_values(raw):
    if raw is None:
        return {}
    return {key: dict(node.attrib) for key, node in xml_properties(parse_xml(raw)).items() if owned(key)}


def ensure_property(root, path):
    parent = root
    for part in path.strip('/').split('/'):
        child = next((n for n in parent.findall('property') if n.get('name') == part), None)
        if child is None:
            child = ET.SubElement(parent, 'property', name=part, type='empty')
        parent = child
    return parent


def xml_apply(raw, image, mode):
    root = parse_xml(raw) if raw is not None else ET.Element('channel', name='xfce4-desktop', version='1.0')
    props = xml_properties(root)
    bases = {key.rsplit('/', 1)[0] for key in props if owned(key)}
    # Legacy monitor defaults are also the migration source for a new monitor.
    bases.update('/backdrop/screen0/monitor%d' % n for n in range(4))
    for base in sorted(bases):
        modern = '/workspace' in base
        values = {'last-image' if modern else 'image-path': ('string', image),
                  'image-style': ('int', STYLES[mode]),
                  'backdrop-cycle-enable' if modern else 'image-show': ('bool', 'false' if modern else 'true')}
        # Existing aliases must not retain another picture.
        for alias in ('last-image', 'image-path'):
            if base + '/' + alias in props:
                values[alias] = ('string', image)
        for key, (typ, value) in values.items():
            node = ensure_property(root, base + '/' + key)
            node.set('type', typ)
            node.set('value', value)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def xml_restore(raw, before, after):
    root = parse_xml(raw)
    old = xml_values(before)
    applied = xml_values(after)
    current = xml_properties(root)
    images = {v.get('value') for k, v in applied.items() if k.endswith(('/image-path', '/last-image'))}
    migrated_bases = {k.rsplit('/', 1)[0] for k, v in current.items()
                      if owned(k) and k.endswith(('/image-path', '/last-image')) and v.get('value') in images}
    for key, node in list(current.items()):
        if not owned(key):
            continue
        expected = applied.get(key)
        migrated = key not in applied and key.rsplit('/', 1)[0] in migrated_bases
        if expected is not None and node.attrib != expected:
            continue  # a subsequent personal change wins
        if expected is None and not migrated:
            continue
        if migrated:
            leaf = key.rsplit('/', 1)[-1]
            aliases = {'image-path', 'last-image'} if leaf in ('image-path', 'last-image') else {leaf}
            candidates = [v for k, v in applied.items() if k.rsplit('/', 1)[-1] in aliases]
            if not any(node.get('type') == v.get('type') and node.get('value') == v.get('value') for v in candidates):
                continue
        if key in old:
            node.attrib.clear()
            node.attrib.update(old[key])
        else:
            parent = current.get(key.rsplit('/', 1)[0], root)
            parent.remove(node)
    old_paths = set(xml_properties(parse_xml(before))) if before is not None else set()
    # Remove only empty structural nodes introduced by us or by migration.
    for key, node in reversed(list(xml_properties(root).items())):
        if key.startswith('/backdrop') and key not in old_paths and len(node) == 0 and node.get('type') == 'empty':
            parent_path = key.rsplit('/', 1)[0]
            parent = xml_properties(root).get(parent_path, root)
            parent.remove(node)
    if before is None and len(root) == 0:
        return None
    def signature(node):
        text = node.text if node.text and node.text.strip() else None
        return node.tag, sorted(node.attrib.items()), text, [signature(c) for c in node]
    if before is not None and signature(root) == signature(parse_xml(before)):
        return before
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def ini_values(raw, section, keys):
    values = {}
    cur = ''
    for line in (raw or b'').decode().splitlines(keepends=True):
        if line.strip().startswith('['):
            cur = line.strip().strip('[]')
        elif cur == section and '=' in line:
            key = line.split('=', 1)[0].strip()
            if key in keys:
                values.setdefault(key, []).append(line)
    return values


def ini_set(raw, section, replacements):
    lines = (raw or b'').decode().splitlines(keepends=True)
    out, seen, cur, found = [], set(), '', False
    def missing():
        if out and not out[-1].endswith('\n') and any(k not in seen and v for k, v in replacements.items()):
            out[-1] += '\n'
        for key, value in replacements.items():
            if key not in seen:
                out.extend(value)
                seen.add(key)
    for line in lines:
        if line.strip().startswith('['):
            if cur == section:
                missing()
            cur = line.strip().strip('[]')
            found |= cur == section
        if cur == section and '=' in line and not line.lstrip().startswith(('#', ';')):
            key = line.split('=', 1)[0].strip()
            if key in replacements:
                if key not in seen:
                    out.extend(replacements[key])
                    seen.add(key)
                continue
        out.append(line)
    if cur == section:
        missing()
    if not found and any(replacements.values()):
        if out and not out[-1].endswith('\n'):
            out[-1] += '\n'
        out.append('[' + section + ']\n')
        missing()
    return ''.join(out).encode()


def ini_apply(raw, kind, image, mode):
    if kind == 'lxqt':
        section = 'Desktop'
        values = dict(Wallpaper=image, WallpaperMode=QT_MODES[mode], WallpaperCommon='true',
                      PerScreenWallpaper='false', SlideShowInterval='0')
    else:
        section = '*'
        values = dict(wallpaper=image, wallpaper_mode=PM_MODES[mode], wallpaper_common='1')
    return ini_set(raw, section, {k: [k + '=' + v + '\n'] for k, v in values.items()})


def ini_restore(raw, before, after, kind):
    if raw == after:
        return before
    section = 'Desktop' if kind == 'lxqt' else '*'
    keys = {'Wallpaper', 'WallpaperMode', 'WallpaperCommon', 'PerScreenWallpaper', 'SlideShowInterval'} if kind == 'lxqt' else {'wallpaper', 'wallpaper_mode', 'wallpaper_common'}
    original, applied, current = (ini_values(data, section, keys) for data in (before, after, raw))
    changes = {k: original.get(k, []) for k in keys if current.get(k) == applied.get(k)}
    restored = ini_set(raw, section, changes)
    if restored == (before or b''):
        return before
    # A section introduced by us is removed only when no other content is left.
    if before is None and restored.strip() == ('[' + section + ']').encode():
        return None
    return restored


def manage(home, action, image, mode, kinds):
    home = Path(home)
    state_path = safe(home, STATE)
    state = json.loads(state_path.read_text()) if state_path.exists() else {'marker': 'cream-wallpaper-1', 'files': {}}
    if state.get('marker') != 'cream-wallpaper-1':
        raise ValueError('foreign wallpaper state')
    files = state['files']
    targets = {}
    if action == 'apply':
        if 'xfce' in kinds:
            targets[XFCE] = 'xfce'
        for kind, folder, filename, default in [('lxde', 'pcmanfm', 'desktop-items-*.conf', 'LXDE/desktop-items-0.conf'),
                                                 ('lxqt', 'pcmanfm-qt', 'settings.conf', 'lxqt/settings.conf')]:
            if kind in kinds:
                base = safe(home, '.config/' + folder)
                existing = list(base.glob('*/' + filename)) if base.exists() else []
                for p in existing or [base / default]:
                    targets[str(p.relative_to(home))] = kind
    else:
        targets = {rel: rec['kind'] for rel, rec in files.items()}
    # Check every path before changing anything.
    for rel in targets:
        safe(home, rel)
    for rel, kind in targets.items():
        path = safe(home, rel)
        raw = path.read_bytes() if path.exists() else None
        if action == 'apply':
            if rel not in files:
                files[rel] = {'kind': kind, 'before': None if raw is None else base64.b64encode(raw).decode(), 'mode': (path.stat().st_mode & 0o777) if path.exists() else 0o600}
            updated = xml_apply(raw, image, mode) if kind == 'xfce' else ini_apply(raw, kind, image, mode)
            files[rel]['after'] = base64.b64encode(updated).decode()
            # Persist the undo record before the edit, including on a mode change.
            atomic(state_path, json.dumps(state, sort_keys=True).encode())
            if raw != updated:
                atomic(path, updated, files[rel]['mode'])
        elif raw is not None:
            rec = files[rel]
            before = base64.b64decode(rec['before']) if rec['before'] is not None else None
            after = base64.b64decode(rec['after'])
            restored = xml_restore(raw, before, after) if kind == 'xfce' else ini_restore(raw, before, after, kind)
            if restored is None:
                path.unlink()
            else:
                atomic(path, restored, rec['mode'])
    if action == 'remove' and state_path.exists():
        state_path.unlink()


def eligible_account(name, uid, home, shell):
    return (1000 <= int(uid) < 65534
            and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.@+-]{0,127}\$?', name) is not None
            and home.startswith('/')
            and not shell.endswith(('/nologin', '/false')))


def dispatch(args):
    # getent also works with NSS; CREAM_ROOT is used only by the H fixtures.
    rows = subprocess.check_output(['getent', 'passwd'], text=True).splitlines()
    users = []
    for row in rows:
        fields = row.split(':')
        if len(fields) != 7:
            continue
        name, _, uid, _, _, home, _ = fields
        if uid.isdecimal() and eligible_account(name, uid, home, fields[6]):
            users.append((name, uid, home))
    if args.dispatch == 'check':
        sessions = subprocess.run(['loginctl', 'list-sessions', '--no-legend'], capture_output=True, text=True, check=False)
        for line in sessions.stdout.splitlines():
            fields = line.split()
            if len(fields) < 2 or fields[1] not in {u[1] for u in users}:
                continue
            kind = subprocess.run(['loginctl', 'show-session', fields[0], '-p', 'Type', '--value'], capture_output=True, text=True, check=False).stdout.strip()
            if kind in ('x11', 'wayland'):
                raise ValueError('log out graphical users before configure/remove wallpaper')
        return
    for name, _, home in users:
        cmd = ['timeout', '-k', '5', '30', 'runuser', '-u', name, '--', 'env', '-i',
               'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'LANG=C.UTF-8',
               '/usr/bin/python3', str(Path(__file__).resolve()), args.dispatch,
               '--home', args.root.rstrip('/') + home, '--image', args.image, '--mode', args.mode,
               '--kinds', args.kinds]
        # No inherited cream lock or secret environment reaches the user process.
        result = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, close_fds=True, check=False)
        if result.returncode:
            raise ValueError('user wallpaper operation failed for ' + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', nargs='?', choices=['apply', 'remove'])
    parser.add_argument('--dispatch', choices=['check', 'apply', 'remove'])
    parser.add_argument('--root', default='')
    parser.add_argument('--home')
    parser.add_argument('--image', default='')
    parser.add_argument('--mode', default='zoom', choices=list(STYLES))
    parser.add_argument('--kinds', default='')
    args = parser.parse_args()
    if args.dispatch:
        dispatch(args)
    else:
        if os.geteuid() == 0:
            raise ValueError('personal settings must be edited as the user')
        if not args.home or not args.action:
            raise ValueError('home and action required')
        account = pwd.getpwuid(os.geteuid())
        if not eligible_account(account.pw_name, account.pw_uid, account.pw_dir, account.pw_shell):
            return  # Xsession must never edit an account that dispatch cannot restore.
        if Path(args.home).resolve() != Path(account.pw_dir).resolve():
            raise ValueError('home differs from the account home used by dispatch')
        for process in ('xfconfd', 'pcmanfm', 'pcmanfm-qt'):
            if subprocess.run(['pgrep', '-u', str(os.geteuid()), '-x', process],
                              stdout=subprocess.DEVNULL, check=False).returncode == 0:
                raise ValueError('log out all desktop sessions before editing personal settings')
        manage(Path(args.home), args.action, args.image, args.mode, args.kinds.split(','))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, ET.ParseError, json.JSONDecodeError) as exc:
        print('wallpaper: ' + str(exc), file=sys.stderr)
        sys.exit(1)
