#!/usr/bin/env python3
"""Export compact manuscript operands from canonical scientific results.

Paragraph annotations supply semantic selectors, never expected data values.
The extra summaries cover literal claims whose old annotations cited only part
of their evidence. No electoral or coalition accounting is repeated here.
"""
from __future__ import annotations

import argparse
import csv
from fractions import Fraction
from pathlib import Path
from tempfile import NamedTemporaryFile

from validate_prose_provenance import (
    DEFAULT_MANUSCRIPT, DEFAULT_RESULTS, REPOSITORY_ROOT, ProvenanceError,
    parse_blocks, result_key, source_records, validate_provenance,
)

FIELDS = ("record_type", "block", "source", "key", "field", "value", "current_row")
PARTIES = "build/results/accounting/raw/party_accounting_all_years.csv"
CABINETS = "build/results/accounting/raw/cabinet_party_set_accounting.csv"


def literal_summaries(root: Path) -> list[dict]:
    """Small aggregations of existing quantities, with exact sign/rank decisions."""
    def read(relative):
        with (root / relative).open(encoding="utf-8", newline="") as handle:
            return list(csv.DictReader(handle))

    def fraction(value):
        return Fraction(value.replace("//", "/"))

    rows = []

    def add(block, source, key, field, value):
        rows.append(dict(record_type="summary", block=block, source=source, key=key,
                         field=field, value=str(value), current_row=""))

    parties, cabinets = read(PARTIES), read(CABINETS)
    by_year = {}
    for year in sorted({r["election_year"] for r in parties}):
        panel = [r for r in parties if r["election_year"] == year]
        by_year[year] = {r["party"]: r for r in panel}
        for metric, field, operation in (
            ("largest_vote_parties", "v_i", max),
            ("largest_differential_parties", "d_i_exact", max),
            ("smallest_differential_parties", "d_i_exact", min),
        ):
            extreme = operation(fraction(r[field]) for r in panel)
            names = ";".join(sorted(r["party"] for r in panel if fraction(r[field]) == extreme))
            add("party-size-and-differential-ranks", PARTIES, f"election_year={year}", metric, names)
        # These are the literal Figure 1 discussion bands, not the report's bins.
        for band, select in (
            ("above_five_percent", lambda share: share > Fraction(5, 100)),
            ("between_three_and_five_percent", lambda share: Fraction(3, 100) < share < Fraction(5, 100)),
        ):
            selected = [r for r in panel if select(Fraction(int(r["v_i"]), int(r["V"])))]
            key = f"election_year={year}; vote_share_band={band}"
            for metric, value in (
                ("parties", len(selected)),
                ("positive_differential", sum(fraction(r["d_i_exact"]) > 0 for r in selected)),
                ("negative_differential", sum(fraction(r["d_i_exact"]) < 0 for r in selected)),
            ):
                add("party-size-representation-signs", PARTIES, key, metric, value)

    gaps = []
    for cabinet in cabinets:
        panel = by_year[cabinet["election_year"]]
        members = set(cabinet["canonical_membership"].split(";"))
        if not members < panel.keys():
            raise ProvenanceError("Cabinet member/nonmember comparison requires two nonempty known groups")
        shares = {p: Fraction(int(r["v_i"]), int(r["V"])) for p, r in panel.items()}
        member_mean = sum(shares[p] for p in members) / len(members)
        outside = panel.keys() - members
        nonmember_mean = sum(shares[p] for p in outside) / len(outside)
        gaps.append(100 * (member_mean - nonmember_mean))
    source = f"{PARTIES} | {CABINETS}"
    for metric, value in (("configurations", len(gaps)),
                          ("positive_member_nonmember_gaps", sum(gap > 0 for gap in gaps))):
        add("cabinet-member-vote-share-gaps", source, "scope=all", metric, value)
    for metric, value in (("minimum_gap_percentage_points", min(gaps)),
                          ("maximum_gap_percentage_points", max(gaps))):
        add("cabinet-member-vote-share-gaps", source, "scope=all", metric, float(value))
        add("cabinet-member-vote-share-gaps", source, "scope=all", metric + "_exact", value)

    for administration in sorted({a for r in cabinets for a in r["administrations"].split(";")}):
        selected = [r for r in cabinets if administration in r["administrations"].split(";")]
        for metric, value in (("configurations", len(selected)),
                              ("positive_B", sum(fraction(r["B_C_exact"]) > 0 for r in selected)),
                              ("negative_B", sum(fraction(r["B_C_exact"]) < 0 for r in selected))):
            add("cabinet-between-component-by-administration", CABINETS,
                f"administration={administration}", metric, value)
    return rows


def build_results(manuscript: Path, root: Path, *, include_summaries: bool = True) -> list[dict]:
    blocks = parse_blocks(manuscript.read_text(encoding="utf-8"))
    if not blocks:
        raise ProvenanceError("Cannot build manuscript results without semantic selectors")
    records = [dict(record_type="provenance", **r) for r in source_records(blocks, root)]
    if include_summaries:
        records.extend(literal_summaries(root))
    keys = [(r["record_type"], result_key(r)) for r in records]
    if len(keys) != len(set(keys)):
        raise ProvenanceError("Duplicate manuscript-result key")
    return records


def write_results(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ProvenanceError("Manuscript-results output must not be a symlink")
    with NamedTemporaryFile(mode="w", encoding="utf-8", newline="", dir=path.parent,
                            prefix=".manuscript-results-", delete=False) as handle:
        temporary = Path(handle.name)
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(records)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--main-tex", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    manuscript = args.main_tex or root / DEFAULT_MANUSCRIPT
    output = args.output or root / DEFAULT_RESULTS
    if not output.resolve().is_relative_to(root):
        raise ProvenanceError("Results output must stay within the selected project")
    records = build_results(manuscript, root)
    write_results(output, records)
    checked, warnings = validate_provenance(manuscript, root, results=output)
    print(f"Manuscript results: {len(checked)} selected values, {len(records) - len(checked)} literal-claim summaries; {len(warnings)} row-number warnings. {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
