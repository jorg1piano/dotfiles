#!/usr/bin/env python3
"""Merge a set of Herdr keybindings into ~/.config/herdr/config.toml.

Herdr has no include mechanism, so bindings have to live in the user's own
config. They go between markers named after their owner, and nothing outside
those markers is touched, so the file stays theirs: their prefix, their theme,
their other bindings.

A binding that already claims one of our keys is removed and reported, so two
owners can hand the same key back and forth: `just herdr init` in your dotfiles
takes it, `just herdr init` in ragnarok takes it back.

    merge-keys.py CONFIG KEYS [--owner NAME]   insert or refresh the block
    merge-keys.py --installed CONFIG [--owner NAME]  exit 0 if the block is there
    merge-keys.py --remove CONFIG [--owner NAME]     take the block out
"""

import pathlib
import re
import sys
import tomllib

KEY_RE = re.compile(r'^\s*key\s*=\s*"([^"]*)"', re.MULTILINE)


def markers(owner: str) -> tuple[str, str]:
    return (
        f"# >>> {owner} herdr keys: managed by `just herdr init`, do not edit inside >>>",
        f"# <<< {owner} herdr keys <<<",
    )


def strip_block(text: str, owner: str) -> str:
    """Return text with the owner's managed block gone."""
    begin, end = markers(owner)
    if begin not in text or end not in text:
        return text
    head, rest = text.split(begin, 1)
    tail = rest.split(end, 1)[1]
    return head.rstrip("\n") + ("\n" + tail.lstrip("\n") if tail.strip() else "\n")


def keys_in(text: str) -> set[str]:
    return {c["key"] for c in tomllib.loads(text).get("keys", {}).get("command", [])}


def is_marker(line: str) -> bool:
    """A managed block's own begin/end line, which is never part of a binding."""
    stripped = line.strip()
    return stripped.startswith("# >>>") or stripped.startswith("# <<<")


def drop_bindings(text: str, wanted: set[str]) -> tuple[str, list[str]]:
    """Remove every [[keys.command]] block that binds one of `wanted`.

    Array-of-tables entries cannot be edited through a TOML writer without
    rewriting the whole file and losing the user's comments and layout, so this
    works on the text: a block runs from its header to the next table header,
    and the comment lines directly above it are part of it. Marker lines bound a
    block on both sides, so taking the last binding inside another owner's block
    cannot swallow that block's closing line.
    """
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if ln.strip() == "[[keys.command]]"]
    drop: set[int] = set()
    removed: list[str] = []

    for start in starts:
        stop = next(
            (
                j
                for j in range(start + 1, len(lines))
                if lines[j].lstrip().startswith("[") or is_marker(lines[j])
            ),
            len(lines),
        )
        found = KEY_RE.search("\n".join(lines[start:stop]))
        if not found or found.group(1) not in wanted:
            continue
        # Absorb the comment lines and one blank separator above the header.
        top = start
        while top > 0 and lines[top - 1].lstrip().startswith("#") and not is_marker(lines[top - 1]):
            top -= 1
        if top > 0 and not lines[top - 1].strip():
            top -= 1
        # Trailing blank lines belong to the gap, not the next block.
        while stop > start and not lines[stop - 1].strip():
            stop -= 1
        drop.update(range(top, stop))
        removed.append(found.group(1))

    if not drop:
        return text, []
    kept = "\n".join(ln for i, ln in enumerate(lines) if i not in drop)
    return drop_empty_blocks(kept.rstrip("\n") + "\n"), removed


def drop_empty_blocks(text: str) -> str:
    """Remove managed blocks left with no bindings after a key was taken.

    An owner whose only binding was taken should stop reporting itself as
    installed, and an empty marker pair is just litter in someone's config.
    """
    lines = text.splitlines()
    keep = [True] * len(lines)
    opens = [i for i, ln in enumerate(lines) if ln.strip().startswith("# >>>")]
    for start in opens:
        stop = next(
            (j for j in range(start + 1, len(lines)) if lines[j].strip().startswith("# <<<")),
            None,
        )
        if stop is None:
            continue
        if any(ln.strip() == "[[keys.command]]" for ln in lines[start:stop]):
            continue
        top = start - 1 if start > 0 and not lines[start - 1].strip() else start
        for j in range(top, stop + 1):
            keep[j] = False
    if all(keep):
        return text
    return "\n".join(ln for i, ln in enumerate(lines) if keep[i]).rstrip("\n") + "\n"


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--owner"]
    owner = "dotfiles"
    if "--owner" in sys.argv:
        owner = sys.argv[sys.argv.index("--owner") + 1]
        args = [a for a in args if a != owner]
    begin, end = markers(owner)

    if args and args[0] == "--installed":
        return 0 if begin in pathlib.Path(args[1]).read_text() else 1

    if args and args[0] == "--remove":
        path = pathlib.Path(args[1])
        path.write_text(strip_block(path.read_text(), owner))
        return 0

    if len(args) != 2:
        sys.exit(__doc__)

    path, keys = pathlib.Path(args[0]), pathlib.Path(args[1])
    current = path.read_text()

    # Drop our own block first, so a refresh does not read as a conflict with
    # itself, then take the key from whoever else is holding it.
    body = strip_block(current, owner)
    body, removed = drop_bindings(body, keys_in(keys.read_text()))
    for key in removed:
        print(f"took {key} from an existing binding in {path}")

    # [[keys.command]] is an array of tables, so the block has to land at the
    # end of the file: appended under someone's [theme] it would be reparented.
    body = body.rstrip("\n")
    parts = ([body, ""] if body else []) + [begin, keys.read_text().strip(), end, ""]
    path.write_text("\n".join(parts))
    print(f"{'updated' if begin in current else 'added'} the {owner} block in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
