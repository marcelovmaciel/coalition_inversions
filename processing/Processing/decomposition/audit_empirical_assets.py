#!/usr/bin/env python3
"""Audit generated paper artifacts and active-manuscript empirical assets.

This script is deliberately independent of the empirical calculations. It
hashes the frozen paper outputs and inventories active manuscript references.
It fails if the paper manifest or active manuscript points at a missing file.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from validate_prose_provenance import ProvenanceError, validate_provenance


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PAPER_HASH_FILENAME = "paper_artifact_hashes.csv"
MANUSCRIPT_REFERENCE_FILENAME = "manuscript_empirical_asset_manifest.csv"
PAPER_HASH_FIELDS = (
    "path",
    "artifact_type",
    "description",
    "rows",
    "columns",
    "bytes",
    "sha256",
)
MANUSCRIPT_REFERENCE_FIELDS = (
    "reference_source",
    "reference_kind",
    "target",
)
MANIFEST_REQUIRED_FIELDS = {
    "path",
    "artifact_type",
    "description",
    "rows",
    "columns",
}
TEX_REFERENCE_RE = re.compile(
    r"\\(?P<kind>input|includegraphics)\*?\s*"
    r"(?:\[[^\]]*\]\s*)?\{(?P<target>[^{}]+)\}",
    flags=re.MULTILINE,
)
URL_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")


class AuditError(RuntimeError):
    """Raised when a final empirical-asset invariant does not hold."""


@dataclass(frozen=True)
class AuditResult:
    paper_records: tuple[dict[str, object], ...]
    manuscript_reference_records: tuple[dict[str, object], ...]
    unreferenced_manuscript_assets: tuple[Path, ...]
    paper_hash_path: Path
    manuscript_reference_path: Path
    provenance_records: tuple[dict[str, object], ...]
    provenance_warnings: tuple[str, ...]


def sha256_and_size(path: Path) -> tuple[int, str]:
    """Return a file's byte size and SHA-256 digest without loading it at once."""

    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(block)
            digest.update(block)
    return size, digest.hexdigest()


def _display_path(path: Path, repository_root: Path | None) -> str:
    resolved = path.resolve()
    if repository_root is not None:
        try:
            return resolved.relative_to(repository_root.resolve()).as_posix()
        except ValueError:
            pass
    return resolved.as_posix()


def _manifest_target(paper_root: Path, manifest_value: str) -> Path:
    relative = Path(manifest_value)
    if relative.is_absolute():
        raise AuditError(
            f"Paper artifact manifest path must be relative, not absolute: "
            f"{manifest_value!r}"
        )

    resolved_root = paper_root.resolve()
    resolved_target = (resolved_root / relative).resolve()
    try:
        resolved_target.relative_to(resolved_root)
    except ValueError as exc:
        raise AuditError(
            f"Paper artifact manifest path escapes its artifact root: "
            f"{manifest_value!r}"
        ) from exc
    return resolved_target


