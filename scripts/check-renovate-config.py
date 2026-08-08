#!/usr/bin/env python3
"""Enforce the repository's thin, review-only Renovate contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".github" / "renovate.json5"
CODEOWNERS = ROOT / ".github" / "CODEOWNERS"
PRESET = "github>NWarila/terraform-runner-template//.github/renovate.json5"

EXPECTED_MANAGERS = [
    "github-actions",
    "terraform",
    "pre-commit",
    "pip_requirements",
    "custom.regex",
    "ansible-galaxy",
]
EXPECTED_PACKAGE_RULES = [
    {
        "description": "Require human review for every dependency update",
        "matchPackageNames": ["/.*/"],
        "automerge": False,
    },
    {
        "description": "Group the bounded Python and Galaxy quality manifests",
        "matchManagers": ["pip_requirements", "ansible-galaxy"],
        "matchFileNames": ["requirements-quality.txt", "requirements-quality.yml"],
        "groupName": "quality dependencies",
        "groupSlug": "quality-dependencies",
        "automerge": False,
    },
    {
        "description": "Group workflow action digest updates",
        "matchManagers": ["github-actions"],
        "matchFileNames": [".github/workflows/**"],
        "groupName": "GitHub Actions",
        "groupSlug": "github-actions",
        "automerge": False,
    },
]


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def audit_automerge(value: Any, location: str, failures: list[str]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            if key == "automerge" and child is not False:
                failures.append(f"{child_location} must be false")
            audit_automerge(child, child_location, failures)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            audit_automerge(child, f"{location}[{index}]", failures)


def main() -> int:
    failures: list[str] = []

    if not CONFIG.is_file():
        failures.append(f"missing {CONFIG.relative_to(ROOT)}")
        config: dict[str, Any] = {}
        raw_config = ""
    else:
        raw_config = CONFIG.read_text(encoding="utf-8")
        try:
            loaded = json.loads(raw_config, object_pairs_hook=unique_object)
        except (json.JSONDecodeError, ValueError) as exc:
            failures.append(f"{CONFIG.relative_to(ROOT)} is not duplicate-free JSON5-compatible JSON: {exc}")
            loaded = {}
        config = loaded if isinstance(loaded, dict) else {}
        if not isinstance(loaded, dict):
            failures.append(f"{CONFIG.relative_to(ROOT)} must contain one top-level object")

    expected_keys = {
        "$schema",
        "extends",
        "enabledManagers",
        "automerge",
        "ignorePaths",
        "ansible-galaxy",
        "packageRules",
    }
    if set(config) != expected_keys:
        failures.append(
            f"Renovate top-level keys must be exactly {sorted(expected_keys)!r}; "
            f"got {sorted(config)!r}"
        )
    if config.get("$schema") != "https://docs.renovatebot.com/renovate-schema.json":
        failures.append("Renovate must use the official configuration schema")
    if config.get("extends") != [PRESET]:
        failures.append(f"Renovate must extend exactly the canonical preset {PRESET!r}")
    if config.get("enabledManagers") != EXPECTED_MANAGERS:
        failures.append(
            "enabledManagers must restate the canonical non-mergeable allowlist plus ansible-galaxy"
        )
    if config.get("automerge") is not False:
        failures.append("top-level Renovate automerge must be explicitly false")
    if config.get("ignorePaths") != [".github/*framework-pin"]:
        failures.append("Renovate must ignore exactly .github/*framework-pin")
    if config.get("ansible-galaxy") != {
        "managerFilePatterns": [r"/^requirements-quality\.ya?ml$/"]
    }:
        failures.append("ansible-galaxy must inspect the repository's bounded quality manifest")
    if config.get("packageRules") != EXPECTED_PACKAGE_RULES:
        failures.append("Renovate package rules must retain the exact review-only bounded groups")

    audit_automerge(config, "renovate", failures)
    if "quality-tools.env" in raw_config:
        failures.append("quality-tools.env checksum tuples remain explicitly outside Renovate (TD-007)")

    for dependabot_name in ("dependabot.yml", "dependabot.yaml"):
        dependabot = ROOT / ".github" / dependabot_name
        if dependabot.exists():
            failures.append(f"{dependabot.relative_to(ROOT)} must remain absent; org policy is Renovate-only")

    if not CODEOWNERS.is_file():
        failures.append("missing .github/CODEOWNERS")
    else:
        rules = [
            line.strip()
            for line in CODEOWNERS.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if rules.count("/.github/renovate.json5 @NWarila") != 1:
            failures.append("CODEOWNERS must protect .github/renovate.json5 exactly once")

    for manifest in ("requirements-quality.txt", "requirements-quality.yml"):
        if not (ROOT / manifest).is_file():
            failures.append(f"missing Renovate-managed manifest {manifest}")

    for failure in failures:
        print(f"check-renovate-config: FAIL — {failure}", file=sys.stderr)
    if failures:
        return 1

    print(
        "check-renovate-config: OK — canonical Renovate is review-only, bounded, and framework-pin safe"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
