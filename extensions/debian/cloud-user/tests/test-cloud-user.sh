#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Tests of the cloud-user library (cream/v1, kind: library): the manifest and
# get_cloud_user.sh, run the way a consumer hook runs it — clean environment,
# CREAM_ROOT a scratch root, fake cloud-init, yq and getent first in PATH. The
# PATH holds only $ROOT/bin (host tools linked one by one), so the cloud-init
# and yq of the host never answer. root, cloud-init and network are not needed.
#
#   extensions/debian/cloud-user/tests/test-cloud-user.sh   code 0 — all checks passed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$(dirname "$HERE")"
# shellcheck source=../../../../tools/hooktest.sh
. "$EXT/../../../tools/hooktest.sh"
ht_init

PY="$(command -v python3)"

# lib_root: a fresh root with the library and a minimal toolbox. Fakes:
#   cloud-init  `query userdata` prints $FAKE/userdata; absent file — exit 1
#   yq          mikefarah syntax subset over PyYAML: `.user // ""`, `.users[0].name // ""`
#   getent      `passwd` prints $FAKE/passwd
lib_root() {
    ht_root "$EXT"
    local t
    for t in bash env awk cat id head; do
        ln -s "$(command -v "$t")" "$ROOT/bin/$t"
    done
    ht_fake cloud-init '[[ "$*" == "query userdata" && -f "$FAKE/userdata" ]] || exit 1; cat "$FAKE/userdata"'
    {
        printf '#!%s\n' "$PY"
        cat <<'PY'
import sys, yaml
# The one query of get_cloud_user.sh, with the semantics of mikefarah/yq
# (checked against v4.45.1): `select(tag == …)` keeps a node of that type only,
# `//` takes the first non-null.
EXPR = ('(.user | select(tag == "!!map") | .name) // (.user | select(tag == "!!str")) // '
        '(.users[0] | select(tag == "!!map") | .name) // (.users[0] | select(tag == "!!str")) // ""')
if sys.argv[-1] != EXPR:
    sys.exit(3)
doc = yaml.safe_load(sys.stdin.read())
doc = doc if isinstance(doc, dict) else {}
def pick(node):
    if isinstance(node, dict):
        v = node.get("name")
        return str(v) if v is not None else None
    if isinstance(node, str):
        return node
    return None
users = doc.get("users")
first = users[0] if isinstance(users, list) and users else None
for cand in (pick(doc.get("user")), pick(first)):
    if cand is not None:
        print(cand)
        break
else:
    print("")
PY
    } > "$ROOT/bin/yq"
    chmod +x "$ROOT/bin/yq"
    ht_fake getent '[[ "$1" == passwd ]] && cat "$FAKE/passwd"'
    : > "$FAKE/passwd"
}

# no_cloud_init / no_yq: the image has no such command.
no_cloud_init() { rm -f "$ROOT/bin/cloud-init"; }
no_yq() { rm -f "$ROOT/bin/yq"; }

# run_lib: get_cloud_user.sh as a consumer hook calls it; stdout to $ROOT/stdout,
# stderr to $ROOT/stderr, status is the script's.
run_lib() {
    (
        cd "$HT_EXT" || exit 125
        exec env -i PATH="$ROOT/bin" LANG=C.UTF-8 CREAM_ROOT="$ROOT" \
            "$HT_EXT/get_cloud_user.sh" < /dev/null
    ) > "$ROOT/stdout" 2> "$ROOT/stderr"
}
stdout() { cat "$ROOT/stdout"; }

echo "== манифест =="
M="$EXT/extension.yaml"
eq "schema" cream/v1 "$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["schema"])' "$M")"
eq "kind: library" library "$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("kind"))' "$M")"
eq "хуков нет" "None" "$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])).get("hooks"))' "$M")"
check_not "каталога hooks/ нет" test -e "$EXT/hooks"
check "get_cloud_user.sh исполняемый" test -x "$EXT/get_cloud_user.sh"

echo "== пользователь из userdata cloud-init =="
lib_root
printf '#cloud-config\nuser: alice\n' > "$FAKE/userdata"
run_lib; eq "user: — код 0" 0 "$?"
eq "user: — имя" alice "$(stdout)"
check "cloud-init спрошен" ht_called '^cloud-init query userdata$'

printf '#cloud-config\nusers:\n  - name: bob\n    groups: [sudo]\n' > "$FAKE/userdata"
run_lib; eq "users[0].name — код 0" 0 "$?"
eq "users[0].name — имя" bob "$(stdout)"

printf '#cloud-config\nuser: {name: dora, sudo: "ALL=(ALL) NOPASSWD:ALL"}\n' > "$FAKE/userdata"
run_lib; eq "user: словарь — код 0" 0 "$?"
eq "user: словарь — .user.name" dora "$(stdout)"

printf '#cloud-config\nuser: {sudo: x}\nusers: [{name: zed}]\n' > "$FAKE/userdata"
run_lib; eq "user: словарь без name — код 0" 0 "$?"
eq "user: словарь без name — users[0].name" zed "$(stdout)"

printf '#cloud-config\nusers: [frank, {name: x}]\n' > "$FAKE/userdata"
run_lib; eq "users[0] строкой — код 0" 0 "$?"
eq "users[0] строкой — как есть" frank "$(stdout)"

