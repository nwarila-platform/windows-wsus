#!/usr/bin/env python3
"""Require immutable revisions for every external GitHub Action."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", re.MULTILINE)
PINNED_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
PINNED_CONTAINER = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")


def main() -> int:
    failures: list[str] = []
    checked = 0

    for workflow in sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml"))):
        text = workflow.read_text(encoding="utf-8")
        for match in USES.finditer(text):
            target = match.group(1).strip("'\"")
            line = text.count("\n", 0, match.start()) + 1
            if target.startswith("./"):
                continue
            checked += 1
            valid = (
                PINNED_CONTAINER.fullmatch(target)
                if target.startswith("docker://")
                else PINNED_ACTION.fullmatch(target)
            )
            if not valid:
                failures.append(
                    f"{workflow.relative_to(ROOT)}:{line}: {target!r} is not pinned to an immutable digest"
                )

    if checked == 0:
        failures.append("no external actions were found; the scanner is probably looking in the wrong place")

    for failure in failures:
        print(f"check-action-pins: FAIL — {failure}", file=sys.stderr)
    if failures:
        return 1

    print(f"check-action-pins: OK — {checked} external action reference(s) are immutable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
