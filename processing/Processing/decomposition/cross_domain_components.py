"""Shared, audited coalition components for manuscript and diagnostic figures.

Inputs are the production cabinet/ideology registries and exact party/district
accounting exports. This module deliberately has no report-local dependencies.
The extraction and registry audit were promoted from the cabinet A/B diagnostic.
"""
from __future__ import annotations
from datetime import date, timedelta

import csv
import gzip
import io
import math
import json
from collections import Counter, defaultdict
from fractions import Fraction
from pathlib import Path

import pandas as pd

from scientific_results import CoalitionResults

YEARS = (2014, 2018, 2022)
ATOL = 1e-10


class _Audit:
    def __init__(self):
        self.checks = Counter()
        self.residuals = defaultdict(float)
        self.inputs = set()

    def require(self, ok, label, scope="structural"):
        if not ok:
            raise RuntimeError("CROSS-DOMAIN VALIDATION FAILED: " + label)
        self.checks[scope] += 1

    def exact(self, actual, expected, label):
        self.require(actual == expected, label, "exact")

    def close(self, actual, expected, label, scope="floating"):
        residual = abs(float(actual) - float(expected))
        self.require(math.isfinite(residual) and residual <= ATOL,
                     f"{label}: residual={residual:.17g}, atol={ATOL}, rtol=0", scope)
        self.residuals[scope] = max(self.residuals[scope], residual)

    def read(self, path):
        path = Path(path).resolve()
        self.inputs.add(str(path))
        with path.open(newline="", encoding="utf-8") as handle:
            return list(csv.DictReader(handle))

    def truth(self, value):
        self.require(str(value).lower() in ("true", "false"), "invalid boolean")
        return str(value).lower() == "true"

    def parties(self, value):
        names = tuple(p.strip() for p in value.split(",")) if value.strip() else ()
        self.require(all(names) and len(names) == len(set(names)), "invalid party vector")
        return names


def _fraction(value):
    return Fraction(value.replace("//", "/"))


