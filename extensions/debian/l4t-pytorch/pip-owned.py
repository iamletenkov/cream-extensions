"""Which Python distributions in /usr/local belong to this extension.

pip as root installs into /usr/local/lib/python3.X/dist-packages; `remove`
must take away only what `install` put there, and never a distribution another
one still needs (numpy and scipy are shared by l4t-pytorch and l4t-tensorflow,
the same file lives in both trees).

    pip-owned.py list             names of the distributions there, one per line
    pip-owned.py has NAME         exit 0 when NAME is installed there
    pip-owned.py removable FILE   names from FILE (one per line) that may go:
                                  installed, and not required by a distribution
                                  outside that set (optional extras do not count)

Names are normalized (PEP 503: lower case, runs of -_. as one -). The site
directories are taken under CREAM_ROOT ("/" on a machine), never from
sys.path: the hook asks about the machine, not about this interpreter.
Metadata is read as data; nothing is imported from the site directories.
"""

import glob
import os
import re
import sys
from importlib import metadata


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def sites():
    root = os.environ.get("CREAM_ROOT", "").rstrip("/")
    return sorted(glob.glob(root + "/usr/local/lib/python3*/dist-packages"))


def installed():
    """{normalized name: [normalized names it requires]}"""
    out = {}
    for dist in metadata.distributions(path=sites()):
        name = dist.metadata["Name"]
        if not name:
            continue
        reqs = []
        for req in dist.requires or []:
            spec, _, marker = req.partition(";")
            if "extra" in marker:
                continue
            m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", spec)
            if m:
                reqs.append(norm(m.group(1)))
        out[norm(name)] = reqs
    return out


def main(argv):
    if len(argv) == 2 and argv[1] == "list":
        print("\n".join(sorted(installed())))
        return 0
    if len(argv) == 3 and argv[1] == "has":
        return 0 if norm(argv[2]) in installed() else 1
    if len(argv) == 3 and argv[1] == "removable":
        have = installed()
        with open(argv[2], encoding="utf-8") as f:
            ours = {norm(line.strip()) for line in f if line.strip()}
        go = ours & set(have)
        changed = True
        while changed:
            changed = False
            for name, reqs in have.items():
                if name in go:
                    continue
                for r in reqs:
                    if r in go:
                        go.discard(r)
                        print(f"{r}: нужен {name} — остаётся", file=sys.stderr)
                        changed = True
        print("\n".join(sorted(go)))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