def audit_paper_manifest(manifest_path: Path) -> list[dict[str, object]]:
    """Validate and hash every row listed in the paper artifact manifest."""

    manifest_path = manifest_path.resolve()
    if not manifest_path.is_file():
        raise AuditError(f"Paper artifact manifest is missing: {manifest_path}")

    with manifest_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = set(reader.fieldnames or ())
        missing_fields = sorted(MANIFEST_REQUIRED_FIELDS - fields)
        if missing_fields:
            raise AuditError(
                "Paper artifact manifest is missing required columns: "
                + ", ".join(missing_fields)
            )
        source_rows = list(reader)

    if not source_rows:
        raise AuditError(f"Paper artifact manifest has no artifact rows: {manifest_path}")

    seen: set[str] = set()
    duplicates: set[str] = set()
    missing_files: list[str] = []
    records: list[dict[str, object]] = []
    paper_root = manifest_path.parent

    for row in source_rows:
        relative = (row.get("path") or "").strip()
        if not relative:
            raise AuditError("Paper artifact manifest contains a blank path.")
        if relative in seen:
            duplicates.add(relative)
        seen.add(relative)

        target = _manifest_target(paper_root, relative)
        if not target.is_file():
            missing_files.append(relative)
            continue
        size, digest = sha256_and_size(target)
        records.append(
            {
                "path": relative,
                "artifact_type": row.get("artifact_type", ""),
                "description": row.get("description", ""),
                "rows": row.get("rows", ""),
                "columns": row.get("columns", ""),
                "bytes": size,
                "sha256": digest,
            }
        )

    problems: list[str] = []
    if duplicates:
        problems.append("duplicate paths: " + ", ".join(sorted(duplicates)))
    if missing_files:
        problems.append("missing files: " + ", ".join(sorted(missing_files)))
    if problems:
        raise AuditError(
            "Paper artifact manifest validation failed (" + "; ".join(problems) + ")."
        )

    return sorted(records, key=lambda record: str(record["path"]))


def _strip_tex_comments(text: str) -> str:
    """Blank TeX comments while preserving offsets and line numbers."""

    output: list[str] = []
    for line in text.splitlines(keepends=True):
        comment_at: int | None = None
        for index, character in enumerate(line):
            if character != "%":
                continue
            backslashes = 0
            cursor = index - 1
            while cursor >= 0 and line[cursor] == "\\":
                backslashes += 1
                cursor -= 1
            if backslashes % 2 == 0:
                comment_at = index
                break
        if comment_at is None:
            output.append(line)
            continue
        suffix = line[comment_at:]
        newline = "\n" if suffix.endswith("\n") else ""
        output.append(line[:comment_at] + (" " * (len(suffix) - len(newline))) + newline)
    return "".join(output)


def _resolve_tex_target(source: Path, kind: str, raw_target: str) -> Path | None:
    target = raw_target.strip()
    if not target:
        raise AuditError(f"Blank \\{kind} target in {source}.")
    if URL_SCHEME_RE.match(target):
        return None
    if "\\" in target:
        raise AuditError(
            f"Non-literal \\{kind} target cannot be audited reproducibly in "
            f"{source}: {target!r}"
        )

    expected_suffix = ".tex" if kind == "input" else ".pdf"
    allowed_suffixes = {".tex"} if kind == "input" else {".pdf", ".png", ".jpg", ".jpeg"}
    target_path = Path(target)
    if not target_path.suffix:
        target_path = Path(str(target_path) + expected_suffix)
    elif target_path.suffix.lower() not in allowed_suffixes:
        raise AuditError(
            f"Expected a local {sorted(allowed_suffixes)} target for \\{kind} in "
            f"{source}, found {target!r}."
        )

    if target_path.is_absolute():
        return target_path.resolve()
    return (source.parent / target_path).resolve()


def audit_manuscript_references(
    manuscript_sources: Sequence[Path],
    *,
    repository_root: Path | None = None,
) -> list[dict[str, object]]:
    """Validate and inventory active local asset references in manuscript files."""

    records: list[dict[str, object]] = []
    missing_targets: list[str] = []
    seen_sources: set[Path] = set()

    for source_value in manuscript_sources:
        source = source_value.resolve()
        if source in seen_sources:
            raise AuditError(f"Manuscript source was supplied more than once: {source}")
        seen_sources.add(source)
        if not source.is_file():
            raise AuditError(f"Active manuscript source is missing: {source}")

        text = _strip_tex_comments(source.read_text(encoding="utf-8"))
        for match in TEX_REFERENCE_RE.finditer(text):
            kind = match.group("kind")
            raw_target = match.group("target")
            target = _resolve_tex_target(source, kind, raw_target)
            if target is None:
                continue
            line = text.count("\n", 0, match.start()) + 1
            reference_source = f"{_display_path(source, repository_root)}:{line}"
            if not target.is_file():
                missing_targets.append(
                    f"{reference_source} -> {_display_path(target, repository_root)}"
                )
                continue
            records.append(
                {
                    "reference_source": reference_source,
                    "reference_kind": kind,
                    "target": _display_path(target, repository_root),
                }
            )

    if missing_targets:
        raise AuditError(
            "Active manuscript has missing generated asset target(s):\n- "
            + "\n- ".join(sorted(missing_targets))
        )

    return sorted(
        records,
        key=lambda record: (
            str(record["reference_source"]),
            str(record["reference_kind"]),
            str(record["target"]),
        ),
    )


