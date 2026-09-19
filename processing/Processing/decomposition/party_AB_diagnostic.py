#!/usr/bin/env python3
"""Rebuild the combined party/coalition accounting diagnostic without asset sync.

Run from any directory after the maintained Julia decomposition has completed.
Only the diagnostic outputs are replaced, after all exact and decimal checks.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import shutil
import subprocess
import tempfile
from collections import Counter, defaultdict
from fractions import Fraction as F
from pathlib import Path
from statistics import mean, median

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PAPER = ROOT / "build/results/domains"
DECOMP = ROOT / "build/results/accounting"
MANUSCRIPT = ROOT / "writing/submission_inversions_review/manuscript/main_rw_again.tex"
YEARS = (2014, 2018, 2022)
ATOL = 1e-10
ZERO = F(1, 10**10)
R = "reinforcement"
W = "within-district dominance with between-district offset"
B = "between-district dominance with within-district offset"
PATTERN_NAMES = {R: "R", W: "W", B: "B"}
CHECKS = Counter()
MAX_RESIDUAL = defaultdict(float)


def require(ok, label):
    if not ok:
        raise RuntimeError("ACCOUNTING VALIDATION FAILED: " + label)


def exact(a, b, label):
    require(a == b, f"{label}: exact residual {a - b}")
    CHECKS["exact"] += 1


def close(a, b, label, scope="floating"):
    residual = abs(float(a) - float(b))
    require(math.isfinite(residual) and residual <= ATOL,
            f"{label}: residual={residual:.17g}, absolute tolerance={ATOL}")
    MAX_RESIDUAL[scope] = max(MAX_RESIDUAL[scope], residual)
    CHECKS[scope] += 1


def read(path):
    with Path(path).open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def truth(value):
    value = str(value).lower()
    require(value in ("true", "false"), f"invalid boolean {value!r}")
    return value == "true"


def parties(value):
    result = tuple(x.strip() for x in value.split(",")) if value.strip() else ()
    require(all(result) and len(result) == len(set(result)), "invalid party set " + value)
    return result


def sign(x):
    return "+" if x > ZERO else "-" if x < -ZERO else "0"


def pattern(a, b, coalition=False):
    sa, sb = sign(a), sign(b)
    if coalition:
        require((sa, sb) != ("-", "-"), "positive inversion with both components negative")
        return {( "+", "+"): R, ("+", "-"): W, ("-", "+"): B}.get(
            (sa, sb), f"near-zero component: A{sa} B{sb}")
    return f"A{sa} B{sb}"


def substantial_offset(a, b):
    # Avoid dividing by the potentially tiny net differential.
    return a * b < 0 and min(abs(a), abs(b)) >= F(1, 4) and min(abs(a), abs(b)) >= max(abs(a), abs(b)) / 5


def hash_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def load_party_data(panel_path):
    cells = defaultdict(dict)
    for row in read(panel_path):
        year = int(row["election"])
        key = row["district"], row["party"]
        require(key not in cells[year], f"duplicate district cell {year}/{key}")
        cells[year][key] = tuple(int(row[c]) for c in ("votes", "seats", "district_votes", "district_seats"))
    require(set(cells) == set(YEARS), "election coverage")
    baseline = {(int(r["election_year"]), r["party"]): r for r in read(PAPER / "raw/party_seat_differentials_all_years.csv")}
    result = {}
    for year, panel in cells.items():
        names = sorted({p for d, p in panel})
        districts = sorted({d for d, p in panel})
        require(len(districts) == 27 and len(panel) == 27 * len(names), f"{year}: incomplete panel")
        require(len(names) == {2014: 32, 2018: 35, 2022: 32}[year], f"{year}: party coverage")
        require(set((year, p) for p in names) == {k for k in baseline if k[0] == year}, f"{year}: national party universe")
        V = sum(v for v, s, vd, sd in panel.values())
        S = sum(s for v, s, vd, sd in panel.values())
        exact(S, 513, f"{year}: total seats")
        district = {}
        for d in districts:
            rows = [panel[d, p] for p in names]
            vd, sd = rows[0][2:]
            require(vd > 0 and sd > 0 and all(v >= 0 and s >= 0 and (vdd, sdd) == (vd, sd)
                    for v, s, vdd, sdd in rows), f"{year}/{d}: primitive counts")
            exact(sum(r[0] for r in rows), vd, f"{year}/{d}: vote closure")
            exact(sum(r[1] for r in rows), sd, f"{year}/{d}: seat closure")
            district[d] = vd, sd
            aa, bb = [], []
            for p, (v, s, _, _) in zip(names, rows):
                a = s - F(sd * v, vd)
                b = F(sd * v, vd) - F(S * v, V)
                exact(b, S * (F(sd, S) - F(vd, V)) * F(v, vd), f"{year}/{d}/{p}: factored B")
                aa.append(a)
                bb.append(b)
            exact(sum(aa), 0, f"{year}/{d}: sum a")
            exact(sum(bb), sd - F(S * vd, V), f"{year}/{d}: sum b")
        pp = {}
        for p in names:
            v = sum(panel[d, p][0] for d in districts)
            s = sum(panel[d, p][1] for d in districts)
            require(v > 0, f"{year}/{p}: positive valid votes required")
            q = F(S * v, V)
            a = sum(panel[d, p][1] - F(district[d][1] * panel[d, p][0], district[d][0]) for d in districts)
            b = sum(F(district[d][1] * panel[d, p][0], district[d][0]) - F(S * panel[d, p][0], V) for d in districts)
            delta = s - q
            exact(a + b, delta, f"{year}/{p}: d=A+B")
            exact(F(s, 1) / q, 1 + delta / q, f"{year}/{p}: R")
            row = dict(election=year, party=p, votes=v, vote_share=F(v, V), seats=s, q_i=q,
                       d_i=delta, R_i=F(s, 1) / q, A_i=a, B_i=b,
                       sign_A_i=sign(a), sign_B_i=sign(b), sign_d_i=sign(delta),
                       component_pattern=pattern(a, b),
                       classification={("+", "+"): "reinforcement", ("+", "-"): "within-positive / between-offset",
                                       ("-", "+"): "between-positive / within-offset", ("-", "-"): "both negative"}.get((sign(a), sign(b)), "near-zero component"),
                       strong_reinforcement=(a * b > 0 and min(abs(a), abs(b)) >= 1),
                       substantial_offset=substantial_offset(a, b),
                       large_countervailing_component=(a*b < 0 and min(abs(a), abs(b)) >= 1),
                       offset_cancellation_fraction=1-abs(delta)/(abs(a)+abs(b)) if a or b else F(0),
                       d_sign_differs_from_A=sign(delta) != sign(a),
                       d_sign_differs_from_B=sign(delta) != sign(b),
                       A_over_q=a/q, B_over_q=b/q,
                       accounting_qualification=("ex post accounting attribution; proportional electoral coalitions pooled lists"
                          if year != 2022 else "ex post accounting attribution; federation members competed through pooled lists"))
            source = baseline[year, p]
            exact(v, int(source["votes"]), f"{year}/{p}: baseline votes")
            exact(s, int(source["seats"]), f"{year}/{p}: baseline seats")
            exact(V, int(source["national_vote_total"]), f"{year}/{p}: baseline V")
            for col, old in (("q_i", "quota"), ("d_i", "seat_diff"), ("R_i", "representation_ratio"), ("vote_share", "vote_share")):
                close(row[col], source[old], f"{year}/{p}: baseline {col}", "baseline")
            pp[p] = row
        for comp in ("A_i", "B_i", "d_i"):
            exact(sum(p[comp] for p in pp.values()), 0, f"{year}: sum {comp}")
        result[year] = dict(parties=pp, cells=panel, district=district, V=V, S=S)
    # The previously generated accounting panel is a regression check, not an input to the calculation.
    for r in read(DECOMP / "raw/party_accounting_all_years.csv"):
        row = result[int(r["election_year"])]["parties"][r["party"]]
        for comp in ("A_i", "B_i", "d_i", "q_i", "R_i"):
            close(row[comp], r[comp], f"saved accounting {r['election_year']}/{r['party']}/{comp}", "baseline")
    return result


def direct_coalition(data, names):
    require(set(names) <= set(data["parties"]), "coalition outside party universe")
    V, S = data["V"], data["S"]
    vv = ss = 0
    a = b = F(0)
    for d, (vd, sd) in data["district"].items():
        v = sum(data["cells"][d, p][0] for p in names)
        s = sum(data["cells"][d, p][1] for p in names)
        vv += v
        ss += s
        a += s - F(sd * v, vd)
        b += F(sd * v, vd) - F(S * v, V)
    q = F(S * vv, V)
    delta = ss - q
    exact(a + b, delta, "coalition direct d=A+B")
    for col, value in (("A_i", a), ("B_i", b), ("d_i", delta)):
        exact(sum(data["parties"][p][col] for p in names), value, "coalition member sum " + col)
    return dict(votes=vv, vote_share=F(vv, V), seats=ss, q_C=q, d_C=delta, A_C=a, B_C=b,
                R_C=F(ss, 1)/q if q else "", r_C=257-q)


def validate_registry(data):
    all_domains = read(PAPER / "raw/ideology_k_gap_coalitions_all_parties.csv")
    orders = {}
    for year in YEARS:
        source_order = sorted(read(PAPER / f"raw/ideology_order_{year}_all_parties.csv"), key=lambda r: int(r['ordinal_position']))
        order = [r['party'] for r in source_order]
        require(len(order) == len(set(order)) and set(order) == set(data[year]['parties']), 'ideology-order coverage')
        orders[year] = order
    cached = {}
    groups = defaultdict(list)
    for source in all_domains:
        year, k = int(source["election"]), int(source["k"])
        names = parties(source["parties"])
        left, right = int(source['left_index']), int(source['right_index'])
        span = orders[year][left-1:right]
        omitted = source['omitted_party']
        require(1 <= left <= right <= len(orders[year]), 'ideological endpoints')
        require(source['left_endpoint'] == span[0] and source['right_endpoint'] == span[-1], 'endpoint labels')
        require(not omitted or (k == 1 and omitted in span[1:-1]), 'omitted party must be interior')
        require(tuple(p for p in span if p != omitted) == names, 'party set differs from authoritative ideology span')
        exact(int(source['gap_count']), int(bool(omitted)), 'actual gap count')
        key = year, frozenset(names)
        if key not in cached:
            cached[key] = direct_coalition(data[year], names)
        values = cached[key]
        for comp in ("votes", "seats"):
            exact(values[comp], int(source[comp]), f"registry {key}: {comp}")
        for comp in ("vote_share", "q_C", "d_C", "R_C", "r_C"):
            close(values[comp], source[comp], f"registry {key}: {comp}", "baseline")
        inv = values["seats"] >= 257 and 2*values["votes"] < data[year]["V"]
        exact(inv, truth(source["inversion"]), "registry inversion flag")
        exact(truth(source["minimal_inversion"]), inv and truth(source["minimal_seat_majority"]), "minimal inversion conjunction")
        groups[year, k].append((frozenset(names), source))
    for (year, k), rows in groups.items():
        n = len(data[year]["parties"])
        exact(len(rows), n*(n+1)//2 + (math.comb(n, 3) if k else 0), "domain cardinality")
        require(len({s for s, r in rows}) == len(rows), "duplicate domain coalition")
        winners = [s for s, r in rows if int(r["seats"]) >= 257]
        # Independently test domain-relative minimality against every winning proper subset.
        for member_set, r in rows:
            minimal = int(r["seats"]) >= 257 and not any(w < member_set for w in winners)
            exact(minimal, truth(r["minimal_seat_majority"]), "proper-set minimality")
    # Consume the canonical cabinet observations without a second deduplication.
    cabinet_source = read(PAPER / "raw/cabinet_party_sets.csv")
    require(len({r["cabinet_party_set_id"] for r in cabinet_source}) == len(cabinet_source), "unique cabinet observation registry")
    cabinets = []
    for source in cabinet_source:
        year = int(source["election_year"])
        names = parties(source["parties"])
        values = direct_coalition(data[year], names)
        inv = values["seats"] >= 257 and 2*values["votes"] < data[year]["V"]
        exact(inv, truth(source["coalition_inversion"]), "cabinet inversion flag")
        for c in ("votes", "seats"):
            exact(values[c], int(source[c]), f"cabinet {source['period']}: {c}")
        for c, old in (("d_C", "seat_diff"), ("q_C", "quota"), ("vote_share", "vote_share")):
            close(values[c], source[old], f"cabinet {source['period']}: {c}", "baseline")
        if inv:
            cabinets.append(source)
    CHECKS["cabinet_inversions"] = len(cabinets)
    cases = []
    for source in cabinets:
        year = int(source["election_year"])
        period = source["period"]
        cases.append(dict(inversion_id=f"cabinet/{source['cabinet_party_set_id']}", election=year,
                          domain="cabinet", k="", period=period,
                          period_ranges=source["observation_intervals"],
                          period_days=int(source["period_days"]), source_periods=source["source_periods"],
                          coalition="Cabinet " + period, members=parties(source["parties"]), omitted_party="",
                          source_coalition_id=source["cabinet_party_set_id"],
                          is_main_focal=True, is_strongest_k1=False))
    for r in all_domains:
        if not truth(r["minimal_inversion"]):
            continue
        year, k = int(r["election"]), int(r["k"])
        cases.append(dict(inversion_id=f"k{k}/{year}/{r['left_index']}-{r['right_index']}" + (f"/omit-{r['omitted_party']}" if r['omitted_party'] else ""),
                          election=year, domain=f"k={k} minimal ideological", k=k, period="", period_ranges="",
                          period_days="", source_periods="",
                          coalition=r["coalition_label"], members=parties(r["parties"]), omitted_party=r["omitted_party"],
                          source_coalition_id=r["coalition_id"], is_main_focal=k == 0, is_strongest_k1=False))
    for year in YEARS:
        for k in (0, 1):
            pool = [c for c in cases if c["election"] == year and c["k"] == k]
            exact(len(pool), {(2014, 0):4, (2018, 0):0, (2022, 0):2, (2014, 1):43, (2018, 1):24, (2022, 1):17}[year, k], "minimal inversion count")
    summaries = read(PAPER / "tables/ideology_k_gap_summary_all_parties.csv")
    for c in cases:
        c.update(direct_coalition(data[c["election"]], c["members"]))
    for year in YEARS:
        pool = [c for c in cases if c["election"] == year and c["k"] == 1]
        chosen = min(pool, key=lambda c: (-c["r_C"], len(c["members"]), c["source_coalition_id"]))
        chosen["is_strongest_k1"] = True
        expected = next(r for r in summaries if int(r["election"]) == year and r["k"] == "1")
        require(chosen["coalition"] == expected["strongest_inversion_coalition"], "strongest-case registry")
    # Match the existing coalition A/B decomposition by exact party set.
    old = {(int(r["election_year"]), frozenset(parties(r["coalition_parties"]))): r
           for r in read(DECOMP / "all_parties/raw/accounting_all_inversion_decomposition.csv")}
    for c in cases:
        if c["is_main_focal"]:
            r = old[c["election"], frozenset(c["members"])]
            for comp in ("A_C", "B_C", "d_C"):
                close(c[comp], r[comp], c["inversion_id"] + ": prior " + comp, "baseline")
    CHECKS["domain_rows"] = len(all_domains)
    CHECKS["unique_domain_configurations"] = len(cached)
    CHECKS["cabinet_party_sets"] = len(cabinet_source)
    return cases


def augment_cases(data, cases):
    member_rows = []
    for c in cases:
        pp = [data[c["election"]]["parties"][p] for p in c["members"]]
        c["classification"] = pattern(c["A_C"], c["B_C"], coalition=True)
        c["component_pattern"] = pattern(c["A_C"], c["B_C"])
        require(c["d_C"] > 0, "inversion must have d_C>0")
        c["party_count"] = len(pp)
        for comp in ("A", "B", "d"):
            col = comp + "_i"
            positive = sorted((p for p in pp if p[col] > ZERO), key=lambda p: (-p[col], p["party"]))
            negative = sorted((p for p in pp if p[col] < -ZERO), key=lambda p: (p[col], p["party"]))
            gp = sum((p[col] for p in pp if p[col] > 0), F(0))
            gn = sum((p[col] for p in pp if p[col] < 0), F(0))
            c[f"gross_positive_{comp}"] = gp
            c[f"gross_negative_{comp}"] = gn
            exact(gp + gn, c[comp + "_C"], c["inversion_id"] + ": gross closure")
            c[f"positive_{comp}_count"] = len(positive)
            c[f"negative_{comp}_count"] = len(negative)
            for direction, rows in (("positive", positive), ("negative", negative)):
                c[f"largest_{direction}_{comp}_party"] = rows[0]["party"] if rows else ""
                c[f"largest_{direction}_{comp}"] = rows[0][col] if rows else F(0)
                c[f"top_two_{direction}_{comp}_parties"] = "; ".join(p["party"] for p in rows[:2])
                denom = gp if direction == "positive" else gn
                c[f"top_two_{direction}_{comp}_share"] = sum((p[col] for p in rows[:2]), F(0))/denom if denom else ""
        c["reinforcing_positive_parties"] = "; ".join(p["party"] for p in pp if p["component_pattern"] == "A+ B+")
        c["reinforcing_negative_parties"] = "; ".join(p["party"] for p in pp if p["component_pattern"] == "A- B-")
        c["offsetting_parties"] = "; ".join(p["party"] for p in pp if p["A_i"] * p["B_i"] < 0)
        c["substantial_offset_parties"] = "; ".join(p["party"] for p in pp if p["substantial_offset"])
        c["focal"] = c["is_main_focal"] or c["is_strongest_k1"]
        for p in pp:
            remaining = tuple(n for n in c["members"] if n != p["party"])
            loo = direct_coalition(data[c["election"]], remaining)
            for comp in ("A", "B", "d"):
                exact(loo[comp + "_C"], c[comp + "_C"] - p[comp + "_i"], "leave-one-out component subtraction")
            majority = loo["seats"] >= 257
            minority = 2 * loo["votes"] < data[c["election"]]["V"]
            member_rows.append({**{key: c[key] for key in ("inversion_id", "election", "domain", "k", "period", "period_ranges", "period_days", "source_periods", "coalition", "omitted_party", "focal", "is_main_focal", "is_strongest_k1")},
                **{key: p[key] for key in ("party", "votes", "vote_share", "seats", "q_i", "d_i", "A_i", "B_i", "R_i", "sign_A_i", "sign_B_i", "sign_d_i", "component_pattern", "strong_reinforcement", "substantial_offset")},
                "coalition_A_C": c["A_C"], "coalition_B_C": c["B_C"], "coalition_d_C": c["d_C"],
                **{"loo_" + key: value for key, value in loo.items()},
                "loo_seat_majority": majority, "loo_vote_minority": minority,
                "loo_inversion": majority and minority, "seat_pivotal": not majority,
                "loo_domain_caution": "unrestricted party deletion; may leave original ideological domain"})
        other = tuple(p for p in data[c["election"]]["parties"] if p not in c["members"])
        complement = direct_coalition(data[c["election"]], other)
        for comp in ("A_C", "B_C", "d_C"):
            exact(complement[comp], -c[comp], "coalition complement " + comp)
    return member_rows


def serial(value):
    if isinstance(value, F):
        return format(float(value), ".17g")
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (list, tuple)):
        return "; ".join(value)
    return value


def write_csv(path, rows):
    require(bool(rows), "empty CSV output")
    with path.open("w", newline="", encoding="utf-8") as handle:
        out = csv.DictWriter(handle, fieldnames=list(rows[0]))
        out.writeheader()
        out.writerows({k: serial(v) for k, v in row.items()} for row in rows)


def export_and_check(stage, data, cases, members):
    pp = [p for year in YEARS for p in data[year]["parties"].values()]
    for p in pp:
        p["identity_residual"] = p["d_i"] - p["A_i"] - p["B_i"]
    summaries = [{**c, "members": "; ".join(c["members"]), "identity_residual": c["d_C"] - c["A_C"] - c["B_C"]} for c in cases]
    write_csv(stage / "party_components_all_years.csv", pp)
    write_csv(stage / "inversion_party_components.csv", members)
    write_csv(stage / "inversion_AB_summary.csv", summaries)
    party_out = read(stage / "party_components_all_years.csv")
    member_out = read(stage / "inversion_party_components.csv")
    summary_out = read(stage / "inversion_AB_summary.csv")
    for p in party_out + member_out:
        close(float(p["d_i"]), math.fsum(float(p[c]) for c in ("A_i", "B_i")), "exported party d=A+B", "csv")
    for year in YEARS:
        pool = [p for p in party_out if int(p["election"]) == year]
        for comp in ("A_i", "B_i", "d_i"):
            close(math.fsum(float(p[comp]) for p in pool), 0, f"exported {year} zero sum {comp}", "csv")
        exact(sum(int(p["seats"]) for p in pool), 513, "exported seat total")
    for c in summary_out:
        pool = [p for p in member_out if p["inversion_id"] == c["inversion_id"]]
        require(len(pool) == int(c["party_count"]), "exported member coverage")
        for comp in ("A", "B", "d"):
            residual = math.fsum(float(p[comp + "_i"]) for p in pool) - float(c[comp + "_C"])
            close(residual, 0, c["inversion_id"] + ": exported member sum " + comp, "csv")
            source = next(r for r in summaries if r["inversion_id"] == c["inversion_id"])
            source["csv_member_sum_residual_" + comp] = residual
        close(float(c["d_C"]), math.fsum(float(c[k]) for k in ("A_C", "B_C")), "exported coalition d=A+B", "csv")
    write_csv(stage / "inversion_AB_summary.csv", summaries)
    return pp


def fmt(value, digits=3, signed=False):
    return format(float(value), ("+" if signed else "") + f".{digits}f")


def md_table(headers, rows):
    def cell(x):
        return str(x).replace("|", "\\|").replace("\n", " ")
    return "\n".join(["| " + " | ".join(map(cell, headers)) + " |",
                     "| " + " | ".join("---" for _ in headers) + " |"] +
                    ["| " + " | ".join(map(cell, row)) + " |" for row in rows]) + "\n"


def contribution_list(rows, comp):
    return "; ".join(f"{p['party']} {fmt(p[comp], 2, True)}" for p in rows) or "None"


def assign_codes(cases):
    mapping = {
        (2014, "PSB--PTN"): "K14a", (2014, "PTB--PR"): "K14b",
        (2014, "PT DO B--PSDC"): "K14c", (2014, "SOLIDARIEDADE--PSL"): "K14d",
        (2022, "MDB--UNIÃO"): "K22a", (2022, "PP--PL"): "K22b",
    }
    cabinet_counts = Counter()
    for c in cases:
        if c["domain"] == "cabinet":
            cabinet_counts[c["election"]] += 1
            c["report_code"] = c["period"]
            continue
        c["report_code"] = mapping.get((c["election"], c["coalition"]),
                                      f"G{str(c['election'])[2:]}" if c["is_strongest_k1"] else "")


def make_figure(stage, data):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    colors = {'A+ B+':'#1b7f79','A+ B-':'#315d9b','A- B+':'#b06a00','A- B-':'#a23c42'}
    labels = {2014:{'PMDB','PSDB','PR','PSD','PTB','PP','PCdoB','PT DO B','PSOL','PSL'},
              2018:{'PP','PR','MDB','PT','PSL','PRB','PSC','NOVO','SOLIDARIEDADE'},
              2022:{'PL','UNIÃO','PT','PP','REPUBLICANOS','MDB','PSOL','PTB','PODE','PSC'}}
    offsets = {(2014,'PMDB'):(-2,9),(2014,'PSD'):(20,0),(2014,'PR'):(12,-12),
               (2014,'PTB'):(10,15),(2014,'PP'):(0,12),(2014,'PCdoB'):(-4,50),
               (2014,'PT DO B'):(-22,19),(2014,'PSL'):(-12,-20),
               (2018,'PP'):(-12,10),(2018,'MDB'):(-12,12),(2018,'PT'):(18,-15),
               (2018,'PRB'):(-8,-20),(2018,'PR'):(15,8),
               (2022,'PP'):(-6,12),(2022,'REPUBLICANOS'):(-10,-20),
               (2022,'PTB'):(-8,-22),(2022,'PODE'):(-8,14),(2022,'PSC'):(10,9),
               (2022,'MDB'):(0,10)}
    with plt.rc_context({'font.family':'DejaVu Sans','font.size':9,'axes.spines.top':False,'axes.spines.right':False}):
        fig,axes=plt.subplots(1,3,figsize=(15,5.3),sharex=True,sharey=True)
        for ax,year in zip(axes,YEARS):
            ax.axhline(0,color='#999999',linewidth=.8)
            ax.axvline(0,color='#999999',linewidth=.8)
            x=np.linspace(-7.5,21,200)
            ax.plot(x,-x,color='#bbbbbb',linestyle='--',linewidth=1,zorder=0)
            for p in data[year]['parties'].values():
                color=colors[p['component_pattern']]
                ax.scatter(float(p['A_i']),float(p['B_i']),s=20+1200*float(p['vote_share']),
                           facecolors=color if p['seats'] else 'white',edgecolors=color,linewidth=.9,alpha=.88,zorder=3)
                if p['party'] in labels[year]:
                    off=offsets.get((year,p['party']),(0,9))
                    ax.annotate(p['party'],(float(p['A_i']),float(p['B_i'])),xytext=off,textcoords='offset points',
                                ha='center',fontsize=8,arrowprops=dict(arrowstyle='-',lw=.4,color='#999999') if abs(off[0])+abs(off[1])>22 else None)
            ax.set_title(str(year),fontsize=13,fontweight='bold')
            ax.set_xlim(-7.8,21)
            ax.set_ylim(-6.6,5.5)
            ax.set_xlabel('Within-district component A_i (seats)')
            ax.grid(alpha=.12)
        axes[0].set_ylabel('Between-district component B_i (seats)')
        from matplotlib.lines import Line2D
        handles=[Line2D([0],[0],marker='o',color='none',markerfacecolor=c,markeredgecolor=c,label=label)
                 for label,c in colors.items()]
        fig.legend(handles=handles,loc='lower center',ncol=4,frameon=False,bbox_to_anchor=(.5,.035))
        fig.suptitle('The same net party differential can combine opposing components',fontsize=14,y=.98)
        fig.text(.5,.012,'Diagonal: d_i = A_i + B_i = 0. Point area reflects vote share; hollow points have zero seats. Accounting attribution, not causal effects.',ha='center',fontsize=9)
        fig.subplots_adjust(left=.06,right=.99,top=.88,bottom=.23,wspace=.10)
        fig.savefig(stage/'party_AB_scatter.png',dpi=180,facecolor='white')
        fig.savefig(stage/'party_AB_scatter.pdf',facecolor='white',metadata={'CreationDate':None,'ModDate':None})
        plt.close(fig)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--panel',type=Path,help='Reuse a primitive panel previously exported by export_party_AB_panel.jl (development only).')
    parser.add_argument('--output-dir',type=Path,default=ROOT/'build/validation/party_AB')
    args=parser.parse_args()
    import sys
    sys.path.insert(0,str(ROOT/'processing'))
    from cabinet_contract import require_current_outputs, RELEASE, PIN
    release=require_current_outputs()
    with tempfile.TemporaryDirectory(prefix='party_AB_') as tmp:
        stage=Path(tmp)
        panel=args.panel
        if panel is None:
            panel=stage/'district_panel.csv'
            shared=read(DECOMP/'raw/party_district_accounting_all_years.csv')
            write_csv(panel, [dict(election=r['election_year'], district=r['electoral_unit'],
                party=r['party'], votes=r['v_id'], seats=r['s_id'],
                district_votes=r['V_d'], district_seats=r['S_d']) for r in shared])
        data=load_party_data(panel)
        print('Exact party and complete-system identities passed.',flush=True)
        cases=validate_registry(data)
        members=augment_cases(data,cases)
        assign_codes(cases)
        code_by_id = {c['inversion_id']: c['report_code'] for c in cases}
        for row in members:
            row['report_code'] = code_by_id[row['inversion_id']]
        export_and_check(stage,data,cases,members)
        make_figure(stage,data)
        args.output_dir.mkdir(parents=True,exist_ok=True)
        names=['party_components_all_years.csv','inversion_party_components.csv',
               'inversion_AB_summary.csv',
               'party_AB_scatter.png','party_AB_scatter.pdf']
        validation = dict(release_version=release['metadata']['release_version'], release_metadata_sha256=release['metadata_sha256'],
                          ideological_universe='all_parties (original standalone sensitivity)',
                          party_years=sum(len(data[y]['parties']) for y in YEARS), configurations=len(cases),
                          main_focal=sum(c['is_main_focal'] for c in cases), k1_minimal=sum(c['k']==1 for c in cases),
                          member_rows=len(members), checks=dict(CHECKS), max_residual=dict(MAX_RESIDUAL),
                          scope='Independent exact accounting, complete domain minimality and member deletion checks')
        (stage/'party_AB_validation.json').write_text(json.dumps(validation, indent=2) + '\n')
        names.append('party_AB_validation.json')
        for name in names:
            shutil.copyfile(stage/name,args.output_dir/name)
        print(json.dumps(validation,indent=2),flush=True)


if __name__=='__main__':
    main()
