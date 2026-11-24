#!/usr/bin/env python3
"""H1: report the Health Connect footprint of a merged manifest (`aapt2 dump xmltree` text).

Usage: manifest_health_report.py <xmltree.txt>
Prints every element whose OWN attributes mention "health" (with its path, e.g.
manifest/queries/package), and the health permissions. Report only: exit 0.
"""
import re
import sys

ELEM = re.compile(r"^(\s*)E: (\S+)")


def main() -> int:
    lines = open(sys.argv[1]).read().splitlines()
    stack: list[tuple[int, str]] = []
    found = []
    perms = []
    i = 0
    while i < len(lines):
        m = ELEM.match(lines[i])
        if not m:
            i += 1
            continue
        depth, name = len(m.group(1)), m.group(2)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        stack.append((depth, name))
        own = []
        j = i + 1
        while j < len(lines) and not ELEM.match(lines[j]):
            own.append(lines[j].strip())
            j += 1
        attrs = " ".join(own)
        if "health" in attrs.lower():
            path = "/".join(n for _, n in stack)
            values = re.findall(r'="([^"]*)"', attrs)
            found.append(f"{path}: {', '.join(values)}")
            if name.startswith("uses-permission"):
                perms += [v for v in values if "health" in v.lower()]
        i = j
    print(f"H1 manifest elements mentioning health: {len(found)}")
    for f in found:
        print(f"  {f}")
    print(f"H1 health permissions: {', '.join(perms) if perms else 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