def _load_accounting(decomposition_root, audit):
    parties = defaultdict(dict)
    totals = {}
    for row in audit.read(decomposition_root / "raw/party_accounting_all_years.csv"):
        year, party = int(row["election_year"]), row["party"]
        audit.require(party not in parties[year], f"duplicate party {year}/{party}")
        V, S = int(row["V"]), int(row["S"])
        audit.require(V > 0 and S > 0, f"{year}: positive national totals")
        audit.exact(totals.setdefault(year, (V, S)), (V, S), f"{year}: consistent national totals")
        values = dict(votes=int(row["v_i"]), seats=int(row["s_i"]))
        audit.require(values["votes"] > 0 and values["seats"] >= 0, f"{year}/{party}: counts")
        for component in ("q_i", "d_i", "A_i", "B_i"):
            values[component] = _fraction(row[component + "_exact"])
            audit.close(values[component], row[component], f"{year}/{party}: {component}", "party_decimal")
        audit.exact(values["q_i"], Fraction(S * values["votes"], V), f"{year}/{party}: quota")
        audit.exact(values["d_i"], values["seats"] - values["q_i"], f"{year}/{party}: differential")
        audit.exact(values["A_i"] + values["B_i"], values["d_i"], f"{year}/{party}: d=A+B")
        audit.close(Fraction(values["seats"], 1) / values["q_i"], row["R_i"],
                    f"{year}/{party}: representation ratio", "party_decimal")
        audit.close(Fraction(values["votes"], V), row["vote_share"],
                    f"{year}/{party}: vote share", "party_decimal")
        parties[year][party] = values
    audit.exact(set(parties), set(YEARS), "accounting election coverage")

    cells = defaultdict(dict)
    districts = defaultdict(dict)
    for row in audit.read(decomposition_root / "raw/party_district_accounting_all_years.csv"):
        year, district, party = int(row["election_year"]), row["electoral_unit"], row["party"]
        audit.require(year in parties and party in parties[year], "district cell in party universe")
        token = district, party
        audit.require(token not in cells[year], f"duplicate district cell {year}/{token}")
        v, s, vd, sd = (int(row[c]) for c in ("v_id", "s_id", "V_d", "S_d"))
        audit.require(v >= 0 and s >= 0 and vd > 0 and sd > 0, f"{year}/{token}: counts")
        audit.exact(districts[year].setdefault(district, (vd, sd)), (vd, sd), "consistent district totals")
        V, S = totals[year]
        p = parties[year][party]
        for actual, col in ((V, "V"), (S, "S"), (p["votes"], "v_i"), (p["seats"], "s_i")):
            audit.exact(actual, int(row[col]), f"{year}/{token}: {col}")
        within = Fraction(sd * v, vd)
        national = Fraction(S * v, V)
        a, b = s - within, within - national
        audit.exact(b, S * (Fraction(sd, S) - Fraction(vd, V)) * Fraction(v, vd),
                    f"{year}/{token}: factored B")
        exact_values = {"within_district_quota": within, "national_quota_contribution": national,
                        "a_id": a, "b_id": b, "b_id_factored": b, "d_id": s - national}
        for column, value in exact_values.items():
            audit.exact(value, _fraction(row[column + "_exact"]), f"{year}/{token}: {column}")
            audit.close(value, row[column], f"{year}/{token}: {column}", "district_decimal")
        cells[year][token] = (v, s, vd, sd, a, b)

    result = {}
    for year in YEARS:
        pp, dd, cc = parties[year], districts[year], cells[year]
        V, S = totals[year]
        audit.exact(S, 513, f"{year}: national seats")
        audit.exact(len(dd), 27, f"{year}: district coverage")
        audit.exact(set(cc), {(d, p) for d in dd for p in pp}, f"{year}: complete district party panel")
        audit.exact(sum(p["votes"] for p in pp.values()), V, f"{year}: national vote closure")
        audit.exact(sum(p["seats"] for p in pp.values()), S, f"{year}: national seat closure")
        for district, (vd, sd) in dd.items():
            audit.exact(sum(cc[district, p][0] for p in pp), vd, f"{year}/{district}: vote closure")
            audit.exact(sum(cc[district, p][1] for p in pp), sd, f"{year}/{district}: seat closure")
        for party, p in pp.items():
            for index, column in ((0, "votes"), (1, "seats"), (4, "A_i"), (5, "B_i")):
                audit.exact(sum(cc[d, party][index] for d in dd), p[column],
                            f"{year}/{party}: district/member {column}")
        for column in ("A_i", "B_i", "d_i"):
            audit.exact(sum(p[column] for p in pp.values()), 0, f"{year}: sum {column}=0")
        result[year] = dict(parties=pp, district=dd, cells=cc, V=V, S=S)
    return result


def _independent_coalition_check(election, names, audit):
    audit.require(set(names) <= set(election["parties"]), "coalition in party universe")
    V, S = election["V"], election["S"]
    votes = seats = 0
    a_district = b_district = Fraction(0)
    for district, (vd, sd) in election["district"].items():
        v = sum(election["cells"][district, p][0] for p in names)
        s = sum(election["cells"][district, p][1] for p in names)
        votes += v
        seats += s
        a_district += s - Fraction(sd * v, vd)
        b_district += Fraction(sd * v, vd) - Fraction(S * v, V)
    a = sum((election["parties"][p]["A_i"] for p in names), Fraction(0))
    b = sum((election["parties"][p]["B_i"] for p in names), Fraction(0))
    q = sum((election["parties"][p]["q_i"] for p in names), Fraction(0))
    audit.require(q >= 0, "nonnegative coalition quota")
    audit.exact(q, Fraction(S * votes, V), "member/direct coalition quota")
    audit.exact(a, a_district, "member/direct district A")
    audit.exact(b, b_district, "member/direct district B")
    d, R = seats - q, Fraction(seats, 1) / q if q else float("nan")
    audit.exact(a + b, d, "coalition d=A+B")
    if q:
        audit.exact(a / q + b / q, R - 1, "coalition normalized identity")
    normalized_a = a / q if q else float("nan")
    normalized_b = b / q if q else float("nan")
    threshold = S // 2 + 1
    return dict(votes=votes, vote_share=Fraction(votes, V), seats=seats,
                q_C=q, d_C=d, A_C=a, B_C=b, R_C=R, r_C=threshold - q,
                A_over_q=normalized_a, B_over_q=normalized_b, A_pct_quota=100 * normalized_a, B_pct_quota=100 * normalized_b,
                inversion=seats >= threshold and 2 * votes < V,
                A_member=a, B_member=b, A_district=a_district, B_district=b_district)


