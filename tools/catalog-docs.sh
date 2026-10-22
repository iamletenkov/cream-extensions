#!/usr/bin/env bash
# Generated parts of the catalog documentation, from the manifests.
#
# The manifests are the only source of these facts; the documents carry them
# between markers, and nobody edits the text between markers by hand:
#
#   README.md                     <!-- catalog:table -->   … <!-- /catalog:table -->
#                                 the table of extensions and of libraries
#   docs/reference/catalog.md     <!-- catalog:reference --> … <!-- /catalog:reference -->
#                                 relations: capabilities, depends, conflicts,
#                                 configure stage, live target
#   extensions/<f>/<name>/README.md
#                                 <!-- catalog:facts -->  … <!-- /catalog:facts -->
#                                 <!-- catalog:params --> … <!-- /catalog:params -->
#                                 platform, cream, relations; the keys table
#
# Versions are left out on purpose: tools/agent-bump.sh raises the version of
# stvor-agent by itself, and a generated version would go stale in its PR.
#
#   tools/catalog-docs.sh           rewrite the blocks in place
#   tools/catalog-docs.sh --check   exit 1 and show the difference when a block
#                                   is stale or a marker is missing (tools/check.sh)
#   tools/catalog-docs.sh [--check] --repo DIR   another checkout (tests)
#
# Exit: 0 — up to date (or rewritten); 1 — stale (--check); 2 — a marker is
# missing or broken, a manifest does not read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
mode="write"
while (( $# )); do
    case "$1" in
        --check) mode=check; shift ;;
        --repo) REPO="$(cd "${2:?--repo требует каталог}" && pwd)"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "catalog-docs: неизвестный аргумент $1" >&2; exit 2 ;;
    esac
done

PY="$(cat <<'PYEOF'
import difflib, os, pathlib, re, sys, yaml

repo = pathlib.Path(sys.argv[1]); mode = sys.argv[2]
cat = yaml.safe_load((repo / "cream-catalog.yaml").read_text(encoding="utf-8")) or {}
roots = cat.get("roots") or []

