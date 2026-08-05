#!/usr/bin/env python3
"""Validate local documentation links, path references, and index coverage."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
SKIP_PARTS = {
    ".git",
    ".opencode",
    "build",
    "node_modules",
    "third_party",
    "__pycache__",
}
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
REFERENCE_LINK_RE = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)", re.MULTILINE)
PATH_CODE_RE = re.compile(r"`([^`\n]+\.(?:md|pdf|html))(?:#[^`]*)?`")
ROOT_PREFIXES = ("AGENTS", "README", "docs/", "fpga/", "rtl/", "sim/")


def source_markdown_files() -> list[Path]:
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if not any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts)
    )


def local_link_target(raw: str, source: Path) -> Path | None:
    target = raw.strip().removeprefix("<").removesuffix(">")
    if target.startswith(("http://", "https://", "mailto:", "#")):
        return None
    target = unquote(target.split("#", 1)[0].split("?", 1)[0])
    if not target:
        return None
    return (source.parent / target).resolve()


def main() -> int:
    files = source_markdown_files()
    failures: list[str] = []
    inbound: set[Path] = set()

    for source in files:
        text = source.read_text(encoding="utf-8")
        raw_links = LINK_RE.findall(text) + REFERENCE_LINK_RE.findall(text)
        for raw in raw_links:
            target = local_link_target(raw, source)
            if target is None:
                continue
            if not target.exists():
                failures.append(
                    f"{source.relative_to(ROOT)}: broken local link: {raw}"
                )
            elif target != source.resolve():
                inbound.add(target)

        if source.relative_to(ROOT).parts[:2] == ("docs", "archive"):
            continue
        for raw in PATH_CODE_RE.findall(text):
            if "*" in raw or "<" in raw or raw.startswith(("http://", "https://")):
                continue
            candidates = [(source.parent / raw).resolve()]
            if raw.startswith(ROOT_PREFIXES):
                candidates.append((ROOT / raw).resolve())
            if not any(path.exists() for path in candidates):
                failures.append(
                    f"{source.relative_to(ROOT)}: unresolved path in code span: {raw}"
                )

    for document in sorted((ROOT / "docs").rglob("*.md")):
        if document.resolve() not in inbound:
            failures.append(
                f"{document.relative_to(ROOT)}: not linked from another Markdown file"
            )

    if failures:
        print("Documentation check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(
        f"PASS: documentation links, path references, and index coverage "
        f"({len(files)} Markdown files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
