#!/usr/bin/env python3
"""Draft converter of a layout 2 extension into cream/v1 (cream spec §4.7).

    tools/convert-v1.py SRC                 draft manifest to stdout, report to stderr
    tools/convert-v1.py SRC --out DST       converted tree in DST (new directory)
    tools/convert-v1.py SRC --in-place      convert SRC itself (then `git add` it)
    tools/convert-v1.py ... --report FILE   the report into FILE instead of stderr

Semi-automatic, one-off (plan 2026-10-19, Task 2; removed in Task 28). What it
does mechanically:

- extension.yaml: `layout`/`family`/`arch`/`phase` -> `schema`/`platform`/
  `targets`; `conflicts` -> `conflicts.extensions`; version gets a new major;
  `targets.live` and `live_note` from the table of the plan; `summary` from the
  first paragraph of README.md;
- `knobs` -> `config.keys`: `ro:` -> `readonly`, `secret` -> `secret: file`,
  `secret:hook` -> `secret: file` (ruling Р4, reported), `?` or an empty
  default -> `empty`, `PREFIX_*` -> `pattern`, `BISQUITE_` prefix dropped (Р8);
- hooks: `install.sh` -> `hooks/install`, `configure.sh` -> `hooks/configure`,
  `knobs.apply` -> `hooks/apply`, `update.sh` -> `hooks/upgrade`; the
  configure unit (the unit whose ExecStart runs configure.sh) is dropped and
  becomes `hooks.configure.stage`/`after`/`before`/`wants` (the plan's table
  wins over the unit when they differ — reported); other systemd units of the
  extension root go to `files` at their current path;
- `lib/get_cloud_user.sh`, `lib/l4t`, `bisquite-desktop` -> `depends`.

What it does NOT do: edit scripts. Their content is copied byte for byte; the
report lists every line with a bisquite name or a layout 2 mechanism
(file:line, grouped by the replacement to make) — the checklist of the
executor, together with the manifest-level TODOs (live_note, stage, remove
hook, exit codes, version ranges of `depends`).

A manifest that already says `schema: cream/v1` is left alone (exit 0): a
second run changes nothing.

Exit: 0 — converted or already cream/v1; 1 — the input cannot be converted
(no manifest, not layout 2, a bad knobs line, DST exists); 2 — usage.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - depends on the host
    sys.stderr.write("Нужен PyYAML: pip install pyyaml (или apt install python3-yaml)\n")
    sys.exit(2)

# --- the plan's tables (docs/plans/2026-10-19-cream-v1-migration.md) --------

# targets.live; live_note drafts for confirm/no come from the plan or from the
# inventory §6 ("Причина") and are reported for review.
LIVE: dict[str, tuple[str, str]] = {
    "btop": ("yes", ""), "firefox": ("yes", ""), "yq": ("yes", ""),
    "locale": ("yes", ""), "can": ("yes", ""),
    "docker": ("confirm", "удаляет docker.io, podman-docker, containerd, runc, если стоят; "
                          "на Raspberry Pi правит cmdline.txt — нужна перезагрузка"),
    "firewall": ("confirm", "policy drop на входе: по SSH легко отрезать себя"),
    "network-manager": ("confirm", "смена сетевого стека на живой машине может отрезать доступ"),
    "cloud-growroot": ("no", "правит модули cloud-init первой загрузки; на живой машине корень уже не вырастет"),
    "nocloud-cidata": ("no", "влияет только на источник данных cloud-init первой загрузки"),
    "gnome": ("confirm", "большой набор пакетов, graphical.target по умолчанию, смена DM — перезагрузка"),
    "xfce4": ("confirm", "большой набор пакетов, graphical.target по умолчанию, смена DM — перезагрузка"),
    "lxde": ("confirm", "большой набор пакетов, graphical.target по умолчанию, смена DM — перезагрузка"),
    "cloud-user-desktop": ("yes", ""), "wallpaper": ("yes", ""), "code-server": ("yes", ""),
    "kiosk": ("confirm", "захватывает экран: браузер на весь экран после входа"),
    "chromium-kiosk": ("confirm", "сторонний репозиторий; захватывает экран"),
    "selkies": ("yes", ""), "x11vnc": ("yes", ""), "vino-vnc": ("yes", ""), "rustdesk": ("yes", ""),
    "jetson-stats": ("yes", ""),
    "nvidia": ("confirm", "модули под все ядра /lib/modules; blacklist nouveau — перезагрузка"),
    "nvidia-container-toolkit": ("confirm", "правит /etc/docker/daemon.json и перезапускает docker"),
    "nvidia-jetpack": ("confirm", "станция прошивки: NFS-сервер, binfmt, USB autosuspend; "
                                  "нужен перезапуск systemd-binfmt"),
    "cuda-toolkit": ("yes", ""), "tensorrt": ("yes", ""), "l4t-gstreamer": ("yes", ""),
    "l4t-opencv": ("yes", ""), "l4t-pytorch": ("yes", ""), "l4t-tensorflow": ("yes", ""),
    "l4t-board-fdt": ("confirm", "правит extlinux.conf; нужна перезагрузка"),
    "l4t-boot-verify": ("yes", ""),
    "l4t-kernel-kvm": ("no", "~3 ч сборки ядра, меняет DEFAULT загрузчика и root=PARTUUID — только базовый образ"),
    "sensing-gmsl2-camera": ("confirm", "подменяет /boot/Image, DTB-оверлеи, extlinux.conf, держит ядро apt-mark hold"),
    "can-usb": ("confirm", "собирает модули под ядро Sensing; нужна перезагрузка"),
    "pixelflux-tegra": ("yes", ""), "pixelflux-v4l2m2m": ("yes", ""),
}

# hooks.configure by the plan: (stage, after, before). Absent — the unit decides.
STAGE: dict[str, tuple[str, list[str], list[str]]] = {
    "docker": ("system", ["docker.service"], []),
    "firewall": ("early", [], []),
    "code-server": ("cloud-user", [], []),
    "wallpaper": ("cloud-user", [], []),
    "jetson-stats": ("cloud-user", [], []),
    "kiosk": ("graphical", [], []),
    "chromium-kiosk": ("system", [], []),
    "selkies": ("graphical", [], []),
    "x11vnc": ("graphical", ["display-manager.service"], []),
    "vino-vnc": ("system", ["cloud-init.service"],
                 ["display-manager.service", "gdm.service", "gdm3.service", "lightdm.service"]),
    "rustdesk": ("system", [], []),
    "pixelflux-tegra": ("graphical", [], []),
    "pixelflux-v4l2m2m": ("graphical", [], []),
}

# Minimal cream of a configure stage newer than 1.0 (cream docs/cli.md): the 1.1
# stages need 1.1.0, cloud-user needs 1.1.1 — 1.1.0 does not start it with
# cloud-init disabled (plan 2026-10-19, ruling R14; tools/lint-hooks.sh).
STAGE_CREAM = {"early": "1.1.0", "graphical": "1.1.0", "cloud-user": "1.1.1"}

# Ordering a stage already gives (cream spec §6.4) or that only made sense for
# a self-made unit; dropped from after/before/wants and reported.
IMPLIED = {
    "network.target", "network-online.target", "network-pre.target", "local-fs.target",
    "sysinit.target", "multi-user.target", "graphical.target", "cloud-init.target",
    "cloud-final.service",
}
IMPLIED_GRAPHICAL = {"display-manager.service", "gdm.service", "gdm3.service", "lightdm.service"}

# Replacements in scripts and docs (inventory §8, rulings Р2, Р7, Р8): regex ->
# what to do. Lines are only reported, never rewritten.
HOOK_FILES = {"hooks/install", "hooks/configure", "hooks/apply", "hooks/upgrade"}
RULES: list[tuple[str, re.Pattern[str], str, bool]] = [
    # (id, regex, advice, hooks only)
    ("script-dir", re.compile(r"(SCRIPT_DIR|HERE)=.*BASH_SOURCE"),
     "каталог скрипта теперь hooks/ — файлы расширения от CREAM_EXT_DIR (cwd хука)", True),
    ("conf", re.compile(r"lib/bisquite-conf|bisquite-conf\b|\bconf_(init|get|set|load|keys|check|validate|cli_set)\b"),
     "bisquite-conf → ключи из окружения хука, `cream set/show/config`; conf_init не нужен (§8)", False),
    ("cloud-user", re.compile(r"lib/get_cloud_user\.sh"),
     "→ \"${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh\" (depends cloud-user)", False),
    ("l4t", re.compile(r"lib/l4t\b"), "→ /opt/cream/ext/l4t/… (depends l4t)", False),
    ("desktop", re.compile(r"bisquite-desktop"), "→ расширение desktop: depends и его действия", False),
    ("opt", re.compile(r"/opt/bisquite"), "/opt/bisquite → /opt/cream/ext", False),
    ("etc", re.compile(r"/etc/bisquite"), "/etc/bisquite/<домен> → /etc/cream/<расширение>", False),
    ("var", re.compile(r"/var/lib/bisquite"), "/var/lib/bisquite → /var/lib/cream/ext", False),
    ("nft", re.compile(r"inet bisquite"), "inet bisquite → inet cream (Р2)", False),
    ("chain", re.compile(r"BISQUITE-INPUT"), "BISQUITE-INPUT → CREAM-INPUT (Р2)", False),
    ("conf-root", re.compile(r"BISQUITE_CONF_ROOT"), "BISQUITE_CONF_ROOT → CREAM_ROOT (Р8)", False),
    ("prefix", re.compile(r"BISQUITE_(?!CONF_ROOT)[A-Z0-9_]+"), "BISQUITE_<X> → без префикса (Р8)", False),
    ("guest-file", re.compile(r"\b(zz|10|99)-bisquite-"), "файл в госте → имя по расширению или cream (опись §8)", False),
    ("cli", re.compile(r"/usr/local/sbin/bisquite-|bisquite-(firewall|sensing|l4t)"),
     "CLI → действие (`cream run <ext> …`), юнит — по имени расширения (Р7)", False),
    ("units", re.compile(r"systemctl\s+(enable|disable)\b|\.wants/|install\s[^#]*\.(service|timer|path|socket)\b"),
     "юниты раскладывает cream (`files`), configure включает cream — убрать из хука", True),
]

UNIT_SUFFIXES = (".service", ".timer", ".path", ".socket")


class ConvertError(Exception):
    pass


# --- knobs -------------------------------------------------------------------

def split_knobs_line(line: str) -> list[str]:
    """Same grammar as _conf_split_fields of lib/bisquite-conf."""
    fields: list[str] = []
    s = line
    for _ in range(3):
        s = s.lstrip()
        if not s:
            raise ValueError("ожидали «ключ тип умолчание описание»")
        if s.startswith('"'):
            s = s[1:]
            if '"' not in s:
                raise ValueError("незакрытая кавычка")
            f, s = s.split('"', 1)
            if s and not s[0].isspace():
                raise ValueError("после кавычки нужен пробел")
        else:
            m = re.match(r"\S+", s)
            f = m.group(0)
            s = s[len(f):]
        fields.append(f)
    fields.append(s.strip())
    return fields


def convert_knobs(path: Path, notes: list[str]) -> list[tuple[str, dict]]:
    keys: list[tuple[str, dict]] = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if re.match(r"^\s*(#.*)?$", line):
            continue
        try:
            key, typ, default, desc = split_knobs_line(line)
        except ValueError as e:
            raise ConvertError(f"knobs:{n}: {e}") from None
        if default == "—":
            default = ""
        spec: dict = {}
        readonly = typ.startswith("ro:")
        if readonly:
            typ = typ[3:]
        optional = typ.endswith("?")
        if optional:
            typ = typ[:-1]
        secret = ""
        if typ == "secret":
            secret, typ = "file", "str"
        elif typ == "secret:hook":
            secret, typ = "hook", "str"
        elif typ.startswith("secret:"):
            secret, typ = "file", typ[len("secret:"):]
        pattern = key.endswith("_*")
        new = key
        if key.startswith("BISQUITE_"):
            new = key[len("BISQUITE_"):]
            notes.append(f"config.keys: {key} → {new} (Р8) — таблица переименований в README и PR")
        spec["type"] = typ
        if not pattern:
            spec["default"] = default
        if (optional or default == "") and not pattern:
            spec["empty"] = True
        if secret:
            spec["secret"] = "file"
        if readonly:
            spec["readonly"] = True
        if pattern:
            spec["pattern"] = True
        spec["description"] = desc or "TODO: описание"
        if secret == "hook":
            notes.append(f"config.keys: {new} — secret:hook → secret: file (Р4); производный файл строит "
                         "hooks/configure из CREAM_SECRETS_FILE, knobs.secret и производные readonly-ключи — убрать")
        elif secret == "file" and typ == "str":
            notes.append(f"config.keys: {new} — secret → secret: file, тип str (без `$` и обратных кавычек)")
        if typ.startswith("list:"):
            notes.append(f"config.keys: {new} — list: в cream через пробел, в bisquite-conf было через запятую")
        if readonly and not secret:
            notes.append(f"config.keys: {new} — readonly; кто пишет его теперь (хук, действие)?")
        keys.append((new, spec))
    return keys


# --- systemd units -----------------------------------------------------------

def parse_unit(path: Path) -> dict[str, list[str]]:
    """Directive -> list of space-separated values (repeats accumulate)."""
    out: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line[0] in "#;[" or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out.setdefault(k.strip(), []).extend(v.split())
    return out


def find_configure_unit(src: Path) -> Path | None:
    for p in sorted(src.iterdir()):
        if p.is_file() and p.name.endswith(".service"):
            u = parse_unit(p)
            if any("configure.sh" in v for v in u.get("ExecStart", [])):
                return p
    return None


def stage_from_unit(u: dict[str, list[str]]) -> str:
    wanted = set(u.get("WantedBy", []))
    after = set(u.get("After", []))
    if "sysinit.target" in wanted:
        return "early"
    if "cloud-init.target" in wanted or "cloud-final.service" in after:
        return "cloud-user"
    if "graphical.target" in wanted:
        return "graphical"
    return "system"


def timeout_from_unit(u: dict[str, list[str]]) -> str:
    vals = u.get("TimeoutStartSec", [])
    if not vals or not vals[-1].isdigit():
        return ""
    sec = int(vals[-1])
    return f"{sec // 60}m" if sec % 60 == 0 else f"{sec}s"


# --- helpers -------------------------------------------------------------------

def q(s: str) -> str:
    """A YAML double-quoted scalar (JSON strings are valid YAML)."""
    return json.dumps(s, ensure_ascii=False)


def flow(items: list[str]) -> str:
    return "[" + ", ".join(items) + "]"


def summary_from_readme(readme: Path) -> str:
    if not readme.is_file():
        return "TODO: однострочное описание"
    para: list[str] = []
    for line in readme.read_text(encoding="utf-8").splitlines()[1:]:
        s = line.strip()
        if not s:
            if para:
                break
            continue
        if s.startswith((">", "#", "-", "*", "|", "```")):
            if para:
                break
            continue
        para.append(s)
    text = " ".join(para)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text).replace("**", "")
    m = re.match(r"(.+?[.:])(\s|$)", text)
    if m:
        text = m.group(1).rstrip(".:")
    if len(text) > 120:
        text = text[:119].rsplit(" ", 1)[0] + "…"
    return text or "TODO: однострочное описание"


def major_bump(version: str) -> str:
    m = re.match(r"^(\d+)\.\d+\.\d+$", str(version))
    if not m:
        raise ConvertError(f"version: {version!r} — не X.Y.Z")
    return f"{int(m.group(1)) + 1}.0.0"


def as_list(v) -> list[str]:
    if v is None:
        return []
    return [str(x) for x in (v if isinstance(v, list) else [v])]


def grep_text(root: Path, skip: set[str]) -> dict[str, list[str]]:
    """Rule id -> ["file:line", …] over every text file of the tree."""
    hits: dict[str, list[str]] = {r[0]: [] for r in RULES}
    for p in sorted(x for x in root.rglob("*") if x.is_file()):
        rel = p.relative_to(root).as_posix()
        if rel in skip:
            continue
        try:
            lines = p.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            for rid, rx, _, hooks_only in RULES:
                if hooks_only and rel not in HOOK_FILES:
                    continue
                if rx.search(line):
                    hits[rid].append(f"{rel}:{n}")
    return hits


def compact(locs: list[str]) -> str:
    """["a:1", "a:5", "b:2"] -> "a:1,5; b:2"."""
    by: dict[str, list[str]] = {}
    for loc in locs:
        f, n = loc.rsplit(":", 1)
        by.setdefault(f, []).append(n)
    return "; ".join(f"{f}:{','.join(ns)}" for f, ns in by.items())


# --- conversion ------------------------------------------------------------------

HOOK_MAP = [("install.sh", "install"), ("update.sh", "upgrade"),
            ("configure.sh", "configure"), ("knobs.apply", "apply")]


def plan_tree(src: Path) -> tuple[str, list[str], dict]:
    """Return (manifest text, report lines, moves) for SRC (layout 2)."""
    mpath = src / "extension.yaml"
    if not mpath.is_file():
        raise ConvertError(f"{src}: нет extension.yaml")
    m = yaml.safe_load(mpath.read_text(encoding="utf-8")) or {}
    if m.get("layout") != 2:
        raise ConvertError(f"{src}: не layout 2 (layout: {m.get('layout')!r})")
    name = str(m["name"])
    if name != src.name:
        raise ConvertError(f"{src}: name {name!r} не равно имени каталога")
    old_version = str(m.get("version", "0.0.0"))
    version = major_bump(old_version)

    todo: list[str] = []
    layout: list[str] = []
    renames: dict[str, str] = {}
    drops: list[str] = []

    for old, hook in HOOK_MAP:
        if (src / old).is_file():
            renames[old] = f"hooks/{hook}"
            layout.append(f"{old} → hooks/{hook}")
    if "install.sh" not in renames:
        raise ConvertError(f"{src}: нет install.sh")
    if (src / "knobs").is_file():
        drops.append("knobs")
        layout.append("knobs → config.keys (файл удалён)")
    if (src / "knobs.secret").is_file():
        todo.append("knobs.secret оставлен как есть: логику — в hooks/configure из CREAM_SECRETS_FILE, файл удалить (Р4)")

    # live
    live, note = LIVE.get(name, ("", ""))
    if not live:
        live, note = "confirm", "TODO: риск живой установки"
        todo.append("targets.live: расширения нет в таблице плана — выбери yes|confirm|no")
    elif live == "yes":
        todo.append("targets.live: yes — по таблице плана")
    else:
        todo.append(f"targets.live: {live} — по таблице плана; live_note — черновик, проверь текст")

    # configure
    configure: dict | None = None
    unit = find_configure_unit(src)
    if "configure.sh" in renames:
        derived, after, before, wants, timeout = "system", [], [], [], ""
        unit_desc = "configure-юнита нет"
        if unit is not None:
            u = parse_unit(unit)
            derived = stage_from_unit(u)
            implied = IMPLIED | (IMPLIED_GRAPHICAL if derived == "graphical" else set())
            after = [x for x in u.get("After", []) if x not in implied]
            before = [x for x in u.get("Before", []) if x not in implied]
            wants = [x for x in u.get("Wants", []) if x not in implied]
            timeout = timeout_from_unit(u)
            dropped = sorted({x for k in ("After", "Before", "Wants") for x in u.get(k, []) if x in implied})
            unit_desc = (f"{unit.name}: WantedBy {' '.join(u.get('WantedBy', [])) or '—'}"
                         + (f", отброшено {' '.join(dropped)}" if dropped else "")
                         + (f", Requires {' '.join(u['Requires'])} — не переносится" if u.get("Requires") else ""))
            drops.append(unit.name)
            layout.append(f"{unit.name} — удалён: configure ставит cream (cream-configure@{name})")
        stage = derived
        if name in STAGE:
            pstage, pafter, pbefore = STAGE[name]
            if (pstage, pafter, pbefore) != (derived, after, before):
                todo.append(f"hooks.configure: юнит даёт {derived}"
                            f"{' after ' + flow(after) if after else ''}{' before ' + flow(before) if before else ''}"
                            f", по плану {pstage}{' after ' + flow(pafter) if pafter else ''}"
                            f"{' before ' + flow(pbefore) if pbefore else ''} — взято из плана")
            stage, after, before = pstage, pafter, pbefore
        else:
            todo.append(f"hooks.configure: стадии нет в таблице плана — взята из юнита ({derived}), проверь")
        todo.append(f"hooks.configure: {unit_desc}")
        configure = {"stage": stage, "after": after, "before": before, "wants": wants, "timeout": timeout}
    elif unit is not None:
        todo.append(f"{unit.name}: зовёт configure.sh, а его нет — разберись руками")

    stage = configure["stage"] if configure else ""
    need = STAGE_CREAM.get(stage, "1.0.0")
    cream = f">={need}"
    if stage in STAGE_CREAM:
        todo.append(f"cream: \"{cream}\" — стадия {stage}: нужен cream {cream} (cream старше откажет)")

    # other systemd units -> files
    files: list[tuple[str, str]] = []
    for p in sorted(src.iterdir()):
        if p.is_file() and p.name.endswith(UNIT_SUFFIXES) and p.name not in drops:
            files.append((p.name, f"/etc/systemd/system/{p.name}"))
    if files:
        todo.append("files: юниты " + ", ".join(f for f, _ in files)
                    + " раскладывает cream — убрать их `install -m`/`ln -s` из hooks/install")

    # knobs
    keys: list[tuple[str, dict]] = []
    if (src / "knobs").is_file():
        keys = convert_knobs(src / "knobs", todo)
        hook_text = (src / "install.sh").read_text(encoding="utf-8")
        dm = re.search(r"^\s*conf_init\s+([a-z0-9][a-z0-9._-]*)\s", hook_text, re.M)
        if dm and dm.group(1) != name:
            todo.append(f"домен настроек {dm.group(1)} → {name}: /etc/bisquite/{dm.group(1)} → /etc/cream/{name}")

    # depends from the shared code the scripts use (README mentions do not count)
    text = "\n".join(p.read_text(encoding="utf-8", errors="replace")
                     for p in sorted(src.rglob("*")) if p.is_file() and p.suffix != ".md")
    depends = []
    for lib, rx in (("cloud-user", r"lib/get_cloud_user\.sh"), ("l4t", r"lib/l4t\b"),
                    ("desktop", r"bisquite-desktop")):
        if re.search(rx, text):
            depends.append(lib)
    if depends:
        todo.append(f"depends: {', '.join(depends)} — по общему коду; укажи диапазон версий")

    conflicts = as_list(m.get("conflicts"))
    if conflicts:
        todo.append("conflicts.extensions: перенесены по именам; взаимоисключение по способности — "
                    "conflicts.capabilities")

    todo.append("hooks.install: явный timeout рекомендован (§6.1)")
    if live == "yes":
        todo.append("hooks.remove: обязателен при targets.live: yes (Р9)")
    else:
        todo.append("hooks.remove: по возможности, иначе README описывает `cream remove --forget` (Р9)")
    todo.append("коды выхода: перезагрузка — 10; «нет устройства/ядра/GPU» — 20 только в install (Р11)")
    todo.append("summary — из README, проверь; platform.os и platform.commands — по образцу teleport")

    # manifest text
    out = [
        f"# Черновик tools/convert-v1.py из layout 2 ({name} {old_version}): отчёт конвертера — что",
        "# проверить руками (план 2026-10-19-cream-v1-migration, «Порядок перевода одного расширения»).",
        "schema: cream/v1",
        f"name: {name}",
        f"version: {version}",
        f"summary: {q(summary_from_readme(src / 'README.md'))}",
        f"cream: {q(cream)}",
        "platform:",
        "  family: deb",
        f"  arch: {flow(as_list(m.get('arch')))}",
        "targets:",
        "  build: exec",
        f"  live: {q(live)}",
    ]
    if note:
        out.append(f"  live_note: {q(note)}")
    if as_list(m.get("provides")):
        out.append(f"provides: {flow(as_list(m.get('provides')))}")
    if as_list(m.get("requires")):
        out.append(f"requires: {flow(as_list(m.get('requires')))}")
    if depends:
        out.append("depends:")
        out.extend(f"  - {{name: {d}}}" for d in depends)
    if conflicts:
        out.append(f"conflicts: {{extensions: {flow(conflicts)}}}")
    out.append("hooks:")
    for _, hook in HOOK_MAP:
        if f"hooks/{hook}" not in renames.values():
            continue
        if hook == "configure" and configure:
            parts = [f"stage: {configure['stage']}"]
            for k in ("after", "before", "wants"):
                if configure[k]:
                    parts.append(f"{k}: {flow(configure[k])}")
            if configure["timeout"]:
                parts.append(f"timeout: {configure['timeout']}")
            out.append(f"  configure: {{{', '.join(parts)}}}")
        else:
            out.append(f"  {hook}: {{}}")
    if keys:
        out.append("config:")
        out.append("  keys:")
        for k, spec in keys:
            out.append(f"    {k}:")
            for f, v in spec.items():
                out.append(f"      {f}: {'true' if v is True else q(v)}")
    if files:
        out.append("files:")
        out.extend(f"  - {{src: {s}, dst: {d}, mode: \"0644\"}}" for s, d in files)
    manifest = "\n".join(out) + "\n"

    report = [f"convert-v1: {name} {old_version} → {version} (черновик cream/v1)", "раскладка:"]
    report += [f"  {x}" for x in layout]
    report.append("проверить руками:")
    report += [f"  - {x}" for x in todo]
    moves = {"renames": renames, "drops": drops}
    return manifest, report, moves


def scan_report(tree: Path) -> list[str]:
    hits = grep_text(tree, {"extension.yaml"})
    lines = ["имена и механика layout 2 в файлах (менять руками; гейт tools/check-names.sh):"]
    any_hit = False
    for rid, _, advice, _ in RULES:
        if hits[rid]:
            any_hit = True
            lines.append(f"  - {advice}: {compact(hits[rid])}")
    if not any_hit:
        lines.append("  (ничего)")
    return lines


def write_tree(src: Path, dst: Path, manifest: str, moves: dict) -> None:
    renames, drops = moves["renames"], set(moves["drops"])
    for p in sorted(src.rglob("*")):
        rel = p.relative_to(src).as_posix()
        if p.is_dir() or rel in drops or rel == "extension.yaml":
            continue
        target = dst / renames.get(rel, rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
        if rel in renames:
            target.chmod(target.stat().st_mode | 0o111)
    (dst / "extension.yaml").write_text(manifest, encoding="utf-8")


def convert_in_place(src: Path, manifest: str, moves: dict) -> None:
    (src / "hooks").mkdir(exist_ok=True)
    for old, new in moves["renames"].items():
        os.rename(src / old, src / new)
        (src / new).chmod((src / new).stat().st_mode | 0o111)
    for d in moves["drops"]:
        (src / d).unlink()
    (src / "extension.yaml").write_text(manifest, encoding="utf-8")


def is_cream_v1(src: Path) -> bool:
    p = src / "extension.yaml"
    if not p.is_file():
        return False
    try:
        return (yaml.safe_load(p.read_text(encoding="utf-8")) or {}).get("schema") == "cream/v1"
    except yaml.YAMLError:
        return False


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="convert-v1.py", description="черновик cream/v1 из layout 2")
    ap.add_argument("src", type=Path, help="каталог расширения layout 2")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--out", type=Path, help="новый каталог с переведённым деревом")
    g.add_argument("--in-place", action="store_true", help="перевести сам SRC")
    ap.add_argument("--report", type=Path, help="отчёт в файл (умолчание — stderr)")
    args = ap.parse_args(argv)

    src = args.src.resolve()
    if is_cream_v1(src):
        print(f"convert-v1: {src.name} — уже cream/v1, ничего не меняю", file=sys.stderr)
        return 0
    try:
        manifest, report, moves = plan_tree(src)
        if args.out:
            if args.out.exists() and any(args.out.iterdir()):
                raise ConvertError(f"{args.out}: каталог не пуст")
            args.out.mkdir(parents=True, exist_ok=True)
            write_tree(src, args.out, manifest, moves)
            report += scan_report(args.out)
        elif args.in_place:
            convert_in_place(src, manifest, moves)
            report += scan_report(src)
        else:
            sys.stdout.write(manifest)
    except ConvertError as e:
        print(f"convert-v1: {e}", file=sys.stderr)
        return 1
    text = "\n".join(report) + "\n"
    if args.report:
        args.report.write_text(text, encoding="utf-8")
    else:
        sys.stderr.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