exts = []
for root in roots:
    for mf in sorted((repo / root).glob("*/extension.yaml")):
        try:
            m = yaml.safe_load(mf.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as e:
            print(f"catalog-docs: {mf.relative_to(repo)}: не читается: {e}", file=sys.stderr)
            sys.exit(2)
        if not isinstance(m, dict) or not m.get("name"):
            print(f"catalog-docs: {mf.relative_to(repo)}: нет name", file=sys.stderr)
            sys.exit(2)
        m["_dir"] = mf.parent
        exts.append(m)
exts.sort(key=lambda m: m["name"])
by_name = {m["name"]: m for m in exts}

def fail(msg):
    print("catalog-docs: " + msg, file=sys.stderr)
    sys.exit(2)

def code(s):
    return "`" + str(s) + "`"

def cell(s):
    return " ".join(str(s).split()).replace("|", "\\|")

def osname(e):
    ids = {"debian": "Debian", "ubuntu": "Ubuntu", "openwrt": "OpenWrt"}
    name = ids.get(e.get("id"), str(e.get("id")))
    v = str(e.get("version") or "").strip()
    if not v:
        return name
    v = re.sub(r">=\s*", "≥ ", v)
    v = re.sub(r"<\s*", "< ", v)
    return f"{name} {v}"

def oses(m):
    lst = (m.get("platform") or {}).get("os")
    if not lst:
        return "OpenWrt" if (m.get("platform") or {}).get("family") == "openwrt" else "Debian, Ubuntu"
    return ", ".join(osname(e) for e in lst)

def arches(m):
    return ", ".join((m.get("platform") or {}).get("arch") or ["любая"])

def cream_min(m):
    c = str(m.get("cream") or "").strip()
    return re.sub(r">=\s*", "≥ ", c) or "—"

def live(m):
    t = (m.get("targets") or {}).get("live")
    return {"yes": "да", "confirm": "с `--accept-risk`", "no": "нет, только образ"}.get(str(t), str(t))

def ext_link(name, frm):
    """Relative link to the README of extension name from directory frm."""
    target = by_name.get(name)
    if target is None:
        return code(name)
    rel = os.path.relpath(target["_dir"] / "README.md", frm)
    return f"[{code(name)}]({rel})"

def names(lst, frm=None):
    out = []
    for x in lst or []:
        n = x["name"] if isinstance(x, dict) else x
        out.append(ext_link(n, frm) if frm is not None else code(n))
    return ", ".join(out) or "—"

def conflicts(m, frm=None):
    c = m.get("conflicts") or {}
    parts = [ext_link(n, frm) if frm is not None else code(n) for n in c.get("extensions") or []]
    parts += [f"способность {code(n)}" for n in c.get("capabilities") or []]
    return ", ".join(parts) or "—"

def configure(m):
    c = (m.get("hooks") or {}).get("configure")
    if c is None:
        return "—"
    when = "на каждой загрузке (`every_boot`)" if c.get("every_boot") else "по отметке выполнения"
    return f"стадия {code(c.get('stage', 'system'))}, {when}"

def keys(m):
    return ((m.get("config") or {}).get("keys")) or {}

def key_list(m, limit=3):
    ks = list(keys(m))
    if not ks:
        return "—"
    shown = ", ".join(code(k) for k in ks[:limit])
    if len(ks) > limit:
        shown += f" и ещё {len(ks) - limit}"
    return shown

def typ(t):
    t = str(t)
    if t.startswith("enum:"):
        return " \\| ".join(code(x) for x in t[5:].split(","))
    if t.startswith("re:"):
        return "строка " + code(t[3:].replace("|", "\\|"))
    if t.startswith("list:re:"):
        return "список через пробел, элемент " + code(t[8:].replace("|", "\\|"))
    return code(t.replace("|", "\\|"))

def default(v):
    if "default" not in v:
        return "—"
    d = str(v["default"])
    return "пусто" if d == "" else code(d)

def notes(v):
    out = []
    if v.get("secret"):
        out.append("секрет: `KEY=-` со stdin или `--params-file`, не в argv")
    if v.get("scope") == "install":
        out.append("только при установке")
    if v.get("readonly"):
        out.append("только чтение")
    if v.get("pattern"):
        out.append("шаблон имени")
    return out

def params_block(m):
    ks = keys(m)
    if not ks:
        return ["Параметров нет."]
    rows = ["| Ключ | Тип | Умолчание | Что задаёт |", "|---|---|---|---|"]
    for k, v in ks.items():
        desc = cell(v.get("description", ""))
        extra = notes(v)
        if extra:
            desc += " *(" + "; ".join(extra) + ")*"
        rows.append(f"| {code(k)} | {typ(v.get('type', 'str'))} | {default(v)} | {desc} |")
    return rows

def facts_block(m):
    frm = m["_dir"]
    rows = ["| | |", "|---|---|",
            f"| ОС | {oses(m)} |",
            f"| Архитектура | {arches(m)} |",
            f"| cream | {cream_min(m)} |"]
    if m.get("kind") == "library":
        rows.append("| Вид | библиотека (`kind: library`): общий код других расширений, без хуков |")
    rows += [f"| Даёт | {names(m.get('provides'))} |",
             f"| Требует | {names(m.get('requires'))} |",
             f"| Зависит от | {names(m.get('depends'), frm)} |",
             f"| Конфликтует с | {conflicts(m, frm)} |"]
    hooks = list((m.get("hooks") or {}))
    if hooks:
        rows.append(f"| Хуки | {', '.join(code(h) for h in hooks)} |")
        rows.append(f"| Настройка на загрузке | {configure(m)} |")
    acts = list((m.get("actions") or {}))
    if acts:
        rows.append(f"| Действия | {', '.join(code('cream run ' + m['name'] + ' ' + a) for a in acts)} |")
    rows.append(f"| Живая машина | {live(m)} |")
    note = (m.get("targets") or {}).get("live_note")
    if note:
        what = "Только образ" if (m.get("targets") or {}).get("live") == "no" else "Живая машина — с `--accept-risk`"
        text = cell(note)
        rows += ["", f"> **{what}.** {text[:1].upper() + text[1:]}"]
    return rows

def table_block():
    frm = repo
    full = [m for m in exts if m.get("kind") != "library"]
    libs = [m for m in exts if m.get("kind") == "library"]
    rows = [f"Расширений — {len(full)}, библиотек — {len(libs)}.", "",
            "| Расширение | Что делает | ОС | Архитектура | Параметры |", "|---|---|---|---|---|"]
    for m in full:
        rows.append(f"| {ext_link(m['name'], frm)} | {cell(m.get('summary', ''))} | {oses(m)} | {arches(m)} | {key_list(m)} |")
    rows += ["", "Библиотеки — общий код, который другие расширения объявляют в `depends`; сами по себе их не ставят:", "",
             "| Библиотека | Что даёт | ОС | Архитектура |", "|---|---|---|---|"]
    for m in libs:
        rows.append(f"| {ext_link(m['name'], frm)} | {cell(m.get('summary', ''))} | {oses(m)} | {arches(m)} |")
    return rows

def reference_block():
    frm = repo / "docs" / "reference"
    rows = ["| Расширение | cream | Даёт | Требует | Зависит от | Конфликтует с | Настройка на загрузке | Живая машина |",
            "|---|---|---|---|---|---|---|---|"]
    for m in exts:
        rows.append(f"| {ext_link(m['name'], frm)} | {cream_min(m)} | {names(m.get('provides'))} | {names(m.get('requires'))} | "
                    f"{names(m.get('depends'), frm)} | {conflicts(m, frm)} | {configure(m)} | {live(m)} |")
    caps = {}
    for m in exts:
        for c in m.get("provides") or []:
            caps.setdefault(c, [[], []])[0].append(m["name"])
        for c in m.get("requires") or []:
            caps.setdefault(c, [[], []])[1].append(m["name"])
    rows += ["", "### Способности: кто даёт и кто требует", "",
             "| Способность | Дают | Требуют |", "|---|---|---|"]
    for c in sorted(caps):
        give, need = caps[c]
        rows.append(f"| {code(c)} | {', '.join(ext_link(n, frm) for n in give) or '— (нет поставщика)'} | "
                    f"{', '.join(ext_link(n, frm) for n in need) or '—'} |")
    return rows

jobs = [(repo / "README.md", [("table", table_block())]),
        (repo / "docs" / "reference" / "catalog.md", [("reference", reference_block())])]
for m in exts:
    jobs.append((m["_dir"] / "README.md", [("facts", facts_block(m)), ("params", params_block(m))]))

stale = 0
for path, blocks in jobs:
    if not path.exists():
        fail(f"{path.relative_to(repo)}: нет файла")
    old = path.read_text(encoding="utf-8")
    new = old
    for tag, body in blocks:
        begin, end = f"<!-- catalog:{tag} -->", f"<!-- /catalog:{tag} -->"
        if new.count(begin) != 1 or new.count(end) != 1 or new.index(begin) > new.index(end):
            fail(f"{path.relative_to(repo)}: нет пары маркеров {begin} … {end} (ровно по одному, в этом порядке)")
        head, rest = new.split(begin, 1)
        _, tail = rest.split(end, 1)
        new = head + begin + "\n" + "\n".join(body) + "\n" + end + tail
    if new == old:
        continue
    if mode == "check":
        stale += 1
        rel = str(path.relative_to(repo))
        sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True), rel, rel + " (из манифестов)", n=1))
    else:
        path.write_text(new, encoding="utf-8")
        print(f"обновлён {path.relative_to(repo)}")

if stale:
    print(f"\ncatalog-docs: устарело файлов — {stale}; обнови: tools/catalog-docs.sh", file=sys.stderr)
    sys.exit(1)
if mode == "check":
    print(f"catalog-docs: сгенерированные блоки актуальны (расширений {len(exts)})")
PYEOF
)"
rc=0
python3 -c "$PY" "$REPO" "$mode" || rc=$?
if (( rc == 1 )); then exit 1; fi
if (( rc != 0 )); then exit 2; fi