def _coalition_values(results, year, names):
    values = results.exact(year, names)
    for key in ("V", "S", "seat_majority_threshold", "seat_share"):
        values.pop(key)
    # These retained figure columns name two proven equivalent aggregations.
    values.update(A_member=values["A_C"], B_member=values["B_C"],
                  A_district=values["A_C"], B_district=values["B_C"])
    return values


def _universe_path(artifact_root, relative, universe):
    if universe not in ("seat_winning", "all_parties"):
        raise ValueError(f"Unknown ideological universe: {universe}")
    path = artifact_root / relative
    return path if universe == "seat_winning" else path.with_name(path.stem + "_all_parties" + path.suffix)


def _audit_minimal_registry(data, artifact_root, requested_k, audit, universe="seat_winning"):
    registry = [r for r in audit.read(_universe_path(artifact_root, "raw/ideology_k_gap_coalitions.csv", universe))
                if int(r["k"]) in requested_k]
    minimal_file = [r for r in audit.read(_universe_path(artifact_root, "raw/ideology_k_gap_minimal_majorities.csv", universe))
                    if int(r["k"]) in requested_k]
    summaries = [r for r in audit.read(_universe_path(artifact_root, "tables/ideology_k_gap_summary.csv", universe))
                 if int(r["k"]) in requested_k]
    checks = [r for r in audit.read(artifact_root / "diagnostics/ideology_k_gap_checks.csv")
              if r["ideological_universe"] == universe]
    audit.require(all(audit.truth(r["ok"]) for r in checks if int(r["k"]) in requested_k),
                  "existing audited domain checks pass")
    orders = {}
    for year in YEARS:
        rows = audit.read(_universe_path(artifact_root, f"raw/ideology_order_{year}.csv", universe))
        order = [r["party"] for r in sorted(rows, key=lambda r: int(r["ordinal_position"]))]
        full_rows = audit.read(_universe_path(artifact_root, f"raw/ideology_order_{year}.csv", "all_parties"))
        full_order = [r["party"] for r in sorted(full_rows, key=lambda r: int(r["ordinal_position"]))]
        audit.exact(set(full_order), set(data[year]["parties"]), f"{year}: full ideological coverage")
        represented = [p for p in full_order if data[year]["parties"][p]["seats"] > 0]
        expected_order = represented if universe == "seat_winning" else full_order
        audit.exact(order, expected_order, f"{year}/{universe}: exact universe and preserved relative order")
        audit.exact(len(order), len(set(order)), f"{year}/{universe}: unique order")
        orders[year] = order
    groups = defaultdict(list)
    for row in registry:
        year, k = int(row["election"]), int(row["k"])
        audit.require(year in data, "registry election coverage")
        audit.exact(row["ideological_universe"], universe, "explicit registry universe")
        names = audit.parties(row["parties"])
        if universe == "seat_winning":
            audit.require(all(data[year]["parties"][p]["seats"] > 0 for p in names),
                          "no zero-seat primary coalition member")
        lo, hi = int(row["left_index"]), int(row["right_index"])
        order = orders[year]
        audit.require(1 <= lo <= hi <= len(order), "registry span bounds")
        span, omitted = order[lo - 1:hi], row["omitted_party"]
        audit.require(not omitted or (k == 1 and omitted in span[1:-1]), "admissible interior omission")
        audit.exact(tuple(p for p in span if p != omitted), names, "registry ideological span")
        audit.require(row["left_endpoint"] == span[0] and row["right_endpoint"] == span[-1], "registry endpoints")
        audit.exact(row["coalition_id"], "|".join(names), "canonical coalition identifier")
        audit.exact(int(row["gap_count"]), int(bool(omitted)), "actual gap count")
        audit.exact(int(row["party_count"]), len(names), "registry party count")
        election = data[year]
        votes = sum(election["parties"][p]["votes"] for p in names)
        seats = sum(election["parties"][p]["seats"] for p in names)
        threshold = election["S"] // 2 + 1
        q = Fraction(election["S"] * votes, election["V"])
        for actual, column in ((votes, "votes"), (seats, "seats"), (election["V"], "national_vote_total"),
                               (election["S"], "total_seats"), (threshold, "seat_majority_threshold")):
            audit.exact(actual, int(row[column]), "registry " + column)
        for actual, column in ((q, "q_C"), (seats - q, "d_C"), (Fraction(seats, 1) / q, "R_C"),
                               (threshold - q, "r_C"), (Fraction(votes, election["V"]), "vote_share")):
            audit.close(actual, row[column], "registry " + column, "registry_arithmetic")
        inversion = seats >= threshold and 2 * votes < election["V"]
        audit.exact(inversion, audit.truth(row["inversion"]), "registry strict inversion flag")
        mask = sum(1 << order.index(p) for p in names)
        groups[year, k].append((mask, seats, row))
    expected_groups = {(year, k) for year in YEARS for k in requested_k}
    audit.exact(set(groups), expected_groups, "complete year/domain coverage")
    selected = {}
    for (year, k), rows in groups.items():
        n = len(orders[year])
        audit.exact(len(rows), n * (n + 1) // 2 + (math.comb(n, 3) if k else 0),
                    "complete admissible domain cardinality")
        audit.exact(len({m for m, s, r in rows}), len(rows), "no duplicate registry party vectors")
        threshold = data[year]["S"] // 2 + 1
        winners = sorted((m for m, s, r in rows if s >= threshold), key=int.bit_count)
        for mask, seats, row in rows:
            minimal = seats >= threshold and not any(w != mask and (w & mask) == w for w in winners)
            audit.exact(minimal, audit.truth(row["minimal_seat_majority"]), "proper-subset domain-relative minimality")
            audit.exact(minimal and audit.truth(row["inversion"]), audit.truth(row["minimal_inversion"]),
                        "minimal inversion conjunction")
            if minimal:
                selected[year, k, row["coalition_id"]] = row
    file_index = {(int(r["election"]), int(r["k"]), r["coalition_id"]): r for r in minimal_file}
    audit.exact(len(file_index), len(minimal_file), "minimal-file identifiers unique")
    audit.exact(set(selected), set(file_index), "selection exactly equals audited minimal-winning file")
    for token, row in selected.items():
        for column in ("parties", "votes", "seats", "inversion", "minimal_seat_majority", "omitted_party"):
            audit.exact(row[column], file_index[token][column], "minimal file agrees with registry: " + column)
    summary_index = {(int(r["election"]), int(r["k"])): r for r in summaries}
    audit.exact(set(summary_index), expected_groups, "summary year/domain coverage")
    for token, expected in summary_index.items():
        subset = [r for (year, k, cid), r in selected.items() if (year, k) == token]
        audit.exact(len(subset), int(expected["minimal_seat_majority_coalitions"]), "audited minimal-winning count")
        audit.exact(sum(audit.truth(r["inversion"]) for r in subset), int(expected["minimal_inversions"]),
                    "audited minimal-inversion count")
    return list(selected.values()), summary_index, len(registry)


