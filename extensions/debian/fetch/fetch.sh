# shellcheck shell=bash
# Compatibility shim of the library extension fetch (1.1.0, deprecated): the
# consumers of catalog 5.4.2 (selkies 6.2.0, code-server 5.2.0/5.2.1, rustdesk
# 2.2.0) source /opt/cream/ext/fetch/fetch.sh. From 5.5.0 every consumer carries
# its own files/fetch.sh (one copy in git — lib/fetch.sh, laid by the snapshot)
# and does not depend on fetch; once they are upgraded `cream remove fetch`.
# shellcheck source=../../../lib/fetch.sh
. "$(dirname "${BASH_SOURCE[0]}")/files/fetch.sh"
