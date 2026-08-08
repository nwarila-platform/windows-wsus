#!/usr/bin/env python3
"""Require immutable revisions for every external GitHub Action."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Iterator

import yaml
from yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
PINNED_CONTAINER = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
STRING_TAG = "tag:yaml.org,2002:str"
JOB_USES_CONTEXT = re.compile(r"^\$\.jobs\.[A-Za-z_][A-Za-z0-9_-]*\.uses$")
STEP_USES_CONTEXT = re.compile(
    r"^(?:\$\.jobs\.[A-Za-z_][A-Za-z0-9_-]*\.steps\[[0-9]+\]|"
    r"\$\.runs\.steps\[[0-9]+\])\.uses$"
)


def context_segment(key: Node) -> str:
    if isinstance(key, ScalarNode):
        value = key.value
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", value):
            return f".{value}"
        return f"[{value!r}]"
    return "[<complex-key>]"


def iter_uses(node: Node, context: str = "$") -> Iterator[tuple[Node, str]]:
    """Yield every exact mapping key named ``uses`` from a parsed YAML node tree."""

    if isinstance(node, MappingNode):
        for key, value in node.value:
            child_context = f"{context}{context_segment(key)}"
            if isinstance(key, ScalarNode) and key.value == "uses":
                yield value, child_context
            yield from iter_uses(value, child_context)
    elif isinstance(node, SequenceNode):
        for index, value in enumerate(node.value):
            yield from iter_uses(value, f"{context}[{index}]")


def executable_uses_context(context: str) -> bool:
    """Return true for workflow jobs and workflow/composite-action steps."""

    return bool(JOB_USES_CONTEXT.fullmatch(context) or STEP_USES_CONTEXT.fullmatch(context))


def scan_workflow_text(
    text: str, source: str
) -> tuple[list[str], int, list[tuple[str, int, str]]]:
    failures: list[str] = []
    checked = 0
    local_references: list[tuple[str, int, str]] = []

    try:
        document = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        location = f":{mark.line + 1}:{mark.column + 1}" if mark is not None else ""
        return ([f"{source}{location}: invalid YAML: {exc.problem or exc}"], checked, [])

    if document is None:
        return ([f"{source}: workflow is empty"], checked, [])

    for value, context in iter_uses(document):
        if not executable_uses_context(context):
            continue
        line = value.start_mark.line + 1
        if not isinstance(value, ScalarNode) or value.tag != STRING_TAG:
            checked += 1
            failures.append(f"{source}:{line}: {context} must be a string action reference")
            continue

        target = value.value
        if target.startswith("./"):
            local_references.append((target, line, context))
            continue

        checked += 1
        valid = (
            PINNED_CONTAINER.fullmatch(target)
            if target.startswith("docker://")
            else PINNED_ACTION.fullmatch(target)
        )
        if not valid:
            failures.append(
                f"{source}:{line}: {context}={target!r} is not pinned to an immutable digest"
            )

    return failures, checked, local_references


def self_test() -> int:
    fixture = """
jobs:
  spaced:
    steps:
      - uses : acme/spaced@main
  quoted:
    steps:
      - 'uses': acme/quoted@v1
  flow:
    steps: [{name: Flow syntax, "uses": acme/flow@latest}]
  local:
    steps:
      - uses: ./local-action
  malformed:
    steps:
      - uses: {owner: acme}
  pinned:
    steps:
      - uses: acme/pinned@0123456789abcdef0123456789abcdef01234567
      - uses: docker://alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
runs:
  using: composite
  steps:
    - "uses" : acme/composite@edge
env: {uses: not-an-executable-action-key}
strategy:
  matrix:
    include:
      - scenario:
          steps:
            - uses: acme/data-only@latest
