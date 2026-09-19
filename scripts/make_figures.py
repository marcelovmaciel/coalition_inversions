#!/usr/bin/env python3
"""Render manuscript and retained diagnostic figures from canonical scientific CSVs."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap, BoundaryNorm
from matplotlib.dates import DateFormatter

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'writing'))
import make_district_electoral_weight_diagnostic as district_weight_diagnostic
from datetime import date
from matplotlib.lines import Line2D
from matplotlib.ticker import MultipleLocator


DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARTIFACT_ROOT = DEFAULT_REPO_ROOT / "build" / "results" / "domains"
DEFAULT_FIGURE_DIR = DEFAULT_REPO_ROOT / "build" / "assets"
EXPECTED_SEATS = 513
SEAT_MAJORITY = 257
ACCOUNTING_ATOL = 1e-9
ACCOUNTING_RTOL = 1e-12
ELECTION_LABELS = {
    2014: "2014 election",
    2018: "2018 election",
    2022: "2022 election",
}
DECOMPOSITION_COMPONENTS = ("A_C", "B_C", "d_C")

STATE_WEIGHTING_MAGNITUDE_COLUMNS = (
    "b_positive_eight_seat",
    "b_positive_other",
    "b_negative_sp",
    "b_negative_other",
)

# Discrete palette for ideological-interval categories.
INTERVAL_COLORS = [
    "#f0f0f0",  # no seat majority
    "#8ecae6",  # seat majority without inversion
    "#fb8500",  # inversion
    "#c1121f",  # endpoint-minimal inversion
]
INTERVAL_LABELS = [
    "no seat majority",
    "vote + seat majority",
    "inversion",
    "minimal inversion",
]


def read_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Required input CSV not found: {path}")
    # Period labels are identifiers: 2015.10 must not collapse to 2015.1.
    return pd.read_csv(path, dtype={"period": str, "cabinet_period": str})


def require_columns(data: pd.DataFrame, path: Path, columns: set[str]) -> None:
    missing = sorted(columns.difference(data.columns))
    if missing:
        raise ValueError(f"Required columns missing from {path}: {', '.join(missing)}")


def coerce_bool_column(data: pd.DataFrame, path: Path, column: str) -> pd.Series:
    """Return one strict boolean column, rejecting missing or ambiguous values."""
    values = data[column]
    if values.isna().any():
        raise ValueError(f"Boolean column {column!r} contains missing values in {path}")
    if pd.api.types.is_bool_dtype(values.dtype):
        return values.astype(bool)
    if pd.api.types.is_numeric_dtype(values.dtype):
        numeric = pd.to_numeric(values, errors="raise")
        unexpected = sorted(set(numeric).difference({0, 1}))
        if unexpected:
            raise ValueError(
                f"Boolean column {column!r} has non-binary values in {path}: {unexpected}"
            )
        return numeric.astype(bool)

    normalized = values.astype(str).str.strip().str.lower()
    unexpected = sorted(set(normalized).difference({"true", "false"}))
    if unexpected:
        raise ValueError(
            f"Boolean column {column!r} has invalid values in {path}: {unexpected}"
        )
    return normalized.map({"true": True, "false": False}).astype(bool)


def require_finite_numeric(data: pd.DataFrame, path: Path, columns: set[str]) -> None:
    for column in sorted(columns):
        converted = pd.to_numeric(data[column], errors="raise")
        if not np.isfinite(converted.to_numpy(dtype=float)).all():
            raise ValueError(f"Numeric column {column!r} contains non-finite values in {path}")
        data[column] = converted


def formatted_keys(keys: set[tuple[int, str]]) -> str:
    return ", ".join(f"{year}/{period}" for year, period in sorted(keys))


def load_party_vote_share_vs_seat_share(artifact_root: Path) -> pd.DataFrame:
    input_path = artifact_root / "figure_data" / "party_vote_share_vs_seat_share.csv"
    party = read_csv(input_path)
    require_columns(
        party,
        input_path,
        {"election_year", "party", "vote_share", "seat_share"},
    )
    require_finite_numeric(party, input_path, {"election_year", "vote_share", "seat_share"})
    party["election_year"] = party["election_year"].astype(int)
    if set(party["election_year"]) != set(ELECTION_LABELS):
        raise ValueError(
            f"Party figure years changed in {input_path}: {sorted(set(party['election_year']))}"
        )
    if party.duplicated(["election_year", "party"]).any():
        raise ValueError(f"Duplicate election/party rows in {input_path}")
    for year, rows in party.groupby("election_year"):
        if not np.isclose(rows["vote_share"].sum(), 1.0, atol=1e-6, rtol=0.0):
            raise ValueError(f"Party vote shares for {year} do not sum to one in {input_path}")
        if not np.isclose(rows["seat_share"].sum(), 1.0, atol=1e-6, rtol=0.0):
            raise ValueError(f"Party seat shares for {year} do not sum to one in {input_path}")
    return party


def load_observed_coalition_timeline(artifact_root: Path) -> pd.DataFrame:
    input_path = artifact_root / "raw" / "cabinet_party_sets.csv"
    observed = read_csv(input_path)
    if observed.duplicated(["cabinet_party_set_id"]).any():
        raise ValueError("Duplicate cabinet party set in shared registry")
    require_columns(
        observed,
        input_path,
        {
            "election_year",
            "first_observed",
            "period",
            "period_start",
            "period_end",
            "vote_share",
            "seat_share",
            "seats",
            "representation_ratio",
            "coalition_inversion",
        },
    )
    require_finite_numeric(
        observed,
        input_path,
        {"election_year", "vote_share", "seat_share", "seats"},
    )
    observed["representation_ratio"] = pd.to_numeric(observed["representation_ratio"], errors="raise")
    positive_quota = observed.vote_share.gt(0)
    if not np.isfinite(observed.loc[positive_quota, "representation_ratio"]).all():
        raise ValueError("Positive-quota cabinet ratios must be finite")
    if observed.loc[~positive_quota, "representation_ratio"].notna().any():
        raise ValueError("Zero-quota cabinet ratios must be unavailable")
    observed["election_year"] = observed["election_year"].astype(int)
    observed["period"] = observed["period"].astype(str)
    observed["coalition_inversion"] = coerce_bool_column(
        observed, input_path, "coalition_inversion"
    )

    if observed.duplicated(["election_year", "period"]).any():
        raise ValueError(f"Duplicate election/period rows in {input_path}")
    inversion_rows = observed.loc[observed["coalition_inversion"]]
    if not (inversion_rows["vote_share"] < 0.5).all():
        raise ValueError(f"An observed inversion has at least 50% of votes in {input_path}")
    if not (inversion_rows["seats"] >= SEAT_MAJORITY).all():
        raise ValueError(f"An observed inversion has fewer than 257 seats in {input_path}")

    observed["first_observed"] = pd.to_datetime(observed["first_observed"], errors="raise")
    if observed["first_observed"].isna().any():
        raise ValueError(f"Missing first-observed date in {input_path}")
    observed["period_start"] = pd.to_datetime(observed["period_start"], errors="raise")
    observed["period_end"] = pd.to_datetime(observed["period_end"], errors="raise")
    if (observed["period_end"] < observed["period_start"]).any():
        raise ValueError(f"Observed cabinet period ends before it starts in {input_path}")
    observed["midpoint"] = observed["period_start"] + (
        observed["period_end"] - observed["period_start"]
    ) / 2
    return observed


def cabinet_calendar_has_bounded_dates(artifact_root: Path) -> bool:
    path = artifact_root / "raw" / "cabinet_calendar_status.csv"
    if not path.exists():
        return False
    data = read_csv(path)
    return any(data[column].fillna("").astype(str).str.strip().isin(["", "[]", "false", "0"]).eq(False).any()
               for column in ("bounded_affiliation_ids", "bounded_service_ids") if column in data)


def load_cabinet_unidentified_intervals(artifact_root: Path) -> pd.DataFrame:
    """Return explicit composition gaps; the ordinary metrics contain full sets only."""
    path = artifact_root / "raw" / "cabinet_unidentified_intervals.csv"
    if not path.exists():
        # Legacy synthetic plotting fixtures predate the release adapter.
        return pd.DataFrame(columns=["start_inclusive", "end_exclusive", "days"])
    data = read_csv(path)
    require_columns(data, path, {"start_inclusive", "end_exclusive", "days"})
    for column in ("start_inclusive", "end_exclusive"):
        data[column] = pd.to_datetime(data[column], errors="raise")
    require_finite_numeric(data, path, {"days"})
    expected = (data.end_exclusive - data.start_inclusive).dt.days
    if not (expected.gt(0) & expected.eq(data.days)).all():
        raise ValueError(f"Invalid unidentified interval durations in {path}")
    return data


def load_ideological_interval_heatmap(artifact_root: Path) -> pd.DataFrame:
    input_path = artifact_root / "figure_data" / "ideological_interval_heatmap.csv"
    intervals = read_csv(input_path)
    require_columns(
        intervals,
        input_path,
        {
            "election_year",
            "start_index",
            "end_index",
            "seats",
            "coalition_inversion",
            "minimal_ideological_interval_inversion",
        },
    )
    require_finite_numeric(
        intervals,
        input_path,
        {"election_year", "start_index", "end_index", "seats"},
    )
    intervals["election_year"] = intervals["election_year"].astype(int)
    for column in ("coalition_inversion", "minimal_ideological_interval_inversion"):
        intervals[column] = coerce_bool_column(intervals, input_path, column)
    if intervals.duplicated(["election_year", "start_index", "end_index"]).any():
        raise ValueError(f"Duplicate ideological interval rows in {input_path}")
    if (
        intervals["minimal_ideological_interval_inversion"]
        & ~intervals["coalition_inversion"]
    ).any():
        raise ValueError(f"A minimal ideological inversion is not an inversion in {input_path}")

    require_columns(intervals, input_path, {"ideological_universe", "ideological_party_count", "vote_share"})
    if set(intervals["ideological_universe"]) != {"seat_winning"}:
        raise ValueError("Main interval figure requires the seat_winning universe")
    if set(intervals["election_year"]) != set(ELECTION_LABELS):
        raise ValueError("Ideological figure must contain all three election years")
    for year, rows in intervals.groupby("election_year"):
        order = read_csv(artifact_root / "raw" / f"ideology_order_{year}.csv")
        n = len(order)
        expected = {(i, j) for i in range(1, n + 1) for j in range(i, n + 1)}
        actual = set(zip(rows["start_index"], rows["end_index"]))
        if actual != expected or set(rows["ideological_party_count"]) != {n}:
            raise ValueError(f"Interval figure does not cover the parliamentary order for {year}")
    return intervals


def load_inversion_decomposition_components(artifact_root: Path) -> pd.DataFrame:
    input_path = artifact_root.parent / "accounting" / "figure_data/inversion_decomposition_components.csv"
    components = read_csv(input_path)
    require_columns(
        components,
        input_path,
        {"coalition_id", "election_year", "cabinet_period", "component", "seats"},
    )
    require_finite_numeric(components, input_path, {"election_year", "seats"})
    components["election_year"] = components["election_year"].astype(int)
    components["cabinet_period"] = components["cabinet_period"].astype(str)
    components["coalition_id"] = components["coalition_id"].astype(str).str.strip()
    components["component"] = components["component"].astype(str).str.strip()
    if (components["coalition_id"] == "").any():
        raise ValueError(f"Blank coalition_id in {input_path}")
    if components.duplicated(
        ["coalition_id", "election_year", "cabinet_period", "component"]
    ).any():
        raise ValueError(f"Duplicate coalition/component rows in {input_path}")

    actual_keys = set(
        zip(components["election_year"], components["cabinet_period"], strict=True)
    )
    observed = load_observed_coalition_timeline(artifact_root)
    inversions = observed.loc[observed.coalition_inversion]
    expected_keys = set(zip(inversions.election_year, inversions.period))
    if actual_keys != expected_keys:
        raise ValueError(
            f"Decomposition case keys changed in {input_path}: expected "
            f"{formatted_keys(expected_keys)}; found {formatted_keys(actual_keys)}"
        )
    if components.empty:
        return pd.DataFrame(columns=["coalition_id", "election_year", "cabinet_period", *DECOMPOSITION_COMPONENTS])
    component_sets = components.groupby(["election_year", "cabinet_period"])["component"].agg(set)
    expected_components = set(DECOMPOSITION_COMPONENTS)
    invalid_component_sets = component_sets[component_sets != expected_components]
    if not invalid_component_sets.empty:
        raise ValueError(
            f"Every decomposition case must contain exactly {DECOMPOSITION_COMPONENTS} in {input_path}"
        )

    pivoted = components.pivot(
        index=["coalition_id", "election_year", "cabinet_period"],
        columns="component",
        values="seats",
    ).reset_index()
    pivoted.columns.name = None
    residual = pivoted["A_C"] + pivoted["B_C"] - pivoted["d_C"]
    if not np.allclose(residual, 0.0, atol=ACCOUNTING_ATOL, rtol=ACCOUNTING_RTOL):
        failures = pivoted.loc[
            ~np.isclose(residual, 0.0, atol=ACCOUNTING_ATOL, rtol=ACCOUNTING_RTOL),
            ["coalition_id", "A_C", "B_C", "d_C"],
        ]
        raise ValueError(
            "Decomposition identity A_C + B_C = d_C failed in "
            f"{input_path}: {failures.to_dict(orient='records')}"
        )
    order = {key: index for index, key in enumerate(zip(inversions.election_year, inversions.period))}
    pivoted["_order"] = [
        order[(year, period)]
        for year, period in zip(
            pivoted["election_year"], pivoted["cabinet_period"], strict=True
        )
    ]
    return pivoted.sort_values("_order").drop(columns="_order").reset_index(drop=True)


def load_accounting_state_weighting_anatomy(artifact_root: Path) -> pd.DataFrame:
    """Load and validate all current focal state-weighting vectors.

    Negative component columns are stored by Julia as positive magnitudes. The
    loader verifies that gross positive minus gross negative contributions
    reproduces the reported net between-district component before plotting.
    """
    input_path = artifact_root.parent / "accounting" / "figure_data/accounting_state_weighting_anatomy.csv"
    anatomy = read_csv(input_path)
    required = {
        "case_id",
        "case_display",
        "case_order",
        "focal_order",
        *STATE_WEIGHTING_MAGNITUDE_COLUMNS,
        "B_C",
        "largest_positive_state",
        "largest_positive_b_Cd",
    }
    require_columns(anatomy, input_path, required)
    require_finite_numeric(
        anatomy,
        input_path,
        {
            "case_order",
            "focal_order",
            *STATE_WEIGHTING_MAGNITUDE_COLUMNS,
            "B_C",
            "largest_positive_b_Cd",
        },
    )

    for column in ("case_id", "case_display", "largest_positive_state"):
        if anatomy[column].isna().any():
            raise ValueError(f"Text column {column!r} contains missing values in {input_path}")
        anatomy[column] = anatomy[column].astype(str).str.strip()
        if (anatomy[column] == "").any():
            raise ValueError(f"Text column {column!r} contains blank values in {input_path}")

    focal_order = anatomy["focal_order"].to_numpy(dtype=float)
    if not np.equal(focal_order, np.floor(focal_order)).all():
        raise ValueError(f"focal_order must contain integers in {input_path}")
    anatomy["focal_order"] = anatomy["focal_order"].astype(int)
    if anatomy["case_id"].duplicated().any():
        raise ValueError(f"Duplicate case_id rows in {input_path}")
    if anatomy["focal_order"].duplicated().any():
        raise ValueError(f"Duplicate focal_order rows in {input_path}")

    anatomy = anatomy.sort_values("focal_order").reset_index(drop=True)
    if tuple(anatomy["focal_order"]) != tuple(range(1, len(anatomy) + 1)):
        raise ValueError(f"Focal registry order is not contiguous in {input_path}")
    registry = read_csv(artifact_root.parent / "accounting" / "tables/table_accounting_focal_cases.csv")
    if "case_id" in registry and set(anatomy["case_id"]) != set(registry["case_id"]):
        raise ValueError(f"State anatomy differs from the generated focal registry in {input_path}")

    magnitudes = anatomy.loc[:, STATE_WEIGHTING_MAGNITUDE_COLUMNS]
    if (magnitudes < -ACCOUNTING_ATOL).any().any():
        raise ValueError(
            f"State-weighting gross components must be nonnegative magnitudes in {input_path}"
        )
    if (anatomy["largest_positive_b_Cd"] <= 0).any():
        raise ValueError(f"Largest positive state contributions must be positive in {input_path}")

    gross_positive = anatomy["b_positive_eight_seat"] + anatomy["b_positive_other"]
    gross_negative = anatomy["b_negative_sp"] + anatomy["b_negative_other"]
    residual = gross_positive - gross_negative - anatomy["B_C"]
    if not np.allclose(residual, 0.0, atol=ACCOUNTING_ATOL, rtol=ACCOUNTING_RTOL):
        failures = anatomy.loc[
            ~np.isclose(residual, 0.0, atol=ACCOUNTING_ATOL, rtol=ACCOUNTING_RTOL),
            ["case_id", *STATE_WEIGHTING_MAGNITUDE_COLUMNS, "B_C"],
        ]
        raise ValueError(
            "State-weighting gross components do not reproduce B_C in "
            f"{input_path}: {failures.to_dict(orient='records')}"
        )
    if (
        anatomy["largest_positive_b_Cd"].to_numpy(dtype=float)
        > gross_positive.to_numpy(dtype=float) + ACCOUNTING_ATOL
    ).any():
        raise ValueError(
            f"A largest positive state contribution exceeds gross positive B in {input_path}"
        )

    return anatomy


def load_district_electoral_weight(artifact_root: Path) -> pd.DataFrame:
    """Load the validated neutral state-year district-weight diagnostic data."""
    input_path = (
        artifact_root.parent / "accounting" / "figure_data/accounting_district_electoral_weight.csv"
    )
    return district_weight_diagnostic.load_district_electoral_weight(input_path)


def save_party_vote_share_vs_seat_share(artifact_root: Path, figure_dir: Path) -> Path:
    party = load_party_vote_share_vs_seat_share(artifact_root)

    fig, ax = plt.subplots(figsize=(6.6, 4.8))
    for year, df in party.groupby("election_year"):
        ax.scatter(
            df["vote_share"] * 100,
            df["seat_share"] * 100,
            s=38,
            alpha=0.75,
            label=str(year),
        )

    upper = max(party["vote_share"].max(), party["seat_share"].max()) * 100 + 2
    lims = [0, upper]
    ax.plot(lims, lims, linestyle="--", linewidth=1, label="proportionality")
    ax.set_xlim(lims)
    ax.set_ylim(lims)
    ax.set_xlabel("Vote share (%)")
    ax.set_ylabel("Seat share (%)")
    ax.set_title("Party vote shares and Chamber seat shares")
    ax.legend(frameon=False, fontsize=8)
    ax.grid(True, linewidth=0.35, alpha=0.35)

    output = figure_dir / "party_vote_share_vs_seat_share.pdf"
    fig.tight_layout()
    fig.savefig(output)
    plt.close(fig)
    return output


ELECTION_COLORS = {2014: "#1f77b4", 2018: "#ff7f0e", 2022: "#2ca02c"}

def plot_observed_coalition_starts(axes, observed: pd.DataFrame) -> None:
    """One point per distinct set at its first observed calendar date."""
    series = (("vote_share", 100, "o"), ("seat_share", 100, "s"),
              ("representation_ratio", 1, "^"))
    for year, rows in observed.groupby("election_year", sort=True):
        for ax, (column, scale, marker) in zip(axes, series, strict=True):
            ax.plot(rows["first_observed"], rows[column] * scale, linestyle="none",
                    marker=marker, color=ELECTION_COLORS[year], label=ELECTION_LABELS[year], markersize=4)
    inverted = observed.loc[observed.coalition_inversion]
    for ax, (column, scale, _) in zip(axes, series, strict=True):
        ax.plot(inverted["first_observed"], inverted[column] * scale, linestyle="none", marker="o",
                markersize=10, markerfacecolor="none", markeredgecolor="black",
                markeredgewidth=1.1, label="Inversion", zorder=5)


def save_observed_coalition_timeline(artifact_root: Path, figure_dir: Path) -> Path:
    # Filename retained for manuscript label compatibility; chronology input
    # remains separately exported as figure_data/observed_coalition_timeline.csv.
    observed = load_observed_coalition_timeline(artifact_root).sort_values(
        ["first_observed", "cabinet_party_set_id"]).reset_index(drop=True)
    fig, axes = plt.subplots(1, 3, figsize=(9.2, 3.4), sharex=True)
    plot_observed_coalition_starts(axes, observed)
    annual_ticks = pd.date_range("2015-01-01", "2026-01-01", freq="YS")
    date_padding = pd.Timedelta(days=90)
    date_limits = (min(annual_ticks[0], observed.first_observed.min()) - date_padding,
                   max(annual_ticks[-1], observed.first_observed.max()) + date_padding)
    for ax, threshold, title, ylabel in zip(axes, (50, SEAT_MAJORITY / EXPECTED_SEATS * 100, 1),
            ("Vote share", "Seat share", "Representation ratio"), ("Vote (%)", "Seats (%)", r"$R_C$")):
        ax.axhline(threshold, linestyle="--", color="#666666", linewidth=.8)
        ax.set_title(title, loc="left", fontsize=10)
        ax.set_ylabel(ylabel)
        ax.grid(axis="y", linewidth=.35, alpha=.35)
        ax.set_xticks(annual_ticks)
        ax.xaxis.set_major_formatter(DateFormatter("%Y"))
        ax.set_xlim(date_limits)
        plt.setp(ax.get_xticklabels(), rotation=90, ha="center", fontsize=7)
    fig.supxlabel("First observed", y=.03, fontsize=10)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=4, frameon=False, bbox_to_anchor=(.53,1.0))
    fig.subplots_adjust(top=.80,bottom=.25,left=.065,right=.99,wspace=.42)
    output = figure_dir / "observed_coalition_timeline.pdf"
    fig.savefig(output, metadata={"CreationDate":None,"ModDate":None})
    plt.close(fig)
    return output


def interval_status_code(row: pd.Series) -> int:
    """Return matrix code for an ideological interval.

    0: no seat majority
    1: seat majority without inversion
    2: coalition inversion
    3: endpoint-minimal ideological interval inversion
    """
    if bool(row["minimal_ideological_interval_inversion"]):
        return 3
    if bool(row["coalition_inversion"]):
        return 2
    if row["majority_status"] in ("votes+seats", "seats only"):
        return 1
    return 0


def save_ideological_interval_legend(figure_dir: Path) -> Path:
    """Save one compact legend for the separately included heatmap panels."""
    handles = [
        plt.Rectangle((0, 0), 1, 1, facecolor=color, edgecolor="none", label=label)
        for color, label in zip(INTERVAL_COLORS, INTERVAL_LABELS, strict=True)
    ]
    fig = plt.figure(figsize=(6.4, 0.28))
    fig.legend(
        handles=handles, loc="center", ncol=4, frameon=False, fontsize=9,
        handlelength=1.1, handletextpad=0.45, columnspacing=1.25,
        borderpad=0, borderaxespad=0,
    )
    output = figure_dir / "ideological_interval_heatmap_legend.pdf"
    fig.savefig(output, bbox_inches="tight", pad_inches=0.035)
    plt.close(fig)
    return output


def save_ideological_interval_heatmaps(artifact_root: Path, figure_dir: Path) -> list[Path]:
    intervals = load_ideological_interval_heatmap(artifact_root)
    outputs: list[Path] = []
    cmap = ListedColormap(INTERVAL_COLORS)
    norm = BoundaryNorm(np.arange(-0.5, 4.5, 1), cmap.N)

    for year, df in intervals.groupby("election_year"):
        n = int(max(df["start_index"].max(), df["end_index"].max()))
        matrix = np.full((n, n), np.nan)

        for _, row in df.iterrows():
            i = int(row["start_index"]) - 1
            j = int(row["end_index"]) - 1
            matrix[j, i] = interval_status_code(row)

        fig, ax = plt.subplots(figsize=(5.6, 5.2))
        ax.imshow(matrix, origin="lower", interpolation="nearest", aspect="auto", cmap=cmap, norm=norm, extent=(0.5, n + 0.5, 0.5, n + 0.5))
        ax.set_title(f"Ideological interval status, {year}")
        ax.set_xlabel("Start index in ideology order")
        ax.set_ylabel("End index in ideology order")
        ticks = sorted(set([1, n] + list(range(5, n, 5))))
        ax.set_xticks(ticks)
        ax.set_yticks(ticks)


        output = figure_dir / f"ideological_interval_heatmap_{year}.pdf"
        fig.tight_layout()
        fig.savefig(output, bbox_inches="tight")
        plt.close(fig)
        outputs.append(output)

    outputs.append(save_ideological_interval_legend(figure_dir))
    return outputs



def load_seat_winning_order(artifact_root: Path, year: int) -> pd.DataFrame:
    """Return the validated ordinal party order used by Figure 3."""
    order_path = artifact_root / "raw" / f"ideology_order_{year}.csv"
    order = read_csv(order_path)
    require_columns(
        order, order_path,
        {"ideological_universe", "election_year", "ordinal_position", "party"},
    )
    order = order.loc[
        order["ideological_universe"].eq("seat_winning")
        & order["election_year"].eq(year)
    ].sort_values("ordinal_position")
    require_finite_numeric(order, order_path, {"ordinal_position"})
    if (order["party"].isna().any() or order["party"].duplicated().any()
            or not np.array_equal(order["ordinal_position"], np.arange(1, len(order) + 1))
            or order["party"].eq("PT").sum() != 1):
        raise ValueError(f"Invalid seat-winning party order in {order_path}")
    return order


def build_minimal_connected_winning_inversions(artifact_root: Path) -> plt.Figure:
    """Plot the exact-connected minimal inversions in the seat-winning order.

    Both interval membership and annotation values come from the unrounded
    figure-data export; the raw ideology-order CSVs determine party positions.
    Each interval gets its own bracket row, in increasing start-position order.
    """
    input_path = artifact_root / "figure_data" / "ideological_interval_heatmap.csv"
    intervals = load_ideological_interval_heatmap(artifact_root)
    require_columns(intervals, input_path, {"start_party", "end_party", "vote_share"})
    require_finite_numeric(intervals, input_path, {"vote_share"})
    minimal = intervals.loc[
        intervals["ideological_universe"].eq("seat_winning")
        & intervals["coalition_inversion"]
        & intervals["minimal_ideological_interval_inversion"]
    ].sort_values(["election_year", "start_index", "end_index"])

    years = sorted(ELECTION_LABELS)
    orders = {}
    for year in years:
        order = load_seat_winning_order(artifact_root, year)
        positions = order.set_index("party")["ordinal_position"]
        rows = minimal.loc[minimal["election_year"].eq(year)]
        if rows.empty:
            raise ValueError(f"No minimal connected winning inversions for {year}")
        for endpoint in ("start", "end"):
            if not np.array_equal(
                rows[f"{endpoint}_party"].map(positions), rows[f"{endpoint}_index"]
            ):
                raise ValueError(f"Interval endpoints disagree with party order for {year}")
        if not (rows["seats"] == rows["seats"].astype(int)).all():
            raise ValueError(f"Non-integer interval seat counts for {year}")
        orders[year] = order

    counts = [int(minimal["election_year"].eq(year).sum()) for year in years]
    with plt.rc_context({"font.family": "DejaVu Sans", "pdf.fonttype": 42}):
        fig, axes = plt.subplots(
            3, 1, figsize=(6.4, 6.2), layout="constrained",
            gridspec_kw={"height_ratios": [count + 0.75 for count in counts]},
        )
        for ax, year, count in zip(axes, years, counts, strict=True):
            order = orders[year]
            positions = order.set_index("party")["ordinal_position"]
            ordinary = order.loc[order["party"].ne("PT"), "ordinal_position"]
            ax.plot(ordinary, np.zeros(len(ordinary)), linestyle="none",
                    marker="o", markersize=2.7, color="black", zorder=3)
            ax.plot(positions["PT"], 0, linestyle="none", marker="D",
                    markersize=4.2, color="black", zorder=4)

            # Put tick labels immediately below the party baseline.
            for spine in ax.spines.values():
                spine.set_visible(False)
            ax.spines["bottom"].set_visible(True)
            ax.spines["bottom"].set_position(("data", 0))
            ax.spines["bottom"].set_bounds(1, len(order))
            ax.spines["bottom"].set_linewidth(0.6)
            ax.set_xticks(order["ordinal_position"], order["party"],
                          rotation=90, fontsize=8, ha="center", va="top")
            ax.tick_params(axis="x", length=0, pad=5)
            ax.set_yticks([])
            ax.grid(False)
            ax.set_xlim(0.35, len(order) + 0.65)
            ax.set_ylim(-0.12, count + 0.75)
            ax.set_title(str(year), fontsize=10.5, pad=4)

            rows = minimal.loc[minimal["election_year"].eq(year)]
            for lane, row in enumerate(rows.itertuples()):
                left = positions[row.start_party]
                right = positions[row.end_party]
                height = count - lane
                ax.plot([left, left, right, right],
                        [height - 0.18, height, height, height - 0.18],
                        color="black", linewidth=0.65, solid_capstyle="butt")
                ax.annotate(f"{100 * row.vote_share:.2f}% votes, {int(row.seats)} seats",
                            ((left + right) / 2, height), xytext=(0, 3),
                            textcoords="offset points", ha="center", va="bottom",
                            fontsize=8.5)

        axes[-1].set_xlabel("Seat-winning parties ordered from left to right",
                            fontsize=9, labelpad=8)
    return fig


def save_minimal_connected_winning_inversions(
    artifact_root: Path, figure_dir: Path
) -> list[Path]:
    """Save matching vector PDF and 300-dpi PNG versions of the three panels."""
    figure_dir.mkdir(parents=True, exist_ok=True)
    fig = build_minimal_connected_winning_inversions(artifact_root)
    stem = "minimal_connected_winning_inversions_3x1_diamond"
    outputs = [figure_dir / f"{stem}.{extension}" for extension in ("pdf", "png")]
    try:
        with plt.rc_context({"pdf.fonttype": 42}):
            for output in outputs:
                fig.savefig(output, dpi=300, facecolor="white")
    finally:
        plt.close(fig)
    return outputs


def save_inversion_decomposition_components(artifact_root: Path, figure_dir: Path) -> Path:
    components = load_inversion_decomposition_components(artifact_root)
    labels = [
        f"{year} / {period}"
        for year, period in zip(
            components["election_year"], components["cabinet_period"], strict=True
        )
    ]
    positions = np.arange(len(components))
    offset = 0.18

    fig, ax = plt.subplots(figsize=(7.2, max(3.2, .52 * len(components) + 1.6)))
    if components.empty:
        ax.text(.5, .5, "No identified cabinet inversions", ha="center", va="center", transform=ax.transAxes)
    ax.barh(
        positions - offset,
        components["A_C"],
        height=0.32,
        color="#315f7d",
        label=r"Within-district allocation ($A_C$)",
    )
    ax.barh(
        positions + offset,
        components["B_C"],
        height=0.32,
        color="#d17a22",
        label=r"Between-district weighting ($B_C$)",
    )
    ax.scatter(
        components["d_C"],
        positions,
        marker="D",
        s=28,
        color="black",
        label=r"Coalition differential ($d_C$)",
        zorder=3,
    )
    ax.axvline(0, color="0.45", linewidth=0.8)
    ax.set_yticks(positions, labels)
    ax.invert_yaxis()
    ax.set_xlabel("Seat contribution")
    ax.set_title("Accounting decomposition of inverted cabinet party sets")
    ax.grid(True, axis="x", linewidth=0.35, alpha=0.35)
    ax.legend(frameon=False, fontsize=8, loc="upper center",
              bbox_to_anchor=(0.5, -0.20), ncol=2)

    output = figure_dir / "inversion_decomposition_components.pdf"
    fig.tight_layout()
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)
    return output


def save_accounting_state_weighting_anatomy(artifact_root: Path, figure_dir: Path) -> Path:
    anatomy = load_accounting_state_weighting_anatomy(artifact_root)
    positions = np.arange(len(anatomy))
    positive_eight = anatomy["b_positive_eight_seat"].to_numpy(dtype=float)
    positive_other = anatomy["b_positive_other"].to_numpy(dtype=float)
    negative_sp = anatomy["b_negative_sp"].to_numpy(dtype=float)
    negative_other = anatomy["b_negative_other"].to_numpy(dtype=float)
    positive_total = positive_eight + positive_other
    negative_total = negative_sp + negative_other

    fig, ax = plt.subplots(figsize=(10.2, 5.8))
    bar_options = {"height": 0.62, "edgecolor": "white", "linewidth": 0.45, "zorder": 2}
    ax.barh(
        positions,
        positive_eight,
        color="#0072B2",
        label="Positive: eight-seat districts",
        **bar_options,
    )
    ax.barh(
        positions,
        positive_other,
        left=positive_eight,
        color="#56B4E9",
        label="Positive: other districts",
        **bar_options,
    )
    ax.barh(
        positions,
        -negative_sp,
        color="#D55E00",
        label="Negative: São Paulo",
        **bar_options,
    )
    ax.barh(
        positions,
        -negative_other,
        left=-negative_sp,
        color="#E69F00",
        label="Negative: other districts",
        **bar_options,
    )
    ax.scatter(
        anatomy["B_C"],
        positions,
        marker="D",
        s=34,
        facecolor="black",
        edgecolor="white",
        linewidth=0.45,
        label=r"Net $B_C$",
        zorder=4,
    )

    extent = max(
        float(positive_total.max()),
        float(negative_total.max()),
        float(np.abs(anatomy["B_C"]).max()),
        1.0,
    )
    for position, positive_endpoint, state, value in zip(
        positions,
        positive_total,
        anatomy["largest_positive_state"],
        anatomy["largest_positive_b_Cd"],
        strict=True,
    ):
        ax.annotate(
            f"{state} +{value:.2f}",
            xy=(positive_endpoint, position),
            xytext=(4, 0),
            textcoords="offset points",
            ha="left",
            va="center",
            fontsize=7.5,
            color="#005A8C",
            clip_on=False,
        )

    ax.axvline(0, color="0.25", linewidth=0.8, zorder=3)
    ax.set_xlim(
        -float(negative_total.max()) - 0.05 * extent,
        float(positive_total.max()) + 0.24 * extent,
    )
    ax.set_yticks(positions, anatomy["case_display"])
    ax.invert_yaxis()
    ax.set_xlabel(r"Between-district accounting contribution (seats; $b_{Cd}$ and net $B_C$)")
    ax.grid(True, axis="x", linewidth=0.4, alpha=0.35, zorder=0)
    ax.legend(
        frameon=False,
        fontsize=8,
        loc="lower center",
        bbox_to_anchor=(0.5, 1.01),
        ncol=3,
    )

    output = figure_dir / "accounting_state_weighting_anatomy.pdf"
    fig.tight_layout()
    fig.savefig(output, bbox_inches="tight")
    plt.close(fig)
    return output


def save_district_electoral_weight_by_magnitude(
    artifact_root: Path, figure_dir: Path
) -> Path:
    """Render the neutral district-weight diagnostic into the requested figure tree."""
    district_weights = load_district_electoral_weight(artifact_root)
    output = figure_dir / "district_electoral_weight_by_magnitude.pdf"
    return district_weight_diagnostic.render_district_electoral_weight(
        district_weights, output
    )


YEARS = (2014, 2018, 2022)
# The approved diagnostic election palette.
COLORS = {2014: '#28678b', 2018: '#ba6620', 2022: '#278275'}
DOMAINS = ('cabinet', 'k=0')


def render_cross_domain_components(data: pd.DataFrame, output: Path) -> Path:
    """Draw distinct cabinet party sets and all exact-connected minimal winners."""
    validation = data.attrs.get("validation", {})
    unavailable_count = int(validation.get("unidentified_periods", 0))
    unavailable_days = int(validation.get("unidentified_days", 0))
    data = data.loc[data.domain.isin(DOMAINS)].copy()
    if data.duplicated(['domain', 'configuration_id']).any():
        raise ValueError('Duplicate cross-domain configuration.')
    counts = {domain: (len(group), int(group.inversion.sum()))
              for domain, group in data.groupby('domain')}
    if set(data.loc[data.domain == 'k=0', 'ideological_universe']) != {'seat_winning'}:
        raise ValueError('Primary ideological panel requires the seat-winning universe.')
    # Rounded design limits retain the approved shared framing without reading
    # the diagnostic k=1 panel or any of its outputs.
    xlim = (min(-11.3, float(data.A_pct_quota.min()) - 1.2), max(12.1, float(data.A_pct_quota.max()) + 1.2))
    ylim = (min(-5.7, float(data.B_pct_quota.min()) - .8), max(5.0, float(data.B_pct_quota.max()) + .8))
    with plt.rc_context({
        'font.family': 'DejaVu Sans', 'font.size': 9.5,
        'axes.spines.top': False, 'axes.spines.right': False,
        'pdf.fonttype': 42, 'ps.fonttype': 42,
    }):
        fig, axes = plt.subplots(1, 2, figsize=(7.6, 4.5), sharex=True, sharey=True)
        titles = ('A  Cabinet party sets',
                  'B  Minimal connected winning coalitions')
        for ax, domain, title in zip(axes, DOMAINS, titles):
            group = data.loc[data.domain == domain]
            zero_quota = int(group.q_C.eq(0).sum())
            ax.axhline(0, color='#9a9fa4', lw=.65, zorder=0)
            ax.axvline(0, color='#9a9fa4', lw=.65, zorder=0)
            ax.plot(xlim, [-xlim[0], -xlim[1]], color='#67727a', lw=.85,
                    ls=(0, (4, 3)), zorder=1)
            ax.grid(alpha=.10, lw=.5)
            for year in YEARS:
                ordinary = group.loc[(group.election == year) & ~group.inversion]
                ax.scatter(ordinary.A_pct_quota, ordinary.B_pct_quota, s=28,
                           c=COLORS[year], edgecolors='none', alpha=.65, zorder=2)
            for year in YEARS:
                inverted = group.loc[(group.election == year) & group.inversion]
                ax.scatter(inverted.A_pct_quota, inverted.B_pct_quota, s=62,
                           c=COLORS[year], edgecolors='#20252b', linewidths=1.15,
                           alpha=.95, zorder=3)
            ax.set(xlim=xlim, ylim=ylim)
            ax.xaxis.set_major_locator(MultipleLocator(5))
            ax.yaxis.set_major_locator(MultipleLocator(2))
            ax.tick_params(labelsize=9)
            ax.set_title(title, fontsize=10, loc='left', pad=38 if unavailable_count else 29)
            unit = 'party sets' if domain == 'cabinet' else 'configurations'
            count_label = f'{len(group)} {unit}; {int(group.inversion.sum())} inversions'
            if zero_quota:
                count_label += f'\n{zero_quota} zero-quota sets (normalized coordinates unavailable)'
            if domain == 'cabinet' and unavailable_count:
                count_label += f'\n{unavailable_count} unidentified intervals ({unavailable_days} days), unplotted'
            ax.text(0, 1.025,
                    count_label,
                    transform=ax.transAxes, fontsize=8.3 if domain == 'cabinet' and unavailable_count else 9.5, va='bottom')

        def label(ax, row, text, position):
            ax.annotate(text, (row.A_pct_quota, row.B_pct_quota), xytext=position,
                        textcoords='data', ha='center', va='center', fontsize=9.5,
                        zorder=5, arrowprops=dict(arrowstyle='-', color='#69747c',
                                                  lw=.6, shrinkA=2, shrinkB=5))

        cabinet_inversions = data.loc[(data.domain == 'cabinet') & data.inversion]
        if cabinet_inversions.empty:
            axes[0].text(.04, .96, 'No identified cabinet inversions', transform=axes[0].transAxes,
                         ha='left', va='top', fontsize=8.5, color='#555555')
        for number, row in enumerate(cabinet_inversions.itertuples()):
            position = (max(xlim[0] + 1.5, min(xlim[1] - 1.5, row.A_pct_quota + (-1.5 if number % 2 else 1.5))),
                        max(ylim[0] + .5, min(ylim[1] - .5, row.B_pct_quota + (.7 if number % 2 else -.7))))
            label(axes[0], row, row.display_label, position)
        focal = data.loc[(data.domain == 'k=0') & data.inversion &
                         (data.is_strongest_inversion | (data.B_C > data.A_C))]
        for number, row in enumerate(focal.itertuples()):
            text = f'{row.election} {row.start_party}-{row.end_party}'
            # Distribute annotations within the shared plot limits; the point
            # identity and text always come from the regenerated registry.
            position = (max(xlim[0] + 3, min(xlim[1] - 3, row.A_pct_quota - 2.4)),
                        max(ylim[0] + .7, min(ylim[1] - .6, row.B_pct_quota + 1.1 + .25 * (number % 2))))
            # The 2014 strongest case sits below a tight cluster of 2018
            # points. Place its annotation in the open lower-right area.
            if row.election == 2014 and row.is_strongest_inversion:
                position = (min(xlim[1] - 3, row.A_pct_quota + 2.5), row.B_pct_quota - 1.7)
            label(axes[1], row, text, position)

        fig.supxlabel('Within-district contribution (% of coalition quota)', y=.125, fontsize=10)
        fig.supylabel('Between-district contribution (% of coalition quota)', x=.016, fontsize=10)
        handles = [Line2D([], [], ls='', marker='o', mfc=COLORS[year], mec='none',
                          label=str(year), markersize=6) for year in YEARS]
        handles.extend([
            Line2D([], [], ls='', marker='o', mfc='white', mec='#20252b', mew=1.15,
                   label='Inversion (outlined)', markersize=7),
            Line2D([], [], color='#67727a', lw=.85, ls=(0, (4, 3)),
                   label=r'Diagonal: $R_C=1$'),
        ])
        fig.legend(handles=handles, ncol=5, loc='lower center', bbox_to_anchor=(.53, .015),
                   frameon=False, handlelength=1.5, columnspacing=1.1, fontsize=9.5)
        fig.subplots_adjust(left=.105, right=.99, bottom=.25, top=.77 if unavailable_count else .80, wspace=.14)
        output.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(output, facecolor='white', metadata={'CreationDate': None, 'ModDate': None})
        plt.close(fig)
    return output


def save_cross_domain_components(artifact_root: Path, figure_dir: Path) -> Path:
    data = pd.read_csv(artifact_root / 'figure_data/cross_domain_components.csv', float_precision='round_trip')
    data = data.loc[data.ideological_universe.isin(['not_applicable', 'seat_winning']) & data.domain.isin(DOMAINS)].copy()
    missing = read_csv(artifact_root / 'raw/cabinet_unidentified_intervals.csv')
    data.attrs['validation'] = {'unidentified_periods': len(missing), 'unidentified_days': int(missing.days.sum())}
    return render_cross_domain_components(data, figure_dir / 'cross_domain_components.pdf')

def check(condition, message):
    if not condition:
        raise ValueError(message)

def build_cabinet_figure(cases, orders) -> plt.Figure:
    """Two ordinal membership panels, with Figure 3's type, labels and PT diamond."""
    with plt.rc_context({'font.family': 'DejaVu Sans', 'pdf.fonttype': 42}):
        fig, axes = plt.subplots(2, 1, figsize=(6.4, 5.0))
        axes[0].set_position([.035, .78, .95, .08])
        axes[1].set_position([.035, .34, .95, .08])
        for ax, row, panel, name in zip(axes, cases, ('a', 'b'), ('Dilma Rousseff', 'Lula III'), strict=True):
            year = int(row['election_year'])
            order = orders[year]
            membership = set(row['canonical_membership'].split(';'))
            for party, position in zip(order['party'], order['ordinal_position'], strict=True):
                member = party in membership
                ax.plot(position, 0, linestyle='none', marker='D' if party=='PT' else 'o',
                        markersize=7 if party=='PT' else (6.2 if member else 4.5),
                        markerfacecolor='black' if member else 'white',
                        markeredgecolor='black' if member else '#777777',
                        markeredgewidth=.9, zorder=4)
            ax.set_xticks(order['ordinal_position'], order['party'], rotation=90,
                          fontsize=9, ha='center', va='top')
            for label in ax.get_xticklabels():
                label.set_fontweight('bold' if label.get_text() in membership else 'normal')
            ax.tick_params(axis='x', length=0, pad=7, labelrotation=90)
            ax.set_yticks([])
            for spine in ax.spines.values():
                spine.set_visible(False)
            # The light baseline spans the entire party order, not the coalition.
            ax.spines['bottom'].set_visible(True)
            ax.spines['bottom'].set_position(('data', 0))
            ax.spines['bottom'].set_bounds(1, len(order))
            ax.spines['bottom'].set_color('#cccccc')
            ax.spines['bottom'].set_linewidth(.55)
            ax.set_xlim(.35, len(order)+.65)
            ax.set_ylim(-.12, .38)
            start, end = (date.fromisoformat(row[field]) for field in ('first_observed', 'last_observed'))
            if start.month == end.month and start.year == end.year:
                dates = f'{start.day}–{end.day} {end:%B %Y}'
            else:
                dates = f'{start.day} {start:%B}–{end.day} {end:%B %Y}'
            # Dates and electoral quantities come from the cabinet registry.
            ax.set_title(f"({panel}) {name} | {year} election | set {row['display_label']}\n"
                         f"{dates} | {100*float(row['vote_share']):.2f}% votes, {row['seats']} seats",
                         fontsize=10, pad=5, linespacing=1.55)
        handles = [Line2D([], [], color='black', marker='o', linestyle='none', markersize=6.2, label='Cabinet member'),
                   Line2D([], [], color='#777777', markerfacecolor='white', marker='o', linestyle='none', markersize=4.5, label='Nonmember'),
                   Line2D([], [], color='black', marker='D', linestyle='none', markersize=7, label='PT (cabinet member)')]
        fig.legend(handles=handles, loc='lower center', bbox_to_anchor=(.5,.04),
                   ncol=3, frameon=False, fontsize=9, handletextpad=.45, columnspacing=1.4)
        fig.text(.5,.005,'Seat-winning parties ordered from left to right (equally spaced)',
                 ha='center', va='bottom', fontsize=9)
    return fig