def _validate_float_identities(frame, audit, scope):
    for row in frame.itertuples(index=False):
        audit.close(row.d_C, row.A_C + row.B_C, row.configuration_id + ": d=A+B", scope)
        if row.q_C == 0:
            audit.require(all(math.isnan(v) for v in (row.R_C, row.A_pct_quota, row.B_pct_quota)),
                          "zero-quota ratios must be unavailable")
            continue
        audit.close(row.R_C - 1, row.A_C / row.q_C + row.B_C / row.q_C,
                    row.configuration_id + ": normalized identity", scope)
        audit.close(row.A_pct_quota, 100 * row.A_C / row.q_C, "plotted x", scope)
        audit.close(row.B_pct_quota, 100 * row.B_C / row.q_C, "plotted y", scope)


def build_cross_domain_components(artifact_root: Path, domains=("cabinet", "k=0"), *,
                                  decomposition_root: Path | None = None,
                                  universe="seat_winning", validate_domain=True) -> pd.DataFrame:
    """Return coalition-observation components, with audit metadata in ``attrs``.

    ``artifact_root`` is the production paper-output directory. Exact accounting
    defaults to its sibling ``accounting`` directory. The normal export selects
    canonical compact registries; deep tests additionally reconstruct minimality.
    ``domains`` may also include ``k=1`` for the existing diagnostic report.
    Counts are assertions against audited inputs, never substitutes for extraction.
    """
    artifact_root = Path(artifact_root)
    decomposition_root = (Path(decomposition_root) if decomposition_root is not None
                          else artifact_root.parent / "accounting")
    domains = tuple(domains)
    audit = _Audit()
    audit.require(bool(domains) and len(set(domains)) == len(domains)
                  and set(domains) <= {"cabinet", "k=0", "k=1"}, "valid requested domains")
    data = _load_accounting(decomposition_root, audit)
    results = CoalitionResults(decomposition_root)
    audit.inputs.add(str(results.path.resolve()))
    rows, chronological_periods, registry_rows = [], 0, 0
    unidentified_intervals = []
    bounded_date_periods = 0
    if "cabinet" in domains:
        # Sole analytical registry view, generated from the shared daily set identity.
        source = audit.read(artifact_root / "raw/cabinet_party_sets.csv")
        unavailable_path = artifact_root / "raw/cabinet_unidentified_intervals.csv"
        if unavailable_path.exists():
            unidentified_intervals = audit.read(unavailable_path)
        calendar_path = artifact_root / "raw/cabinet_calendar_status.csv"
        if calendar_path.exists():
            calendar = audit.read(calendar_path)
            bounded_date_periods = sum(any(r.get(c, "").strip() not in ("", "[]", "false", "0")
                                          for c in ("bounded_affiliation_ids", "bounded_service_ids")) for r in calendar)
        for row in source:
            audit.require(row.get("composition_status", "identified") != "unidentified",
                          "unidentified core cannot be supplied as a full cabinet set")
        audit.exact(len({r["cabinet_party_set_id"] for r in source}), len(source),
                    "unique cabinet observations")
        chronological_periods = sum(int(r["analytical_period_count"]) for r in source)
        for row in sorted(source, key=lambda r: (int(r["election_year"]), r["period_start"])):
            year = int(row["election_year"])
            names = tuple(sorted(audit.parties(row["parties"])))
            values = _coalition_values(results, year, names)
            audit.exact(values["inversion"], audit.truth(row["coalition_inversion"]), "cabinet inversion flag")
            audit.exact(data[year]["V"], int(row["national_vote_total"]), "cabinet vote denominator")
            for actual, column in (("votes", "votes"), ("seats", "seats"), ("q_C", "quota"),
                                   ("d_C", "seat_diff"), ("R_C", "representation_ratio"), ("vote_share", "vote_share")):
                if actual == "R_C" and values["q_C"] == 0:
                    audit.require(row[column] in ("", "missing", "NaN", "nan"), "zero-quota registry ratio unavailable")
                else:
                    audit.close(values[actual], row[column], "cabinet registry " + actual, "cabinet_regression")
            period = row["period"]
            rows.append(dict(domain="cabinet", ideological_universe="not_applicable", election=year, configuration_id=f"cabinet/{row['cabinet_party_set_id']}",
                             display_label=row["display_label"], cabinet_periods_if_applicable=row["analytical_period_labels"],
                             source_periods=row["source_periods"], period_start=row["period_start"],
                             period_end=row["period_end"], period_days=int(row["period_days"]),
                             party_set="; ".join(names), repeated_vector_count=int(row["analytical_period_count"]), start_party="", end_party="",
                             omitted_party="", k="", source_coalition_id=row["cabinet_party_set_id"], party_count=len(names),
                             is_strongest_inversion=False, **values))
    requested_k = {int(domain[-1]) for domain in domains if domain.startswith("k=")}
    if requested_k:
        if validate_domain:
            minimals, summaries, registry_rows = _audit_minimal_registry(data, artifact_root, requested_k, audit, universe)
        else:
            minimals = [row for row in audit.read(_universe_path(artifact_root, "raw/ideology_k_gap_minimal_majorities.csv", universe))
                        if int(row["k"]) in requested_k]
            summaries = {(int(row["election"]), int(row["k"])): row for row in
                         audit.read(_universe_path(artifact_root, "tables/ideology_k_gap_summary.csv", universe))
                         if int(row["k"]) in requested_k}
        for row in minimals:
            year, k = int(row["election"]), int(row["k"])
            names = audit.parties(row["parties"])
            values = _coalition_values(results, year, names)
            for column in ("votes", "seats", "q_C", "d_C", "R_C", "vote_share"):
                audit.close(values[column], row[column], "minimal-winning registry " + column, "minimal_regression")
            audit.exact(values["inversion"], audit.truth(row["inversion"]), "plotted ideological inversion")
            rows.append(dict(domain=f"k={k}", ideological_universe=universe, election=year, configuration_id=f'k{k}/{year}/{row["coalition_id"]}',
                             display_label=f'{year} {row["coalition_label"]}', cabinet_periods_if_applicable="",
                             party_set="; ".join(names), repeated_vector_count=1, start_party=row["left_endpoint"],
                             end_party=row["right_endpoint"], omitted_party=row["omitted_party"], k=k,
                             source_coalition_id=row["coalition_id"], party_count=len(names),
                             is_strongest_inversion=False, left_index=int(row["left_index"]),
                             right_index=int(row["right_index"]), gap_count=int(row["gap_count"]),
                             minimal_seat_majority=True, **values))
        if requested_k:
            for year in YEARS:
                for k in requested_k:
                    candidates = [r for r in rows if r["domain"] == f"k={k}" and r["election"] == year and r["inversion"]]
                    if not candidates:
                        continue
                    chosen = min(candidates, key=lambda r: (r["votes"], r["party_count"], r["source_coalition_id"]))
                    audit.exact(chosen["display_label"], f'{year} {summaries[year, k]["strongest_inversion_coalition"]}',
                                "strongest inversion selection")
                    chosen["is_strongest_inversion"] = True
    frame = pd.DataFrame([{c: float(v) if isinstance(v, Fraction) else v for c, v in r.items()} for r in rows])
    frame["vote_share_units"] = "proportion of all valid federal-deputy votes"
    frame["A_over_q_units"] = frame["B_over_q_units"] = "proportion of coalition quota"
    frame["A_pct_quota_units"] = frame["B_pct_quota_units"] = "percent of coalition quota"
    audit.require(not frame.duplicated(["domain", "configuration_id"]).any(), "one row per configuration")
    counts = []
    for domain in domains:
        subset = frame[frame.domain == domain]
        count = dict(domain=domain, configurations=len(subset), inversions=int(subset.inversion.sum()))
        counts.append(count)
        if domain == "cabinet":
            expected = (len(source), sum(audit.truth(r["coalition_inversion"]) for r in source))
        else:
            k = int(domain[-1])
            expected = (sum(int(summaries[y, k]["minimal_seat_majority_coalitions"]) for y in YEARS),
                        sum(int(summaries[y, k]["minimal_inversions"]) for y in YEARS))
        audit.exact((count["configurations"], count["inversions"]), expected, domain + ": audited configuration/inversion counts")
    if "cabinet" in domains:
        cabinet = frame[frame.domain == "cabinet"]
        audit.exact(int(cabinet.repeated_vector_count.sum()), chronological_periods, "all canonical cabinet observations retained")
        audit.exact(set(cabinet.loc[cabinet.inversion, "display_label"]),
                    {r["period"] for r in source if audit.truth(r["coalition_inversion"])}, "distinct cabinet inversion labels")
    _validate_float_identities(frame, audit, "float_identity")
    serialized = pd.read_csv(io.StringIO(frame.to_csv(index=False, float_format="%.17g")), float_precision="round_trip")
    _validate_float_identities(serialized, audit, "serialized_identity")
    frame.attrs["validation"] = dict(checks=dict(audit.checks), max_absolute_residuals=dict(audit.residuals),
                                      absolute_tolerance=ATOL, relative_tolerance=0,
                                      input_paths=sorted(audit.inputs), chronological_periods=chronological_periods,
                                      registry_rows=registry_rows, counts=counts,
                                      unidentified_intervals=unidentified_intervals, bounded_date_periods=bounded_date_periods,
                                      unidentified_periods=len(unidentified_intervals),
                                      unidentified_days=sum(int(r["days"]) for r in unidentified_intervals))
    return frame