"""
    failures, checked, local_references = scan_workflow_text(fixture, "alternate-uses.yml")
    expected_targets = (
        "acme/spaced@main",
        "acme/quoted@v1",
        "acme/flow@latest",
        "acme/composite@edge",
    )
    self_failures: list[str] = []

    if checked != 7:
        self_failures.append(f"fixture checked {checked} external/malformed references; expected 7")
    if len(failures) != 5:
        self_failures.append(f"fixture produced {len(failures)} failures; expected 5")
    for target in expected_targets:
        if not any(repr(target) in failure for failure in failures):
            self_failures.append(f"alternate YAML spelling escaped detection: {target}")
    if not any("$.jobs.malformed.steps[0].uses" in failure for failure in failures):
        self_failures.append("non-string uses value escaped detection")
    if local_references != [("./local-action", 13, "$.jobs.local.steps[0].uses")]:
        self_failures.append(f"local action references were not isolated correctly: {local_references!r}")
    if any("acme/data-only@latest" in failure for failure in failures):
        self_failures.append("a nested matrix data key was mistaken for an executable action")

    parse_failures, _, _ = scan_workflow_text("jobs: [", "invalid.yml")
    if not parse_failures or "invalid YAML" not in parse_failures[0]:
        self_failures.append("invalid workflow YAML escaped detection")

    for failure in self_failures:
        print(f"check-action-pins self-test: FAIL — {failure}", file=sys.stderr)
    if self_failures:
        return 1

    print(
        "check-action-pins self-test: OK — alternate YAML and composite actions cannot evade pin checks"
    )
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if sys.argv[1:]:
        print("usage: check-action-pins.py [--self-test]", file=sys.stderr)
        return 2

    failures: list[str] = []
    checked = 0
    workflows = sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")))
    try:
        tracked_output = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        print(f"check-action-pins: FAIL — could not enumerate tracked files: {exc}", file=sys.stderr)
        return 2
    action_manifests = sorted(
        ROOT / relative.decode("utf-8")
        for relative in tracked_output.split(b"\0")
        if relative and Path(relative.decode("utf-8")).name in {"action.yml", "action.yaml"}
    )
    sources = sorted(set((*workflows, *action_manifests)))
    scanned_sources = {path.resolve() for path in sources}
    local_references: list[tuple[Path, str, int, str]] = []

    for source_path in sources:
        source = str(source_path.relative_to(ROOT))
        source_failures, source_checked, source_local_references = scan_workflow_text(
            source_path.read_text(encoding="utf-8"), source
        )
        failures.extend(source_failures)
        checked += source_checked
        local_references.extend(
            (source_path, target, line, context)
            for target, line, context in source_local_references
        )

    root_resolved = ROOT.resolve()
    for source_path, target, line, context in local_references:
        candidate = (ROOT / target.removeprefix("./")).resolve()
        source = source_path.relative_to(ROOT)
        if not candidate.is_relative_to(root_resolved):
            failures.append(f"{source}:{line}: {context}={target!r} escapes the repository")
            continue

        if candidate.is_file():
            manifests = [candidate]
        elif candidate.is_dir():
            manifests = [
                manifest
                for manifest in (candidate / "action.yml", candidate / "action.yaml")
                if manifest.is_file()
            ]
        else:
            manifests = []

        if len(manifests) != 1:
            failures.append(
                f"{source}:{line}: {context}={target!r} must resolve to exactly one local "
                "workflow or action manifest"
            )
        elif manifests[0].resolve() not in scanned_sources:
            failures.append(
                f"{source}:{line}: {context}={target!r} resolves to an unscanned local manifest"
            )

    if not workflows:
        failures.append("no workflow files were found; the scanner is looking in the wrong place")
    elif checked == 0:
        failures.append("no external actions were found; the scanner is probably looking in the wrong place")

    for failure in failures:
        print(f"check-action-pins: FAIL — {failure}", file=sys.stderr)
    if failures:
        return 1

    print(
        f"check-action-pins: OK — {checked} external action reference(s) are immutable; "
        f"{len(action_manifests)} local action manifest(s) scanned"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
