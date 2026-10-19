#!/usr/bin/env bash
# cloud-user library (cream/v1, kind: library): the name of the cloud-init user.
# Prints only the user name, or fails with a message on stderr.
#
# Consumers declare `depends: [{name: cloud-user, version: ">=1.0.0 <2"}]` and
# run it by the stable path:
#     user="$("${CREAM_ROOT:-}/opt/cream/ext/cloud-user/get_cloud_user.sh")"
# Exit 1 while cloud-init has no userdata yet is a race, not an absence: the
# caller waits and retries.

set -euo pipefail

# Paths go under CREAM_ROOT (empty on a machine): the tests and fixture roots
# run the library on a scratch root, as cream runs the hooks of its consumers.
ROOT="${CREAM_ROOT:-}"
ROOT="${ROOT%/}"

# The user name rule of the consumers (and of useradd by default): the name goes
# into paths, gsettings and units, so anything else is not a user here.
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'

# printable TEXT: TEXT cut to 64 characters, anything but [[:alnum:]_.+-] as
# '?' — a name from passwd or userdata never reaches a terminal or the journal
# with its control characters.
printable() {
    local t="${1:0:64}"
    printf '%s' "${t//[^[:alnum:]_.+-]/?}"
}

# Функция для получения пользователя из cloud-init
fallback_user() {
    # Первая обычная учётная запись с домашним каталогом.
    #
    # Диапазон uid тот же, что у `adduser` в Debian: 1000..65533. Верхняя
    # граница отсекает `nobody` (65534), нижняя — системные учётки.
    # Домашний каталог обязателен: всё, что настраивают расширения
    # (gsettings, ключи, автозапуск), живёт в нём, и учётка без него
    # настройке не поддаётся.
    #
    # Имя проверяется тем же правилом, что у потребителей (RE_USER): учётка с
    # именем вроде `x$(id)` или с управляющими символами пропускается с
    # пометкой, а не уходит в пути и юниты.
    local candidate uid rest
    while IFS=: read -r candidate _ uid rest; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 1000 && uid < 65534 )) || continue
        if [[ ! "$candidate" =~ $RE_USER ]]; then
            echo "Note: account '$(printable "$candidate")' (uid $uid) is not a valid user name — skipped" >&2
            continue
        fi
        if [[ -d "${ROOT}/home/${candidate}" ]]; then
            # Сказать вслух, что пошли запасным путём, и какую учётку выбрали.
            #
            # Единственное место, где эти два факта известны разом. Раньше
            # запасной путь молчал, и настройка «не того» пользователя
            # выглядела снаружи как успешная: журнал говорил, что автологин
            # настроен, а настроен он был вендорской учётке, которая в
            # /etc/passwd оказалась раньше cloud-init-овской.
            #
            # В stderr, а не в stdout: stdout — это возвращаемое имя, и
            # подмешивать в него диагностику значит ломать вызывающих,
            # которые читают его как $(get_cloud_user).
            echo "Note: cloud-init user unavailable; falling back to '${candidate}' (uid $(id -u "$candidate" 2>/dev/null || echo '?'))" >&2
            echo "$candidate"
            return 0
        fi
    done < <(getent passwd)
    echo "Error: no cloud-init user and no regular account with a home dir" >&2
    return 1
}

get_cloud_user() {
    local ci_user=""

    # Проверяем доступность необходимых команд
    # Отсутствие cloud-init или yq — НЕ отказ, а переход к запасному пути.
    #
    # Раньше здесь стоял `return 1`, и на образе без cloud-init поиск
    # проваливался всегда. Замер 2026-09-04 на живом Jetson: вендорский
    # образ Q-engineering собран без cloud-init, и `vino-vnc` с
    # `jetson-stats` не настроились вовсе, а `docker` настроился —
    # потому что у него, единственного из трёх, запасной путь был
    # дописан в своём `configure.sh`. Одна задача решалась в двух
    # местах по-разному, и работало то, где решили полнее.
    #
    # Запасной путь теперь здесь, в библиотеке: он одинаков у всех
    # потребителей, и класть его в каждый хук `configure` значило бы
    # завести расходящиеся копии вместо одной.
    if ! command -v cloud-init >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
        fallback_user
        return $?
    fi

    # Получаем пользовательские данные из cloud-init
    local userdata
    if ! userdata=$(cloud-init query userdata 2>/dev/null); then
        # Альтернативный способ - читаем напрямую из файла
        local user_data_file="${ROOT}/var/lib/cloud/instance/user-data.txt"
        if [[ -f "$user_data_file" ]]; then
            userdata=$(cat "$user_data_file" 2>/dev/null || echo "")
        else
            # cloud-init установлен, но данных пока нет — это ГОНКА,
            # а не отсутствие. Отказ здесь означает «попробуй ещё раз»,
            # и вызывающий цикл ждёт. Запасной путь тут вернул бы
            # вендорского пользователя раньше, чем cloud-init создаст
            # своего, — то есть настроил бы не того.
            echo "Error: cloud-init userdata not ready yet" >&2
            return 1
        fi
    fi

    # Если userdata пустые, выходим с ошибкой
    if [[ -z "$userdata" ]] || [[ "$userdata" == "null" ]]; then
        # Тоже гонка: см. выше.
        echo "Error: No cloud-init userdata found" >&2
        return 1
    fi

    # Извлекаем пользователя с помощью yq в чистом окружении.
    # Сам yq находится по PATH вызывающего (там, где его нашла проверка выше),
    # а запускается уже с чистым окружением.
    local yq_bin
    yq_bin="$(command -v yq)"
    # Один запрос по документации cloud-init: `user` — строка (имя как есть)
    # или словарь (берётся `.name`); если его нет — первый элемент `users`,
    # тоже строкой или словарём. `select(tag == …)` оставляет узел только
    # нужного типа, поэтому словарь не печатается YAML-ом вместо имени
    # (так было с `.user // ""` при `user: {name: …}`). Язык — mikefarah/yq
    # (расширение yq); у kislyuk/yq запрос не разберётся, и ответ будет пуст.
    local query
    query='(.user | select(tag == "!!map") | .name) // (.user | select(tag == "!!str")) // '
    query+='(.users[0] | select(tag == "!!map") | .name) // (.users[0] | select(tag == "!!str")) // ""'
    ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb "$yq_bin" -r "$query" 2>/dev/null || true)

    if [[ -n "$ci_user" ]]; then
        # Имя уходит в пути, gsettings и юниты потребителей: только то, что
        # примет useradd по умолчанию. `default` в `users` — ссылка на
        # default_user из cloud.cfg, а не имя; его, как и мусор, закрывает
        # запасной путь (первая обычная учётка с домом и есть default_user).
        if [[ "$ci_user" =~ $RE_USER && "$ci_user" != default ]]; then
            echo "$ci_user"
            return 0
        fi
        echo "Note: cloud-init user '$(printable "$ci_user")' is not a valid user name" >&2
        fallback_user
        return $?
    fi

    # Данные cloud-init есть, а имени yq не дал: пользователя в seed нет,
    # yq не тот (kislyuk/yq не разбирает запрос) или упал. Отличить одно от
    # другого по пустому ответу нельзя, и ни в одном случае отказ ничего не
    # чинит — поэтому запасной путь, с пометкой в stderr.
    echo "Note: no user name from yq in cloud-init userdata" >&2
    fallback_user
    return $?
}

# Основная логика
main() {
    local user

    if user=$(get_cloud_user); then
        echo "$user"
        exit 0
    else
        exit 1
    fi
}

main "$@"
