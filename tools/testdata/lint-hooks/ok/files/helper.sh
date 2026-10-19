# shellcheck shell=bash
# Sourced helper of the lint fixture: no shebang and no `set` of its own.
ok_log() { echo "[ok] $*" >&2; }