def export_ideological_accounting(artifact_root: Path, decomposition_root: Path | None = None):
    """Audit and enrich every admissible k=0/1 coalition in both universes.

    All quantities use one exact election accounting panel. The universe changes
    admissible membership and gaps only; V always includes every party's votes.
    Complete member vectors are written separately for compact replication.
    """
    artifact_root = Path(artifact_root)
    decomposition_root = Path(decomposition_root) if decomposition_root else artifact_root.parent / "accounting"
    audit = _Audit()
    data = _load_accounting(decomposition_root, audit)
    results = CoalitionResults(decomposition_root)
    audit.inputs.add(str(results.path.resolve()))
    coalition_path = artifact_root / "raw/ideology_k_gap_accounting_both_universes.csv"
    party_path = artifact_root / "raw/ideology_k_gap_party_contributions_both_universes.csv.gz"
    coalition_rows = []
    member_rows = 0
    cache = {}
    with gzip.GzipFile(filename=str(party_path), mode="wb", mtime=0) as compressed, \
            io.TextIOWrapper(compressed, newline="", encoding="utf-8") as handle:
        fields = ["election", "ideological_universe", "k", "coalition_id", "parties",
                  "left_index", "right_index", "gap_count", "minimal_seat_majority", "inversion",
                  "party_order", "party", "votes", "seats", "V", "S", "vote_share",
                  "q_i", "d_i", "A_i", "B_i", "q_i_exact", "d_i_exact", "A_i_exact", "B_i_exact"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for universe in ("seat_winning", "all_parties"):
            source = audit.read(_universe_path(artifact_root, "raw/ideology_k_gap_coalitions.csv", universe))
            for source_row in source:
                year = int(source_row["election"])
                names = audit.parties(source_row["parties"])
                election = data[year]
                key = year, names
                if key not in cache:
                    canonical = _coalition_values(results, year, names)
                    cache[key] = canonical
                values = cache[key]
                audit.exact(sum(election["parties"][p]["d_i"] for p in names), values["d_C"], "party differential closure")
                row = dict(source_row)
                for component in ("q_C", "d_C", "R_C", "A_C", "B_C"):
                    row[component] = float(values[component])
                    row[component + "_exact"] = str(values[component])
                row.update(V=election["V"], S=election["S"], A_over_q=float(values["A_over_q"]),
                           B_over_q=float(values["B_over_q"]), vote_denominator="all_valid_federal_deputy_votes")
                coalition_rows.append(row)
                common = {field: source_row[field] for field in fields[:10]}
                for position, party in enumerate(names, 1):
                    p = election["parties"][party]
                    member = dict(common, party_order=position, party=party, votes=p["votes"], seats=p["seats"],
                                  V=election["V"], S=election["S"], vote_share=float(Fraction(p["votes"], election["V"])))
                    for component in ("q_i", "d_i", "A_i", "B_i"):
                        member[component] = float(p[component])
                        member[component + "_exact"] = str(p[component])
                    writer.writerow(member)
                    member_rows += 1
    frame = pd.DataFrame(coalition_rows)
    frame.to_csv(coalition_path, index=False, float_format="%.17g")
    # The compact all-party exact-connected decomposition is generated from the
    # same complete export and can be retained as an appendix replication asset.
    minimals = frame.loc[frame.minimal_seat_majority.astype(str).str.lower().eq("true")]
    minimals.to_csv(artifact_root / "raw/ideology_k_gap_minimal_accounting_both_universes.csv", index=False, float_format="%.17g")
    component_frames = []
    for universe in ("seat_winning", "all_parties"):
        components = build_cross_domain_components(artifact_root, domains=("cabinet", "k=0", "k=1"),
                                                  decomposition_root=decomposition_root, universe=universe, validate_domain=False)
        component_frames.append(components)
    cabinet = [part.loc[part.domain.eq("cabinet")].reset_index(drop=True) for part in component_frames]
    pd.testing.assert_frame_equal(cabinet[0], cabinet[1])
    combined = pd.concat([component_frames[0], component_frames[1].loc[~component_frames[1].domain.eq("cabinet")]], ignore_index=True)
    combined.to_csv(artifact_root / "figure_data/cross_domain_components.csv", index=False, float_format="%.17g")
    report = dict(checks=dict(audit.checks), residuals=dict(audit.residuals), coalition_rows=len(frame),
                  member_rows=member_rows, member_columns=len(fields), universes=["seat_winning", "all_parties"],
                  national_votes={str(y): data[y]["V"] for y in YEARS},
                  input_paths=sorted(audit.inputs))
    (artifact_root / "diagnostics/ideological_accounting_both_universes.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "input_paths"}, indent=2))
    return frame


def validate_full_accounting(artifact_root: Path, decomposition_root: Path | None = None):
    """Independently recheck the complete domain without overwriting scientific outputs."""
    decomposition_root = decomposition_root or artifact_root.parent / "accounting"
    audit = _Audit()
    data = _load_accounting(decomposition_root, audit)
    results = CoalitionResults(decomposition_root)
    seen = set()
    row_count = 0
    for universe in ("seat_winning", "all_parties"):
        _audit_minimal_registry(data, artifact_root, {0, 1}, audit, universe)
        for row in audit.read(_universe_path(artifact_root, "raw/ideology_k_gap_coalitions.csv", universe)):
            year = int(row["election"])
            names = audit.parties(row["parties"])
            row_count += 1
            if (year, names) in seen:
                continue
            seen.add((year, names))
            election = data[year]
            canonical = _coalition_values(results, year, names)
            independent = _independent_coalition_check(election, names, audit)
            for field, value in independent.items():
                if isinstance(value, float) and math.isnan(value):
                    audit.require(math.isnan(canonical[field]), "undefined canonical ratio")
                else:
                    audit.exact(canonical[field], value, "canonical/independent " + field)
    return dict(coalition_rows=row_count, distinct_sets=len(seen), checks=dict(audit.checks),
                max_absolute_residuals=dict(audit.residuals))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact_root", type=Path)
    parser.add_argument("--decomposition-root", type=Path)
    args = parser.parse_args()
    import sys
    sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
    from cabinet_contract import require_current_outputs
    require_current_outputs()
    export_ideological_accounting(args.artifact_root, args.decomposition_root)
