# shellcheck shell=bash
# Корень по PARTUUID во всех записях extlinux.conf.
#
# Подключается из hooks/install (`. "$EXT_DIR/extlinux-root.sh"`, дерево
# расширения — /opt/cream/ext/l4t-kernel-kvm) и из тестов tests/. Опций
# оболочки файл не ставит и ничего не выполняет при подключении — только
# объявляет функции.
#
# ЗАЧЕМ. У базы Q-engineering в APPEND стоит `root=/dev/mmcblk0p1`, то есть
# корень назван ИМЕНЕМ устройства. Образ, записанный на USB-SSD, с таким
# корнем не грузится: там раздел называется /dev/sda1. PARTUUID приходит
# из таблицы разделов образа, переживает `dd` и одинаков на любом носителе.
#
# Функции, все отказы — на stderr с ненулевым кодом:
#   kvm_root_partition                     печатает `DEV NUM PARTUUID` раздела,
#                                          на котором физически лежит /;
#   kvm_check_extlinux_roots FILE P NUM    проверка всех APPEND без записи
#                                          (шаг 1в, до сборки ядра);
#   kvm_backup_once FILE                   FILE.cream-orig — один раз (шаг 7);
#   kvm_rewrite_root FILE P                переписывание (шаг 7, после бэкапа);
#   kvm_write_entry FILE LOCALVERSION FDT  запись kvm и DEFAULT kvm (шаг 7).
#
# ЗАПИСЬ extlinux.conf — только через временный файл рядом и rename, с прежним
# режимом и владельцем; FILE-ссылка — отказ (открытие с O_NOFOLLOW): через
# ссылку не пишем. Содержимое файла — данные: разбирается Python, не оболочкой.

# Раздел корня: st_dev от / -> блочный узел в /dev с тем же st_rdev -> blkid.
#
# Не findmnt и не разбор /proc/self/mountinfo: в chroot virt-customize
# mountinfo показывает пути относительно корня процесса, а stat даёт ответ
# ядра без разбора текста. `blkid -p` читает таблицу разделов напрямую, мимо
# кеша blkid.tab, который в образе может остаться от чужой машины.
kvm_root_partition() {
    local dev info num partuuid blkid
    # blkid живёт в /sbin, а PATH процесса сборки его может не содержать.
    blkid="$(PATH="$PATH:/usr/sbin:/sbin" command -v blkid)" || {
        echo "l4t-kernel-kvm: нет blkid — раздел корня определить нечем" >&2
        return 1
    }
    dev="$(python3 - <<'PYEOF'
import os, stat, sys

want = os.stat("/").st_dev
found = []
for top, dirs, files in os.walk("/dev"):
    for name in files:
        path = os.path.join(top, name)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if stat.S_ISBLK(st.st_mode) and st.st_rdev == want:
            found.append(path)
if not found:
    sys.stderr.write(
        "l4t-kernel-kvm: в /dev нет блочного узла с номером %d:%d — "
        "устройства корня (/)\n" % (os.major(want), os.minor(want)))
    sys.exit(1)
# Самый короткий путь: /dev/sda1, а не /dev/block/…
found.sort(key=lambda p: (p.count("/"), p))
print(found[0])
PYEOF
)" || return 1
    if ! info="$("$blkid" -p -o export "$dev")"; then
        echo "l4t-kernel-kvm: blkid -p не прочёл $dev (устройство корня)" >&2
        return 1
    fi
    partuuid="$(sed -n 's/^PART_ENTRY_UUID=//p' <<<"$info")"
    num="$(sed -n 's/^PART_ENTRY_NUMBER=//p' <<<"$info")"
    if [[ ! "$num" =~ ^[1-9][0-9]*$ ]]; then
        echo "l4t-kernel-kvm: у $dev нет номера раздела (PART_ENTRY_NUMBER='$num')" >&2
        echo "l4t-kernel-kvm: корень лежит не в разделе — PARTUUID взять неоткуда" >&2
        return 1
    fi
    if ! _kvm_partuuid_ok "$partuuid"; then
        echo "l4t-kernel-kvm: у $dev PARTUUID '$partuuid' не GPT-формы" >&2
        return 1
    fi
    printf '%s %s %s\n' "$dev" "$num" "$partuuid"
}

