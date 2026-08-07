#!/usr/bin/env python3
# =========================================================================================== #
# File: 'scripts/check-winshell-splitargs.py'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Static gate for the wsus role's inline PowerShell. Every win_shell / win_command free-form
# block MUST (a) parse cleanly through Ansible's split_args and (b) contain NO backslash
# immediately before a quote (\' or \").
#
# WHY THIS EXISTS (proven 2026-07-17, maturity pass M1): Ansible parses the free-form arg of
# win_shell/win_command with split_args, which honors backslash as an escape EVEN INSIDE single
# quotes. A backslash right before a closing quote — Replace('/','\'), 'IIS:\Sites\', 'C:\' —
# escapes the quote, unbalances the parser, and fails the task at LOAD time
# ("failed at splitting arguments, either an unbalanced jinja2 block or quotes"). The regular
# static gate does NOT catch this: yamllint lints YAML only; ansible-lint lints YAML only; and
# `ansible-playbook --syntax-check` was empirically shown to pass an unbalanced-\' regression.
# The failure surfaces only at real playbook runtime (this is exactly how the C12c bug escaped).
# This dedicated check closes that gap. Fix any hit with [char]92 (and keep \ off closing quotes).
#
# Usage (run with the ansible-core venv python — it provides both yaml and ansible.parsing):
#   /root/.local/share/pipx/venvs/ansible-core/bin/python scripts/check-winshell-splitargs.py
#   (optional: pass explicit task-file paths as args; default globs applications/*/tasks/*.yml)
#
# Exit 0 = clean; 1 = unreadable input, no blocks, or a block-level failure; 3 = wrong python.
# =========================================================================================== #
import sys
import os
import re
import glob

try:
    import yaml
    from ansible.parsing.splitter import split_args
except ImportError as exc:
    sys.stderr.write(
        "check-winshell-splitargs: run with the ansible-core venv python "
        "(needs PyYAML + ansible.parsing.splitter): %s\n" % exc)
    sys.exit(3)

FREEFORM_MODULES = (
    'ansible.windows.win_shell', 'community.windows.win_shell',
    'ansible.windows.win_command', 'community.windows.win_command',
    'win_shell', 'win_command',
)
BACKSLASH_BEFORE_QUOTE = re.compile(r"\\['\"]")


def collect_blocks(tasks, out):
    """Recurse tasks (incl. block/rescue/always) collecting (name, module, content) tuples."""
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        for mod in FREEFORM_MODULES:
            if mod in task and isinstance(task[mod], str):
                out.append((task.get('name', '<unnamed>'), mod, task[mod]))
        for key in ('block', 'rescue', 'always'):
            if key in task:
                collect_blocks(task[key], out)


def main(argv):
    paths = argv[1:]
    if not paths:
        here = os.path.dirname(os.path.abspath(__file__))
        paths = sorted(glob.glob(os.path.join(
            here, '..', 'ansible', 'applications', '*', 'tasks', '*.yml')))
    if not paths:
        print("[FAIL discovery] no application task files found")
        return 1

    problems = 0
    scanned = 0
    for path in paths:
        try:
            with open(path, encoding='utf-8') as task_file:
                docs = list(yaml.safe_load_all(task_file))
        except Exception as exc:  # noqa: BLE001 — every unreadable input fails the gate
            problems += 1
            print("[FAIL YAML] %s: load error (%s)" % (path, exc))
            continue
        blocks = []
        for doc in docs:
            if isinstance(doc, list):
                collect_blocks(doc, blocks)
        for name, _mod, content in blocks:
            scanned += 1
            try:
                split_args(content)
            except Exception as exc:  # noqa: BLE001 — split_args raises AnsibleError
                problems += 1
                print("[FAIL split_args] %s :: %s -> %s"
                      % (os.path.relpath(path), name, str(exc).splitlines()[0]))
            for match in BACKSLASH_BEFORE_QUOTE.finditer(content):
                problems += 1
                snippet = content[max(0, match.start() - 14):match.start() + 2]
                print("[FAIL backslash-before-quote] %s :: %s (…%s) — use [char]92"
                      % (os.path.relpath(path), name, snippet))
    if scanned == 0:
        problems += 1
        print("[FAIL discovery] no win_shell/win_command free-form blocks found")
    print("\nscanned %d win_shell/win_command block(s); %d problem(s)" % (scanned, problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