def save_cabinet_membership(artifact_root, figure_dir):
    path = artifact_root.parent / 'accounting/raw/cabinet_party_set_accounting.csv'
    cabinets = read_csv(path).to_dict('records')
    # Read identifiers/dates as strings, preserving the original rendering operands.
    import csv
    with path.open(newline='', encoding='utf-8') as handle:
        cabinets = list(csv.DictReader(handle))
    cases = [next(r for r in cabinets if r['display_label'] == label) for label in ('14-05','22-01')]
    orders = {year: read_csv(artifact_root / 'raw' / f'ideology_order_{year}.csv')[['party','ordinal_position']] for year in YEARS}
    figure = build_cabinet_figure(cases, orders)
    output = figure_dir / 'cabinet_membership_inversions.pdf'
    try:
        figure.canvas.draw()
        renderer = figure.canvas.get_renderer()
        labels = [label for ax in figure.axes for label in ax.get_xticklabels()]
        check(all(label.get_rotation() == 90 for label in labels), 'Party labels must remain vertical')
        boxes = [item.get_window_extent(renderer) for item in [*labels, *(ax.title for ax in figure.axes), *figure.texts, *figure.legends]]
        check(all(figure.bbox.contains(bb.x0, bb.y0) and figure.bbox.contains(bb.x1, bb.y1) for bb in boxes), 'Figure label clipped')
        check(not any(a.overlaps(b) for i,a in enumerate(boxes) for b in boxes[i+1:]), 'Overlapping figure labels')
        with plt.rc_context({'pdf.fonttype': 42}):
            figure.savefig(output, facecolor='white', metadata={'CreationDate': None, 'ModDate': None})
    finally:
        plt.close(figure)
    return output

