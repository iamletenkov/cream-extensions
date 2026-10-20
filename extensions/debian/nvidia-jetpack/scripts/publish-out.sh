# shellcheck shell=bash
# Results of step 09 go to the operator without root writing into a directory
# the operator owns. Sourced by step 09.
#
#     stage_init STAGE                 fresh root-owned STAGE (the old one removed)
#     publish_out STAGE OUT_DIR [UID:GID]
#
# The build writes into STAGE ($WORK/.out-stage), a directory only root
# writes to. publish_out hands STAGE and its top-level regular files to the
# operator (chown -h on a named list — never -R, never through a link) and
# moves them into OUT_DIR AS THE OPERATOR: a link the operator planted in
# OUT_DIR is followed with the operator's rights, not root's. Without an
# owner (root ran it directly) root moves them itself. Links and *.tmp in
# STAGE are not published.

# _po_as UID GID CMD…: CMD as UID:GID (directly when that is already us).
_po_as() {
    local uid="$1" gid="$2"; shift 2
    if [ "$(id -u)" = "$uid" ] && [ "$(id -g)" = "$gid" ]; then
        "$@"
    else
        setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
    fi
}

stage_init() {
    local stage="$1"
    # The previous STAGE belongs to the operator after publish_out: nothing
    # in it is trusted. rm -r does not follow links; mkdir without -p fails
    # if something took the name in between.
    rm -r -f -- "$stage" || return 1
    mkdir -m 0755 -- "$stage" || { echo "ОТКАЗ: $stage не создан (имя занято?)"; return 1; }
}

publish_out() {
    local stage="$1" out="$2" owner="${3:-}" uid="" gid="" f n files=()
    if [ -n "$owner" ]; then
        [[ "$owner" =~ ^([0-9]+)(:([0-9]+))?$ ]] \
            || { echo "ОТКАЗ: владелец результатов '$owner' — ждали UID[:GID] числами"; return 1; }
        uid="${BASH_REMATCH[1]}"; gid="${BASH_REMATCH[3]:-$uid}"
    fi
    [ -d "$stage" ] && [ ! -L "$stage" ] || { echo "ОТКАЗ: нет каталога сборки $stage"; return 1; }
    for f in "$stage"/*; do
        n="$(basename -- "$f")"
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        case "$n" in *.tmp) continue ;; esac
        files+=("$n")
    done
    [ "${#files[@]}" -gt 0 ] || { echo "ОТКАЗ: в $stage нет результатов"; return 1; }
    if [ -L "$out" ]; then
        echo "ОТКАЗ: $out — символическая ссылка; результаты через ссылку не кладу"
        return 1
    fi

    if [ -z "$owner" ]; then
        mkdir -p -- "$out" || return 1
        for n in "${files[@]}"; do
            mv -f -T -- "$stage/$n" "$out/$n" || return 1
        done
        return 0
    fi

    # OUT_DIR: created by root if absent (its parent may be root's $WORK),
    # then handed over — the directory itself, not its contents.
    if [ ! -e "$out" ]; then
        mkdir -- "$out" || return 1
    fi
    [ -d "$out" ] || { echo "ОТКАЗ: $out — не каталог"; return 1; }
    case "$(stat -c %u -- "$out")" in
        0) chown -h -- "$uid:$gid" "$out" || return 1 ;;
        "$uid") ;;
        *) echo "ОТКАЗ: $out принадлежит uid $(stat -c %u -- "$out"), а не root и не $uid"; return 1 ;;
    esac
    chown -h -- "$uid:$gid" "$stage" || return 1
    for n in "${files[@]}"; do
        chown -h -- "$uid:$gid" "$stage/$n" || return 1
    done
    for n in "${files[@]}"; do
        _po_as "$uid" "$gid" mv -f -T -- "$stage/$n" "$out/$n" \
            || { echo "ОТКАЗ: $n не перенесён в $out от имени $uid"; return 1; }
    done
}