def find_unreferenced_manuscript_assets(
    generated_directory: Path,
    manuscript_reference_records: Iterable[dict[str, object]],
    *,
    manuscript_sources: Sequence[Path] = (),
    repository_root: Path | None = None,
) -> list[Path]:
    """Return local manuscript renderings not referenced by the audited sources."""

    if not generated_directory.is_dir():
        raise AuditError(
            f"Generated manuscript asset directory is missing: {generated_directory}"
        )

    referenced: set[Path] = set()
    for record in manuscript_reference_records:
        display_target = Path(str(record["target"]))
        if display_target.is_absolute():
            referenced.add(display_target.resolve())
        elif repository_root is not None:
            referenced.add((repository_root / display_target).resolve())
    excluded = {source.resolve() for source in manuscript_sources}

    return sorted(
        (
            candidate.resolve()
            for candidate in generated_directory.rglob("*")
            if candidate.is_file()
            and candidate.suffix.lower() in {".pdf", ".tex", ".png", ".jpg", ".jpeg"}
            and candidate.resolve() not in referenced
            and candidate.resolve() not in excluded
        ),
        key=lambda path: path.as_posix(),
    )


def _write_csv_atomic(
    output_path: Path,
    fieldnames: Sequence[str],
    records: Iterable[dict[str, object]],
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=output_path.parent,
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
            writer.writeheader()
            writer.writerows(records)
        os.replace(temporary_name, output_path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def run_audit(
    *,
    paper_manifest: Path,
    manuscript_sources: Sequence[Path],
    audit_directory: Path,
    repository_root: Path | None = None,
    generated_manuscript_directory: Path | None = None,
    freeze_prose: bool = False,
) -> AuditResult:
    """Write the paper-output hash audit and manuscript reference inventory."""

    paper_records = audit_paper_manifest(paper_manifest)
    manuscript_reference_records = audit_manuscript_references(
        manuscript_sources,
        repository_root=repository_root,
    )
    provenance_records: list[dict[str, object]] = []
    provenance_warnings: list[str] = []
    for source in manuscript_sources:
        if source.name == "main_rw_again.tex" or "PROVENANCE-BEGIN" in source.read_text(encoding="utf-8"):
            try:
                records, warnings = validate_provenance(source, repository_root or REPOSITORY_ROOT)
            except ProvenanceError as exc:
                if not freeze_prose:
                    raise AuditError(f"Prose provenance validation failed: {exc}") from exc
                records, warnings = [], [f"Frozen prose remains stale: {exc}; see STALE_PROSE_REPORT.md"]
            provenance_records.extend(records)
            provenance_warnings.extend(warnings)
    unreferenced: list[Path] = []
    if generated_manuscript_directory is not None:
        unreferenced = find_unreferenced_manuscript_assets(
            generated_manuscript_directory,
            manuscript_reference_records,
            manuscript_sources=manuscript_sources,
            repository_root=repository_root,
        )

    paper_hash_path = audit_directory / PAPER_HASH_FILENAME
    manuscript_reference_path = audit_directory / MANUSCRIPT_REFERENCE_FILENAME
    _write_csv_atomic(paper_hash_path, PAPER_HASH_FIELDS, paper_records)
    _write_csv_atomic(
        manuscript_reference_path,
        MANUSCRIPT_REFERENCE_FIELDS,
        manuscript_reference_records,
    )
    _write_csv_atomic(
        audit_directory / "manuscript_prose_provenance.csv",
        ("block", "source", "key", "row_at_generation", "current_row", "field", "value", "display"),
        provenance_records,
    )
    return AuditResult(
        paper_records=tuple(paper_records),
        manuscript_reference_records=tuple(manuscript_reference_records),
        unreferenced_manuscript_assets=tuple(unreferenced),
        paper_hash_path=paper_hash_path,
        manuscript_reference_path=manuscript_reference_path,
        provenance_records=tuple(provenance_records),
        provenance_warnings=tuple(provenance_warnings),
    )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPOSITORY_ROOT,
        help="Repository root used for defaults and portable output paths.",
    )
    parser.add_argument(
        "--paper-manifest",
        type=Path,
        help="Paper artifact_manifest.csv (default: output/paper/artifact_manifest.csv).",
    )
    parser.add_argument(
        "--main-tex",
        type=Path,
        help="Active manuscript (default: main_rw_again.tex).",
    )
    parser.add_argument(
        "--title-page-tex",
        type=Path,
        help="Active manuscript title_page.tex.",
    )
    parser.add_argument(
        "--audit-dir",
        type=Path,
        help="Output directory for the two audit CSVs.",
    )
    parser.add_argument(
        "--generated-manuscript-dir",
        type=Path,
        help="Directory scanned when --report-unreferenced is supplied.",
    )
    parser.add_argument(
        "--report-unreferenced",
        action="store_true",
        help="Report unreferenced manuscript assets without failing the audit.",
    )
    parser.add_argument("--freeze-prose", action="store_true", help="Audit assets but report stale frozen narrative separately; never edit prose.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    repo_root = args.repo_root.resolve()
    processing_root = repo_root / "processing" / "Processing"
    active_manuscript_dir = (
        repo_root / "writing" / "submission_inversions_review" / "manuscript"
    )
    paper_manifest = args.paper_manifest or (
        processing_root / "output" / "paper" / "artifact_manifest.csv"
    )
    main_tex = args.main_tex or active_manuscript_dir / "main_rw_again.tex"
    title_page_tex = args.title_page_tex or (
        repo_root / "writing" / "submission_inversions_review" / "title_page.tex"
    )
    audit_directory = args.audit_dir or (
        processing_root / "output" / "decomposition" / "audit"
    )
    generated_directory = None
    if args.report_unreferenced:
        generated_directory = args.generated_manuscript_dir or active_manuscript_dir

    try:
        result = run_audit(
            paper_manifest=paper_manifest,
            manuscript_sources=(main_tex, title_page_tex),
            audit_directory=audit_directory,
            repository_root=repo_root,
            generated_manuscript_directory=generated_directory,
            freeze_prose=args.freeze_prose,
        )
    except (AuditError, OSError, UnicodeError, csv.Error) as exc:
        print(f"Empirical asset audit FAILED: {exc}", file=sys.stderr)
        return 1

    print(
        f"Validated {len(result.paper_records)} listed paper artifacts; "
        f"wrote {result.paper_hash_path}"
    )
    print(
        f"Validated {len(result.manuscript_reference_records)} manuscript asset references; "
        f"wrote {result.manuscript_reference_path}"
    )
    print(
        f"Validated {len({r['block'] for r in result.provenance_records})} prose provenance blocks, "
        f"{len(result.provenance_records)} fields; current data rows recorded in "
        f"{audit_directory / 'manuscript_prose_provenance.csv'}"
    )
    for warning in result.provenance_warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    if args.report_unreferenced:
        if result.unreferenced_manuscript_assets:
            print("Unreferenced manuscript assets (non-fatal):")
            for path in result.unreferenced_manuscript_assets:
                print(f"- {_display_path(path, repo_root)}")
        else:
            print("Unreferenced manuscript assets: none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
