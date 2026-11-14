#!/usr/bin/env bash
# Per-user wallpaper changes are opt-in; test real XML/INI edits on a scratch home.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/../files/user-wallpaper.py" <<'PY'
import importlib.util
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('wallpaper_user', sys.argv.pop())
wp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wp)

class Wallpaper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)

    def write(self, rel, text):
        p = self.home / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def apply(self, kinds):
        wp.manage(self.home, 'apply', '/opt/cream/ext/wallpaper/images/dst_1080.jpg', 'zoom', kinds)

    def remove(self):
        wp.manage(self.home, 'remove', '', '', [])

    def test_xfce_existing_channel_and_reinstall(self):
        p = self.write(wp.XFCE, '<channel name="xfce4-desktop" version="1.0"><property name="desktop-icons" type="empty"><property name="style" type="int" value="0"/></property><property name="backdrop" type="empty"><property name="screen0" type="empty"><property name="monitorVirtual-1" type="empty"><property name="workspace0" type="empty"><property name="last-image" type="string" value="/old.jpg"/><property name="image-style" type="int" value="4"/></property></property></property></property></channel>')
        before = p.read_bytes()
        for _ in range(2):
            self.apply(['xfce'])
            self.assertIn('dst_1080.jpg', p.read_text())
            self.assertIn('name="style" type="int" value="0"', p.read_text())
            self.apply(['xfce'])
            self.remove()
            self.assertEqual(before, p.read_bytes())

    def test_xfce_first_login_migrated_properties_are_removed(self):
        self.apply(['xfce'])
        p = self.home / wp.XFCE
        tree = ET.parse(p)
        screen = tree.getroot().find('./property/property')
        mon = ET.SubElement(screen, 'property', name='monitorVirtual-1', type='empty')
        ws = ET.SubElement(mon, 'property', name='workspace0', type='empty')
        ET.SubElement(ws, 'property', name='last-image', type='string', value='/opt/cream/ext/wallpaper/images/dst_1080.jpg')
        ET.SubElement(ws, 'property', name='image-style', type='int', value='5')
        tree.write(p)
        self.remove()
        self.assertFalse(p.exists())

    def test_xfce_unrelated_edit_survives_remove(self):
        self.apply(['xfce'])
        p = self.home / wp.XFCE
        tree = ET.parse(p)
        ET.SubElement(tree.getroot(), 'property', name='desktop-menu', type='bool', value='false')
        tree.write(p)
        self.remove()
        self.assertIn('desktop-menu', p.read_text())
        self.assertNotIn('dst_1080.jpg', p.read_text())

    def test_lxde_existing_profile_exact_restore(self):
        p = self.write('.config/pcmanfm/LXDE/desktop-items-0.conf', '[*]\nwallpaper=/old.png\nwallpaper_mode=fit\nshow_documents=1\n')
        before = p.read_bytes()
        self.apply(['lxde'])
        self.assertIn('wallpaper=/opt/cream/', p.read_text())
        self.assertIn('show_documents=1', p.read_text())
        self.remove()
        self.assertEqual(before, p.read_bytes())

    def test_lxqt_existing_profile_and_unrelated_changes(self):
        p = self.write('.config/pcmanfm-qt/lxqt/settings.conf', '[Desktop]\nWallpaper=/old.png\nWallpaperMode=fit\nShowTrash=true\n\n[System]\nTerminal=qterminal\n')
        self.apply(['lxqt'])
        self.assertIn('WallpaperMode=zoom', p.read_text())
        p.write_text(p.read_text().replace('Terminal=qterminal', 'Terminal=xterm'))
        self.remove()
        self.assertIn('Wallpaper=/old.png', p.read_text())
        self.assertIn('WallpaperMode=fit', p.read_text())
        self.assertIn('Terminal=xterm', p.read_text())
        self.assertNotIn('WallpaperCommon=', p.read_text())

    def test_lxde_lxqt_first_login_remove_reinstall(self):
        for kind, rel in [('lxde', '.config/pcmanfm/LXDE/desktop-items-0.conf'), ('lxqt', '.config/pcmanfm-qt/lxqt/settings.conf')]:
            self.apply([kind])
            self.assertTrue((self.home / rel).exists())
            self.remove()
            self.assertFalse((self.home / rel).exists())
            self.apply([kind])
            self.remove()
            self.assertFalse((self.home / rel).exists())

    def test_symlink_parent_refused(self):
        target = self.home / 'target'
        target.mkdir()
        (self.home / '.config').symlink_to(target)
        with self.assertRaises(ValueError):
            self.apply(['xfce'])
        self.assertEqual([], list(target.iterdir()))

    def test_gnome_personal_database_never_touched(self):
        p = self.write('.config/dconf/user', 'personal binary database')
        self.apply(['gnome'])
        self.remove()
        self.assertEqual('personal binary database', p.read_text())

    def test_lxqt_exact_restore_without_trailing_newline(self):
        p = self.write('.config/pcmanfm-qt/lxqt/settings.conf', '[Desktop]\nWallpaper=/old.jpg')
        before = p.read_bytes()
        self.apply(['lxqt'])
        self.assertIn('WallpaperMode=zoom', p.read_text())
        self.remove()
        self.assertEqual(before, p.read_bytes())

    def test_subsequent_personal_wallpaper_is_preserved(self):
        self.apply(['lxde'])
        p = self.home / '.config/pcmanfm/LXDE/desktop-items-0.conf'
        p.write_text(p.read_text().replace('/opt/cream/ext/wallpaper/images/dst_1080.jpg', '/personal.jpg'))
        self.remove()
        self.assertIn('wallpaper=/personal.jpg', p.read_text())

    def test_xfce_mode_change_keeps_first_snapshot(self):
        p = self.write(wp.XFCE, '<channel name="xfce4-desktop" version="1.0"/>')
        before = p.read_bytes()
        self.apply(['xfce'])
        wp.manage(self.home, 'apply', '/opt/cream/ext/wallpaper/images/dst_1080.jpg', 'scaled', ['xfce'])
        self.assertIn('value="4"', p.read_text())
        self.remove()
        self.assertEqual(before, p.read_bytes())

    def test_state_symlink_refused_before_user_edits(self):
        p = self.write(wp.XFCE, '<channel name="xfce4-desktop" version="1.0"/>')
        before = p.read_bytes()
        target = self.write('unrelated', 'not a state')
        state = self.home / wp.STATE
        state.parent.mkdir(parents=True)
        state.symlink_to(target)
        with self.assertRaises(ValueError):
            self.apply(['xfce'])
        self.assertEqual(before, p.read_bytes())
        self.assertEqual('not a state', target.read_text())

    def test_xfce_comments_survive_apply_and_unrelated_edit(self):
        p = self.write(wp.XFCE, '<channel name="xfce4-desktop" version="1.0"><!-- personal comment --><property name="desktop-menu" type="bool" value="true"/></channel>')
        self.apply(['xfce'])
        self.assertIn('<!-- personal comment -->', p.read_text())
        p.write_text(p.read_text().replace('name="desktop-menu" type="bool" value="true"', 'name="desktop-menu" type="bool" value="false"'))
        self.remove()
        self.assertIn('<!-- personal comment -->', p.read_text())
        self.assertIn('name="desktop-menu" type="bool" value="false"', p.read_text())

unittest.main()
PY
