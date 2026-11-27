#!/usr/bin/env python3
"""
Merge a kconfig fragment into a .config, in place.

    merge_kconfig.py <.config> <fragment> [fragment ...]

The kernel ships scripts/kconfig/merge_config.sh for this; BusyBox does not, and
appending a fragment to the end of a .config is not a substitute. kconfig does
read last-wins for plain symbols, but it warns on every one of them, and a
symbol inside a `choice` block cannot be reassigned at all:

    .config:1268:warning: SH_IS_ASH creates inconsistent choice state

which BusyBox's conf treats as fatal. The fix is to delete each symbol's old
definition before writing the new one, so every symbol is defined exactly once.

Both forms of a definition count as one, and either can replace the other:

    CONFIG_FOO=y
    CONFIG_FOO="a string"
    # CONFIG_FOO is not set

Comment lines that are not the "is not set" form are just comments and are
carried through from the fragment untouched. The output keeps the original
file's ordering, with anything genuinely new appended - which keeps the diff
between two generated configs readable.
"""

import re
import sys

SET = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=")
UNSET = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def symbol(line):
    m = SET.match(line) or UNSET.match(line)
    return m.group(1) if m else None


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: merge_kconfig.py <.config> <fragment> [fragment ...]")

    config, fragments = sys.argv[1], sys.argv[2:]

    # Read the fragments first: a later fragment overrides an earlier one, the
    # same way a later line overrides an earlier one within a file.
    new = {}
    order = []
    for path in fragments:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                sym = symbol(line)
                if sym:
                    if sym not in new:
                        order.append(sym)
                    new[sym] = line

    out = []
    replaced = set()
    with open(config) as f:
        for line in f:
            line = line.rstrip("\n")
            sym = symbol(line)
            if sym and sym in new:
                out.append(new[sym])
                replaced.add(sym)
            else:
                out.append(line)

    added = [s for s in order if s not in replaced]
    if added:
        out.append("")
        out.append("# --- merged from: " + " ".join(fragments) + " ---")
        out.extend(new[s] for s in added)

    with open(config, "w") as f:
        f.write("\n".join(out) + "\n")

    print(f"merge_kconfig: {len(replaced)} replaced, {len(added)} added, "
          f"{len(new)} in fragment(s)")


if __name__ == "__main__":
    main()
