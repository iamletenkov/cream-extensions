#!/usr/bin/env bash
# Links of the documentation: every relative link of every Markdown file the
# repository tracks (or would track — .gitignore is honoured) points to an
# existing file, and its #anchor to a heading of that file (GitHub slugs,
# duplicates numbered -1, -2, …). Links inside code (fenced blocks, `inline`)
# are not links and are skipped.
#
#   tools/check-links.sh               relative links and anchors, offline (tools/check.sh)
#   tools/check-links.sh --external    also every http(s) URL: HEAD/GET must answer 2xx/3xx
#   tools/check-links.sh --repo DIR    another checkout (tests)
#
# Exit: 0 — no broken links; 1 — broken links (file:line: link — reason);
# 2 — usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
external=0
while (( $# )); do
    case "$1" in
        --external) external=1; shift ;;
        --repo) REPO="$(cd "${2:?--repo требует каталог}" && pwd)"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "check-links: неизвестный аргумент $1" >&2; exit 2 ;;
    esac
done
# Inside a git hook GIT_DIR points to the hook's repository, not to REPO.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

PY="$(cat <<'PYEOF'
import pathlib, re, subprocess, sys, urllib.request

repo = pathlib.Path(sys.argv[1]); external = sys.argv[2] == "1"
files = subprocess.run(
    ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
    check=True, capture_output=True).stdout.decode().split("\0")
files = sorted({f for f in files if f and (repo / f).is_file()})

FENCE = re.compile(r"^\s*(```|~~~)")
LINK = re.compile(r"(?<!!)\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
IMG = re.compile(r"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?\s*\)")
HREF = re.compile(r"""<a\s[^>]*href=["']([^"']+)["']""")

def strip_code(line):
    return re.sub(r"`[^`]*`", "", line)

def slug(text):
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text).strip().lower()
    out = "".join(ch for ch in text if ch.isalnum() or ch in " -_")
    return out.replace(" ", "-")

anchor_cache = {}
def anchors(path):
    if path not in anchor_cache:
        seen, result, fence = {}, set(), False
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if FENCE.match(line):
                fence = not fence
                continue
            if fence:
                continue
            m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
            if m:
                s = slug(m.group(2))
                n = seen.get(s, 0)
                result.add(s if n == 0 else f"{s}-{n}")
                seen[s] = n + 1
            for a in re.findall(r"""<a\s+(?:name|id)=["']([^"']+)["']""", line):
                result.add(a)
        anchor_cache[path] = result
    return anchor_cache[path]

bad, urls = [], {}
for rel in files:
    path = repo / rel
    fence = False
    for no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if FENCE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        text = strip_code(line)
        for target in LINK.findall(text) + IMG.findall(text) + HREF.findall(text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                if target.startswith(("http://", "https://")):
                    urls.setdefault(target, f"{rel}:{no}")
                continue
            ref, _, frag = target.partition("#")
            dest = path if not ref else (path.parent / ref).resolve()
            try:
                dest.relative_to(repo.resolve())
            except ValueError:
                bad.append(f"{rel}:{no}: {target} — ведёт за пределы репозитория")
                continue
            if not dest.exists():
                bad.append(f"{rel}:{no}: {target} — нет файла")
                continue
            if frag and dest.is_file() and dest.suffix == ".md" and frag not in anchors(dest):
                bad.append(f"{rel}:{no}: {target} — нет заголовка #{frag}")

if external:
    for url, where in sorted(urls.items()):
        base = url.split("#", 1)[0]
        ok = False
        for method in ("HEAD", "GET"):
            try:
                req = urllib.request.Request(base, method=method, headers={"User-Agent": "check-links"})
                with urllib.request.urlopen(req, timeout=20) as r:
                    ok = r.status < 400
            except Exception:
                ok = False
            if ok:
                break
        if not ok:
            bad.append(f"{where}: {url} — не отвечает")

for b in bad:
    print(b)
if bad:
    print(f"check-links: битых ссылок — {len(bad)}", file=sys.stderr)
    sys.exit(1)
print(f"check-links: ок, файлов: {len(files)}" + (f", внешних адресов: {len(urls)}" if external else ""))
PYEOF
)"
rc=0
python3 -c "$PY" "$REPO" "$external" || rc=$?
exit "$rc"