# GPT-форма, строчными: так печатает blkid, и так же сверяется запись в файле.
_kvm_partuuid_ok() {
    [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

kvm_check_extlinux_roots() {
    if (( $# != 3 )); then
        echo "l4t-kernel-kvm: kvm_check_extlinux_roots ФАЙЛ PARTUUID НОМЕР" >&2
        return 2
    fi
    _kvm_extlinux_root check "$@"
}

kvm_rewrite_root() {
    if (( $# != 2 )); then
        echo "l4t-kernel-kvm: kvm_rewrite_root ФАЙЛ PARTUUID" >&2
        return 2
    fi
    _kvm_extlinux_root rewrite "$@" ""
}

# Один разбор на оба режима — иначе проверка шага 1в и запись шага 7
# отвечали бы на разные вопросы, и отказ мог бы переехать на третий час.
_kvm_extlinux_root() {
    local mode="$1" file="$2" partuuid="$3" num="$4"
    if ! _kvm_partuuid_ok "$partuuid"; then
        echo "l4t-kernel-kvm: PARTUUID '$partuuid' не GPT-формы (8-4-4-4-12, строчные)" >&2
        return 1
    fi
    if [[ -n "$num" && ! "$num" =~ ^[1-9][0-9]*$ ]]; then
        echo "l4t-kernel-kvm: номер раздела '$num' — не число" >&2
        return 1
    fi
    if [[ -L "$file" ]]; then
        echo "l4t-kernel-kvm: $file — символическая ссылка; через ссылку не пишем" >&2
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "l4t-kernel-kvm: нет $file" >&2
        return 1
    fi
    python3 - "$mode" "$file" "$partuuid" "$num" <<'PYEOF'
import os, re, sys, tempfile

mode, path, partuuid, num = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# surrogateescape: байт, не разобранный как UTF-8, возвращается как был.
ENC = {"encoding": "utf-8", "errors": "surrogateescape"}
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as e:
    sys.stderr.write(f"l4t-kernel-kvm: {path}: не открыть ({e.strerror}); через ссылку не пишем\n")
    sys.exit(1)
with os.fdopen(fd, "r", **ENC) as f:
    st = os.fstat(f.fileno())
    lines = f.read().splitlines(keepends=True)
want = "root=PARTUUID=" + partuuid
# Номер раздела в имени устройства: /dev/<диск>p<N> (mmcblk0p1, nvme0n1p1)
# и /dev/sd<x><N>, /dev/vd<x><N>. Иные пути сверять не с чем.
DEV_NUM = re.compile(r"^/dev/(?:[a-z0-9]*[0-9]p|(?:sd|vd)[a-z]+)([0-9]+)$")

errors, changes, seen, label = [], [], 0, "(до первой записи)"
out = []
for lineno, line in enumerate(lines, 1):
    body = line.rstrip("\r\n")
    stripped = body.strip()
    # Ровно `LABEL x`: `MENU LABEL …` начинается с MENU и сюда не попадает.
    if stripped.startswith("LABEL "):
        label = stripped[len("LABEL "):].strip()
    tokens = list(re.finditer(r"\S+", body))
    if not tokens or tokens[0].group() != "APPEND":
        out.append(line)
        continue
    seen += 1
    where = f"{path}:{lineno} (запись {label})"
    roots = [t for t in tokens[1:] if t.group().startswith("root=")]
    if not roots:
        errors.append(f"{where}: в APPEND нет root=")
        out.append(line)
        continue
    if len(roots) > 1:
        errors.append(f"{where}: в APPEND {len(roots)} токена root= — какой из них корень, не решить")
        out.append(line)
        continue
    tok = roots[0]
    value = tok.group()[len("root="):]
    if value.startswith("PARTUUID="):
        if value[len("PARTUUID="):].lower() == partuuid:
            out.append(line)
            continue
        errors.append(f"{where}: {tok.group()} — чужой носитель, корень здесь PARTUUID={partuuid}")
        out.append(line)
        continue
    if not (value.startswith("/dev/") and len(value) > len("/dev/")):
        errors.append(f"{where}: {tok.group()} — такая форма корня не разбиралась, "
                      "переписывается только root=/dev/… и root=PARTUUID=")
        out.append(line)
        continue
    m = DEV_NUM.match(value)
    if num and m and m.group(1) != num:
        errors.append(f"{where}: {tok.group()} — раздел {m.group(1)}, а корень лежит "
                      f"в разделе {num}: запись вендора указывает не туда")
        out.append(line)
        continue
    changes.append(f"запись {label}: {tok.group()} -> {want}")
    out.append(body[:tok.start()] + want + body[tok.end():] + line[len(body):])

if seen == 0:
    errors.append(f"{path}: нет ни одной строки APPEND")
if errors:
    for e in errors:
        sys.stderr.write(f"l4t-kernel-kvm: {e}\n")
    sys.stderr.write("l4t-kernel-kvm: файл не изменён\n")
    sys.exit(1)
if mode == "rewrite":
    if changes:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".extlinux.conf.")
        try:
            with os.fdopen(fd, "w", **ENC) as f:
                f.write("".join(out))
            os.chmod(tmp, st.st_mode & 0o7777)
            try:
                os.chown(tmp, st.st_uid, st.st_gid)
            except PermissionError:
                pass
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
        for c in changes:
            sys.stderr.write(f"l4t-kernel-kvm: root= переписан, {c}\n")
    else:
        sys.stderr.write(f"l4t-kernel-kvm: root= уже {want} во всех записях\n")
else:
    for c in changes:
        sys.stderr.write(f"l4t-kernel-kvm: будет переписано, {c}\n")
    if not changes:
        sys.stderr.write(f"l4t-kernel-kvm: root= уже {want} во всех записях\n")
PYEOF
}

# FILE.cream-orig — копия FILE до первой правки cream, ОДИН РАЗ (спека cream
# §6.3: резервные копии не перезаписываются). Та же копия, что ведёт
# l4t-board-fdt: в ней всегда файл до cream, сколько бы слоёв его ни правили.
# Прежняя `.before-kvm` снималась каждым прогоном, и после второго «откат»
# возвращал уже изменённый файл. Копия ставится link(2) готового временного
# файла: имя занято (в том числе ссылкой) — не трогаем.
kvm_backup_once() {
    if (( $# != 1 )); then
        echo "l4t-kernel-kvm: kvm_backup_once ФАЙЛ" >&2
        return 2
    fi
    if [[ -L "$1" || ! -f "$1" ]]; then
        echo "l4t-kernel-kvm: $1 — нет файла или символическая ссылка; копию не снимаю" >&2
        return 1
    fi
    python3 - "$1" <<'PYEOF'
import os, shutil, sys, tempfile

path = sys.argv[1]
backup = path + ".cream-orig"
if os.path.lexists(backup):
    sys.stderr.write(f"l4t-kernel-kvm: копия {backup} уже есть — не перезаписываю\n")
    sys.exit(0)
src = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
st = os.fstat(src)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".extlinux.conf.")
try:
    with os.fdopen(src, "rb") as fi, os.fdopen(fd, "wb") as fo:
        shutil.copyfileobj(fi, fo)
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    try:
        os.link(tmp, backup)
        sys.stderr.write(f"l4t-kernel-kvm: исходный файл сохранён как {backup}\n")
    except FileExistsError:
        pass
finally:
    os.unlink(tmp)
PYEOF
}

# Запись `kvm`: прежняя снимается, DEFAULT переключается на kvm, новая
# дописывается в конец. APPEND копируется из первой записи вендора — ПОСЛЕ
# kvm_rewrite_root, то есть уже с root=PARTUUID. FDT — пусто или путь в /boot.
#
# ЗАПИСЬ КОНЧАЕТСЯ СЛЕДУЮЩИМ `LABEL `, А НЕ ПУСТОЙ СТРОКОЙ: пустая строка
# внутри записи законна, а наша запись последняя в файле и пустой строкой
# не кончается вовсе (прежний `sed '/^LABEL kvm$/,/^$/d'` уносил чужую запись
# за нашей). Начало — ровным сравнением: `MENU LABEL kvm kernel` содержит
# `LABEL kvm`. DEFAULT меняется, прежние записи остаются в меню запасными:
# незагружаемое ядро на плате без монитора чинится только консолью.
# Повтор с теми же входами — файл байт в байт тот же (запись не делается).
kvm_write_entry() {
    if (( $# != 3 )); then
        echo "l4t-kernel-kvm: kvm_write_entry ФАЙЛ LOCALVERSION FDT" >&2
        return 2
    fi
    if [[ -L "$1" ]]; then
        echo "l4t-kernel-kvm: $1 — символическая ссылка; через ссылку не пишем" >&2
        return 1
    fi
    python3 - "$@" <<'PYEOF'
import os, sys, tempfile

path, localversion, fdt = sys.argv[1], sys.argv[2], sys.argv[3]
ENC = {"encoding": "utf-8", "errors": "surrogateescape"}
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as e:
    sys.stderr.write(f"l4t-kernel-kvm: {path}: не открыть ({e.strerror})\n")
    sys.exit(1)
with os.fdopen(fd, "r", **ENC) as f:
    st = os.fstat(f.fileno())
    text = f.read()

out, in_kvm = [], False
for line in text.splitlines():
    stripped = line.strip()
    if stripped == "LABEL kvm":
        in_kvm = True
        continue
    if in_kvm:
        if stripped.startswith("LABEL "):
            in_kvm = False
        else:
            continue
    out.append(line)
while out and not out[-1].strip():
    out.pop()

append = None
for line in out:
    tokens = line.split(None, 1)
    if tokens and tokens[0] == "APPEND":
        append = tokens[1].strip() if len(tokens) > 1 else ""
        break
if append is None:
    sys.stderr.write(f"l4t-kernel-kvm: в {path} нет ни одной строки APPEND — брать нечего; файл не изменён\n")
    sys.exit(1)

if any(l.startswith("DEFAULT ") for l in out):
    out = ["DEFAULT kvm" if l.startswith("DEFAULT ") else l for l in out]
else:
    out.insert(0, "DEFAULT kvm")

entry = ["", "LABEL kvm",
         f"      MENU LABEL kvm kernel ({localversion.lstrip('-')}, l4t-kernel-kvm)",
         "      LINUX /boot/Image.kvm",
         "      INITRD /boot/initrd"]
if fdt:
    entry.append(f"      FDT {fdt}")
entry.append(f"      APPEND {append}")
new = "\n".join(out + entry) + "\n"
if new == text:
    sys.stderr.write("l4t-kernel-kvm: запись kvm уже такая — файл не менялся\n")
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".extlinux.conf.")
try:
    with os.fdopen(fd, "w", **ENC) as f:
        f.write(new)
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise
sys.stderr.write("l4t-kernel-kvm: запись kvm записана и назначена умолчанием\n")
PYEOF
}
