#!/usr/bin/env python3
"""Build deterministic submission archives and verify their current contents."""

from __future__ import annotations

import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


REPO_ROOT = Path(__file__).resolve().parents[1]
REVIEW_ROOT = REPO_ROOT / "writing" / "submission_inversions_review"
MANUSCRIPT_ROOT = REVIEW_ROOT / "manuscript"
MAIN_TEX = MANUSCRIPT_ROOT / "main_rw_again.tex"
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def referenced_assets() -> tuple[list[Path], list[Path]]:
    source = MAIN_TEX.read_text(encoding="utf-8")
    # Ignore comments; a line break may separate the command from its target.
    source = re.sub(r"(?<!\\)(?:\\\\)*%[^\n]*", "", source)
    table_names = sorted(set(re.findall(r"\\input\s*\{([^{}]+\.tex)\}", source)))
    figure_names = sorted(set(re.findall(
        r"\\includegraphics\*?(?:\[[^]]*\])?\s*\{([^{}]+\.(?:pdf|png|jpg|jpeg))\}",
        source,
    )))
    if {"manuscript_values.tex", "accounting_numeric_macros.tex"} & set(table_names):
        raise ValueError("Retired empirical prose macro files cannot enter the submission package.")
    tables = [MANUSCRIPT_ROOT / name for name in table_names]
    figures = [MANUSCRIPT_ROOT / name for name in figure_names]
    return tables, figures


def require_files(paths: list[Path]) -> None:
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing submission asset(s): " + ", ".join(missing))


def manuscript_tex_sources() -> list[Path]:
    # Historical local drafts are not publication inputs.
    tables, _ = referenced_assets()
    return sorted(set([MAIN_TEX, *tables]))


def expected_members(paths: list[Path], source_root: Path | None = None) -> dict[str, Path]:
    members: dict[str, Path] = {}
    for path in paths:
        name = path.relative_to(source_root).as_posix() if source_root else path.name
        if name in members:
            raise ValueError(f"Duplicate submission member: {name}")
        members[name] = path
    return members


def verify_zip(destination: Path, paths: list[Path], *, source_root: Path | None = None) -> None:
    expected = expected_members(paths, source_root)
    with ZipFile(destination) as archive:
        actual = archive.namelist()
        if sorted(actual) != sorted(expected):
            raise ValueError(
                f"Archive membership mismatch in {destination}: "
                f"expected {sorted(expected)}, found {sorted(actual)}"
            )
        for name, path in expected.items():
            if archive.read(name) != path.read_bytes():
                raise ValueError(f"Archive content mismatch in {destination}: {name} != {path}")


def write_deterministic_zip(
    destination: Path, paths: list[Path], *, source_root: Path | None = None,
) -> None:
    require_files(paths)
    members = expected_members(paths, source_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in sorted(members.items()):
            info = ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=9)
    verify_zip(destination, paths, source_root=source_root)


def verify_manuscript_archives(inner: Path, outer: Path) -> None:
    with ZipFile(inner) as first, ZipFile(outer) as second:
        if sorted(first.namelist()) != sorted(second.namelist()):
            raise ValueError("Inner and outer manuscript archives have different members.")
        for name in first.namelist():
            if first.read(name) != second.read(name):
                raise ValueError(f"Inner and outer manuscript archives differ: {name}")


def main() -> int:
    tables, figures = referenced_assets()
    core = [MAIN_TEX, MAIN_TEX.with_suffix(".pdf"), MANUSCRIPT_ROOT / "refs2.bib"]
    manuscript_files = core + tables + figures
    require_files(manuscript_files)
    outputs = [
        (MANUSCRIPT_ROOT / "figures.zip", figures),
        (MANUSCRIPT_ROOT / "tables.zip", tables),
        (MANUSCRIPT_ROOT / "manuscript.zip", manuscript_files),
        (REVIEW_ROOT / "manuscript.zip", manuscript_files),
    ]
    for destination, files in outputs:
        write_deterministic_zip(destination, files, source_root=MANUSCRIPT_ROOT)
    verify_manuscript_archives(MANUSCRIPT_ROOT / "manuscript.zip", REVIEW_ROOT / "manuscript.zip")
    for destination, files in outputs:
        print(f"{destination.relative_to(REPO_ROOT)}: {len(files)} files, contents verified")
    print("Inner and outer manuscript archives: identical contents")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
