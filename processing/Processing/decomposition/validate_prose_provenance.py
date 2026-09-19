#!/usr/bin/env python3
"""Validate paragraph-local LaTeX provenance against semantically keyed CSV rows.

Row numbers are 1-based DATA rows: the header is excluded. They are navigation
hints only. Numeric fields compare as exact decimals (no rounding tolerance);
other fields and all semantic keys compare as strings. Optional display entries
are literal, whitespace-normalized matches in the preceding paragraph, not NLP.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MANUSCRIPT = Path("writing/submission_inversions_review/manuscript/main_rw_again.tex")
DEFAULT_RESULTS = Path("build/results/manuscript_results.csv")
MARKER = re.compile(r"^\s*% PROVENANCE-(BEGIN|END) ([a-z0-9]+(?:-[a-z0-9]+)*)\s*$")
EMPIRICAL_MACRO = re.compile(r"\\(?:Ideology|Cabinet|Party|District|Empirical|Acct)[A-Za-z]+\b")


class ProvenanceError(ValueError):
    """A malformed block or an unsupported empirical claim."""


@dataclass
class SourceRow:
    source: str
    key: dict[str, str] = field(default_factory=dict)
    row_at_generation: int = 0
    fields: dict[str, str] = field(default_factory=dict)
    display: dict[str, str] = field(default_factory=dict)


@dataclass
class Block:
    identifier: str
    line: int
    paragraph: str
    rows: list[SourceRow] = field(default_factory=list)


def uncomment(text: str) -> str:
    # An odd run of backslashes escapes a percent sign in TeX.
    return "\n".join(re.split(r"(?<!\\)(?:\\\\)*%", line, maxsplit=1)[0]
                     for line in text.splitlines())


def parse_key(value: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in value.split(";"):
        name, sep, raw = item.strip().partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_]\w*", name) or name in result:
            raise ProvenanceError(f"Malformed or duplicate semantic key: {value!r}")
        result[name] = raw.strip()
    return result


def parse_blocks(text: str) -> list[Block]:
    lines = text.splitlines()
    blocks: list[Block] = []
    active: Block | None = None
    source = ""
    row: SourceRow | None = None
    section = ""
    row_indent = 0
    seen: set[str] = set()
    for number, line in enumerate(lines, 1):
        marker = MARKER.fullmatch(line)
        if "PROVENANCE-BEGIN" in line or "PROVENANCE-END" in line:
            if marker is None:
                raise ProvenanceError(f"Line {number}: malformed provenance marker")
            kind, identifier = marker.groups()
            if kind == "BEGIN":
                if active is not None or identifier in seen:
                    raise ProvenanceError(f"Line {number}: nested/duplicate block {identifier}")
                end = number - 1
                while end and not lines[end - 1].strip():
                    end -= 1
                start = end
                while start and lines[start - 1].strip():
                    start -= 1
                paragraph = uncomment("\n".join(lines[start:end])).strip()
                if not paragraph:
                    raise ProvenanceError(f"Line {number}: provenance has no preceding paragraph")
                active = Block(identifier, number, paragraph)
                source, row, section = "", None, ""
                seen.add(identifier)
            else:
                if active is None or active.identifier != identifier:
                    raise ProvenanceError(f"Line {number}: unmatched end {identifier}")
                if row is None or not active.rows or any(not r.key or not r.row_at_generation or not r.fields
                                          for r in active.rows):
                    raise ProvenanceError(f"{identifier}: every row needs source, key, row_at_generation and fields")
                for r in active.rows:
                    if not r.display.keys() <= r.fields.keys():
                        raise ProvenanceError(f"{identifier}: display field is absent from fields")
                blocks.append(active)
                active = None
            continue
        if active is None:
            continue
        if not line.startswith("% "):
            raise ProvenanceError(f"Line {number}: non-comment or blank line inside {active.identifier}")
        payload = line[2:]
        indent = len(payload) - len(payload.lstrip())
        name, separator, value = payload.strip().partition(":")
        value = value.strip()
        if not separator:
            raise ProvenanceError(f"Line {number}: expected name: value")
        if name == "note" and indent == 0 and value:
            continue
        if re.fullmatch(r"source(?:\[\d+\])?", name) and indent == 0:
            if not value or (source and (row is None or not row.fields)):
                raise ProvenanceError(f"Line {number}: empty/unused source")
            source, row, section = value, None, ""
            continue
        if re.fullmatch(r"row(?:\[\d+\])?", name) and indent == 0 and not value:
            if not source:
                raise ProvenanceError(f"Line {number}: row precedes source")
            row = SourceRow(source)
            active.rows.append(row)
            row_indent, section = 2, ""
            continue
        # The single-row form may put key/fields directly below source.
        if name == "key" and indent == 0 and row is None and source:
            row = SourceRow(source)
            active.rows.append(row)
            row_indent = 0
        if row is None:
            raise ProvenanceError(f"Line {number}: expected source and row/key")
        if indent == row_indent:
            section = ""
            if name == "key" and not row.key:
                row.key = parse_key(value)
                continue
            if name == "row_at_generation" and not row.row_at_generation and re.fullmatch(r"[1-9]\d*", value):
                row.row_at_generation = int(value)
                continue
            if name in ("fields", "display") and not value and not getattr(row, name):
                section = name
                continue
        if section and indent == row_indent + 2 and re.fullmatch(r"[A-Za-z_]\w*", name):
            target = getattr(row, section)
            if name in target or (section == "display" and not value):
                raise ProvenanceError(f"Line {number}: duplicate/empty {section} entry {name}")
            target[name] = value
            continue
        raise ProvenanceError(f"Line {number}: malformed entry or indentation: {payload!r}")
    if active is not None:
        raise ProvenanceError(f"Unclosed provenance block {active.identifier} at line {active.line}")
    return blocks


def same_value(recorded: str, current: str) -> bool:
    if recorded == current:
        return True
    try:
        left, right = Decimal(recorded), Decimal(current)
        return left.is_finite() and right.is_finite() and left == right
    except InvalidOperation:
        return False


def source_records(blocks: list[Block], repository_root: Path) -> list[dict[str, object]]:
    """Extract current scientific values; annotated expected values are never inputs."""
    root = repository_root.resolve()
    cache: dict[str, tuple[list[str], list[dict[str, str]]]] = {}
    records: list[dict[str, object]] = []
    for block in blocks:
        for reference in block.rows:
            path = (root / reference.source).resolve()
            if Path(reference.source).is_absolute() or not path.is_relative_to(root) or path.suffix != ".csv":
                raise ProvenanceError(f"{block.identifier}: source must be a repository-relative CSV")
            if reference.source not in cache:
                if not path.is_file():
                    raise ProvenanceError(f"{block.identifier}: missing source {reference.source}")
                with path.open(encoding="utf-8-sig", newline="") as handle:
                    reader = csv.DictReader(handle)
                    fields = reader.fieldnames or []
                    if not fields or len(fields) != len(set(fields)):
                        raise ProvenanceError(f"{block.identifier}: missing/duplicate CSV header")
                    rows = list(reader)
                    if any(None in r or None in r.values() for r in rows):
                        raise ProvenanceError(f"{block.identifier}: malformed CSV record")
                    cache[reference.source] = (fields, rows)
            fields, rows = cache[reference.source]
            missing = (reference.key.keys() | reference.fields.keys()) - set(fields)
            if missing:
                raise ProvenanceError(f"{block.identifier}: unknown CSV field(s) {sorted(missing)} in {reference.source}")
            matches = [(n, r) for n, r in enumerate(rows, 1)
                       if all(r[k] == v for k, v in reference.key.items())]
            key = "; ".join(f"{k}={v}" for k, v in reference.key.items())
            if len(matches) != 1:
                raise ProvenanceError(f"{block.identifier}: key [{key}] resolves to {len(matches)} rows in {reference.source}; expected exactly one")
            current_row, observation = matches[0]
            for name in reference.fields:
                records.append(dict(block=block.identifier, source=reference.source, key=key,
                                    current_row=current_row, field=name, value=observation[name]))
    return records


def result_key(record: dict) -> tuple:
    return (record["block"], record["source"], tuple(sorted(parse_key(record["key"]).items())), record["field"])


def compact_records(path: Path) -> list[dict[str, str]]:
    """Load compact results without opening any exhaustive scientific output."""
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"record_type", "block", "source", "key", "field", "value", "current_row"}
        if set(reader.fieldnames or []) != required:
            raise ProvenanceError(f"Invalid manuscript-results schema in {path}")
        records = list(reader)
    if any(None in row or None in row.values() for row in records):
        raise ProvenanceError(f"Malformed manuscript-results row in {path}")
    if any(row["record_type"] not in ("provenance", "summary") for row in records):
        raise ProvenanceError(f"Unknown manuscript-results record type in {path}")
    return [row for row in records if row["record_type"] == "provenance"]


def validate_provenance(manuscript: Path, repository_root: Path, *, require_blocks: bool = True,
                        results: Path | None = None
                        ) -> tuple[list[dict[str, object]], list[str]]:
    text = manuscript.read_text(encoding="utf-8")
    blocks = parse_blocks(text)
    if require_blocks and not blocks:
        raise ProvenanceError(f"No provenance blocks in {manuscript}")
    stale = sorted(set(EMPIRICAL_MACRO.findall(uncomment(text))))
    if stale or re.search(r"\\input\{(?:manuscript_values|accounting_numeric_macros)\.tex\}", uncomment(text)):
        raise ProvenanceError(f"Retired empirical prose macro layer in {manuscript}: {stale}")
    observations = compact_records(results) if results is not None else source_records(blocks, repository_root)
    indexed = {}
    for record in observations:
        token = result_key(record)
        if results is not None and token in indexed:
            raise ProvenanceError(f"Duplicate manuscript-result key: {token}")
        indexed[token] = record
    expected = {(block.identifier, ref.source, tuple(sorted(ref.key.items())), name)
                for block in blocks for ref in block.rows for name in ref.fields}
    if set(indexed) != expected:
        raise ProvenanceError("Manuscript-results selectors differ from the current provenance blocks; regenerate results")
    records: list[dict[str, object]] = []
    warnings: list[str] = []
    for block in blocks:
        paragraph = " ".join(block.paragraph.split())
        for reference in block.rows:
            key = "; ".join(f"{k}={v}" for k, v in reference.key.items())
            selected = {name: indexed[block.identifier, reference.source, tuple(sorted(reference.key.items())), name]
                        for name in reference.fields}
            row_numbers = {int(row["current_row"]) for row in selected.values()}
            if len(row_numbers) != 1 or min(row_numbers) < 1:
                raise ProvenanceError(f"{block.identifier}: inconsistent manuscript-result source rows")
            current_row = row_numbers.pop()
            if current_row != reference.row_at_generation:
                warnings.append(f"{block.identifier}: {reference.source} [{key}] is now data row {current_row}; row_at_generation={reference.row_at_generation} is stale")
            for name, recorded in reference.fields.items():
                actual = selected[name]["value"]
                if not same_value(recorded, actual):
                    raise ProvenanceError(f"{block.identifier}: {reference.source} [{key}], current data row {current_row}, {name}: recorded {recorded!r}, CSV {actual!r}")
                display = reference.display.get(name, "")
                if display and not re.search(r"(?<!\w)" + re.escape(" ".join(display.split())) + r"(?!\w)", paragraph):
                    raise ProvenanceError(f"{block.identifier}: display {display!r} for {name} is absent from the immediately preceding paragraph")
                records.append(dict(block=block.identifier, source=reference.source, key=key,
                                    row_at_generation=reference.row_at_generation,
                                    current_row=current_row, field=name, value=actual, display=display))
    return records, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--main-tex", type=Path)
    parser.add_argument("--results", type=Path, help="Compact scientific results (default: build/results/manuscript_results.csv)")
    parser.add_argument("--direct-sources", action="store_true", help="Compare directly with the selected scientific source rows")
    args = parser.parse_args()
    try:
        records, warnings = validate_provenance(args.main_tex or args.repo_root / DEFAULT_MANUSCRIPT, args.repo_root,
            results=None if args.direct_sources else args.results or args.repo_root / DEFAULT_RESULTS)
    except (ProvenanceError, OSError, UnicodeError, csv.Error) as exc:
        print(f"Prose provenance FAILED: {exc}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    for block, source, key, current in dict.fromkeys((r['block'], r['source'], r['key'], r['current_row']) for r in records):
        print(f"{block}: {source} [{key}] -> data row {current}")
    print(f"Validated {len({r['block'] for r in records})} provenance blocks, {len(records)} fields; {len(warnings)} row-number warnings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