def generate_figures(artifact_root: Path, figure_dir: Path) -> list[Path]:
    figure_dir.mkdir(parents=True, exist_ok=True)
    outputs = [
        save_party_vote_share_vs_seat_share(artifact_root, figure_dir),
        save_observed_coalition_timeline(artifact_root, figure_dir),
        save_inversion_decomposition_components(artifact_root, figure_dir),
        save_accounting_state_weighting_anatomy(artifact_root, figure_dir),
    ]
    outputs.extend(save_ideological_interval_heatmaps(artifact_root, figure_dir))
    outputs.extend(save_minimal_connected_winning_inversions(artifact_root, figure_dir))
    outputs.append(
        save_district_electoral_weight_by_magnitude(artifact_root, figure_dir)
    )
    outputs.append(save_cross_domain_components(artifact_root, figure_dir))
    # This appendix figure previously ran in a fresh process. Preserve its
    # defaults after the district diagnostic's established global style update.
    with plt.rc_context(plt.rcParamsDefault):
        outputs.append(save_cabinet_membership(artifact_root, figure_dir))
    return outputs


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate figures for the coalition inversions manuscript.")
    parser.add_argument(
        "--artifact-root",
        type=Path,
        default=DEFAULT_ARTIFACT_ROOT,
        help=f"Path to build/results/domains. Default: {DEFAULT_ARTIFACT_ROOT}",
    )
    parser.add_argument(
        "--figure-dir",
        type=Path,
        default=DEFAULT_FIGURE_DIR,
        help=f"Directory where figures should be written. Default: {DEFAULT_FIGURE_DIR}",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    outputs = generate_figures(args.artifact_root.expanduser(), args.figure_dir.expanduser())
    print("Generated figures:")
    for path in outputs:
        print(f"- {path}")


if __name__ == "__main__":
    main()