echo "== недопустимое имя — запасной путь =="
printf 'carol:x:1001:1001::/home/carol:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/carol"
for junk in 'Bad Name;rm -rf' '-root' 'default' 'abcdefghijklmnopqrstuvwxyz0123456789'; do
    printf '#cloud-config\nuser: %s\n' "'$junk'" > "$FAKE/userdata"
    run_lib; eq "имя [$junk] — код 0" 0 "$?"
    eq "имя [$junk] — запасная учётка" carol "$(stdout)"
    check "имя [$junk] — сказано в stderr" grep -q 'not a valid user name' "$ROOT/stderr"
done

echo "== запасной файл user-data.txt =="
lib_root
mkdir -p "$ROOT/var/lib/cloud/instance"
printf '#cloud-config\nuser: erin\n' > "$ROOT/var/lib/cloud/instance/user-data.txt"
run_lib; eq "query упал, файл есть — код 0" 0 "$?"
eq "имя из файла под CREAM_ROOT" erin "$(stdout)"

echo "== гонка: cloud-init есть, данных нет =="
lib_root
run_lib; eq "нет userdata и файла — код 1" 1 "$?"
eq "stdout пуст" "" "$(stdout)"
check "stderr: данных пока нет" grep -q 'not ready' "$ROOT/stderr"
printf 'alice:x:1000:1000::/home/alice:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/alice"
run_lib; eq "гонка — запасной путь не берётся" 1 "$?"
printf 'null' > "$FAKE/userdata"
run_lib; eq "userdata null — код 1" 1 "$?"

echo "== yq ответил пусто или ошибкой — запасной путь =="
lib_root
printf 'carol:x:1001:1001::/home/carol:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/carol"
printf '#cloud-config\npackages: [vim]\n' > "$FAKE/userdata"
run_lib; eq "нет user — код 0" 0 "$?"
eq "нет user — запасная учётка" carol "$(stdout)"
check "нет user — сказано в stderr" grep -q 'no user name from yq' "$ROOT/stderr"
printf '#cloud-config\nuser: alice\n' > "$FAKE/userdata"
for body in 'echo ""' 'echo "jq: error: tag/0 is not defined" >&2; exit 3'; do
    ht_fake yq "$body"
    run_lib; eq "yq [$body] — код 0" 0 "$?"
    eq "yq [$body] — запасная учётка" carol "$(stdout)"
done

echo "== запасной путь: нет cloud-init или yq =="
for missing in cloud-init yq; do
    lib_root
    if [[ "$missing" == cloud-init ]]; then no_cloud_init; else no_yq; fi
    printf '#cloud-config\nuser: alice\n' > "$FAKE/userdata"
    cat > "$FAKE/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
sys:x:999:999::/home/sys:/usr/sbin/nologin
vendor:x:1000:1000::/home/vendor:/bin/bash
carol:x:1001:1001::/home/carol:/bin/bash
nobody:x:65534:65534::/home/nobody:/usr/sbin/nologin
EOF
    mkdir -p "$ROOT/home/sys" "$ROOT/home/carol" "$ROOT/home/nobody"
    run_lib; eq "нет $missing — код 0" 0 "$?"
    eq "нет $missing — первая учётка uid>=1000 с домом под CREAM_ROOT" carol "$(stdout)"
    check "нет $missing — запасной путь назван в stderr" grep -q "falling back to 'carol'" "$ROOT/stderr"
    check_not "нет $missing — stdout только имя" grep -q Note "$ROOT/stdout"
done
check_not "без cloud-init userdata не читается" ht_called '^cloud-init'

lib_root
no_cloud_init
printf 'nobody:x:65534:65534::/home/nobody:/usr/sbin/nologin\nsys:x:999:999::/home/sys:/bin/sh\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/nobody" "$ROOT/home/sys"
run_lib; eq "нет обычной учётки с домом — код 1" 1 "$?"
check "stderr объясняет" grep -q 'no regular account' "$ROOT/stderr"

echo "== запасной путь: имя учётки проверяется, как у потребителей =="
lib_root
no_cloud_init
printf 'Evil$(id):x:1000:1000::/home/x:/bin/bash\nb\033[31mad:x:1001:1001::/home/y:/bin/bash\nwith space:x:1002:1002::/home/z:/bin/bash\ncarol:x:1003:1003::/home/carol:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/Evil\$(id)" "$ROOT/home/"$'b\e[31mad' "$ROOT/home/with space" "$ROOT/home/with" "$ROOT/home/carol"
run_lib; eq "кривые имена пропущены — код 0" 0 "$?"
eq "кривые имена пропущены — carol" carol "$(stdout)"
check "пропуск назван в stderr" grep -q 'not a valid user name' "$ROOT/stderr"
check_not "в stderr нет ESC" grep -q $'\e' "$ROOT/stderr"
lib_root
no_cloud_init
printf 'b\033[31mad:x:1001:1001::/home/y:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/"$'b\e[31mad'
run_lib; eq "только кривое имя — код 1" 1 "$?"
eq "только кривое имя — stdout пуст" "" "$(stdout)"
check_not "только кривое имя — в stderr нет ESC" grep -q $'\e' "$ROOT/stderr"

echo "== имя cloud-init с управляющими символами — stderr чистый =="
lib_root
printf '#cloud-config\nuser: "a\\e[31mlice"\n' > "$FAKE/userdata"
printf 'carol:x:1001:1001::/home/carol:/bin/bash\n' > "$FAKE/passwd"
mkdir -p "$ROOT/home/carol"
run_lib; eq "ESC в имени cloud-init — запасная учётка" carol "$(stdout)"
check "сказано в stderr" grep -q 'not a valid user name' "$ROOT/stderr"
check_not "в stderr нет ESC" grep -q $'\e' "$ROOT/stderr"

ht_done
