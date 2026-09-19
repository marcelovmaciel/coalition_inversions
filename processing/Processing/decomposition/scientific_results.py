"""Read the canonical Julia coalition accounting; no electoral arithmetic here."""
from __future__ import annotations

import csv
import gzip
from fractions import Fraction
from pathlib import Path


class CoalitionResults:
    """Exact quantities keyed by election and an unordered member set.

    Domain membership/minimality lives separately in the ideological registry.
    Cabinet dates/status/scenarios live in the public contract and set registry.
    """
    def __init__(self, decomposition_root):
        self.path = Path(decomposition_root) / "raw/coalition_accounting.csv.gz"
        self.rows = {}
        with gzip.open(self.path, "rt", newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                key = self.key(row["election_year"], row["coalition_members"].split(";"))
                if key in self.rows:
                    raise ValueError(f"Duplicate canonical coalition: {key}")
                self.rows[key] = row

    @staticmethod
    def key(year, members):
        names = tuple(sorted(p.strip() for p in members if p.strip()))
        if len(names) != len(set(names)):
            raise ValueError("Coalition members must be unique")
        return int(year), names

    def row(self, year, members):
        return self.rows[self.key(year, members)]

    def exact(self, year, members):
        row = self.row(year, members)
        values = {k: int(row[k]) for k in ("votes", "seats", "V", "S", "seat_majority_threshold")}
        for key in ("q_C", "d_C", "r_C", "A_C", "B_C", "R_C",
                    "A_over_q", "B_over_q", "A_pct_quota", "B_pct_quota"):
            text = row[key + "_exact"]
            values[key] = Fraction(text.replace("//", "/")) if text else float("nan")
        for key in ("vote_share", "seat_share"):
            values[key] = Fraction(row[key + "_exact"].replace("//", "/"))
        values["inversion"] = row["inversion"] == "true"
        return values
