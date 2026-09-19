"""Render canonical district electoral-weight columns without recomputing them."""
from pathlib import Path
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter, NullLocator
import numpy as np
import pandas as pd

EXPECTED_YEARS = (2014, 2018, 2022)
POINT_COLOR = "#176B87"
REFERENCE_COLOR = "#6B7280"
GRID_COLOR = "#D8DEE6"

REQUIRED_COLUMNS = {
    "election_year",
    "electoral_unit",
    "V_d",
    "S_d",
    "V",
    "S",
    "district_vote_share",
    "district_seat_share",
    "district_valid_votes_per_seat",
    "national_valid_votes_per_seat",
    "district_electoral_weight",
    "district_electoral_weight_exact",
}
INTEGER_COLUMNS = ("election_year", "V_d", "S_d", "V", "S")
FLOAT_COLUMNS = (
    "district_vote_share",
    "district_seat_share",
    "district_valid_votes_per_seat",
    "national_valid_votes_per_seat",
    "district_electoral_weight",
)


def load_district_electoral_weight(input_path: Path) -> pd.DataFrame:
    """Read canonical state-year coordinates and require complete, finite columns."""
    if not input_path.is_file():
        raise FileNotFoundError(f"Required diagnostic input not found: {input_path}")

    data = pd.read_csv(input_path)
    missing = sorted(REQUIRED_COLUMNS.difference(data.columns))
    if missing:
        raise ValueError(f"Required columns missing from {input_path}: {', '.join(missing)}")

    for column in INTEGER_COLUMNS:
        numeric = pd.to_numeric(data[column], errors="raise")
        if not np.isfinite(numeric.to_numpy(dtype=float)).all():
            raise ValueError(f"{column} contains non-finite values in {input_path}")
        if not np.equal(numeric, np.floor(numeric)).all():
            raise ValueError(f"{column} contains non-integer values in {input_path}")
        data[column] = numeric.astype(int)

    for column in FLOAT_COLUMNS:
        numeric = pd.to_numeric(data[column], errors="raise")
        if not np.isfinite(numeric.to_numpy(dtype=float)).all():
            raise ValueError(f"{column} contains non-finite values in {input_path}")
        data[column] = numeric.astype(float)

    data["electoral_unit"] = data["electoral_unit"].astype(str).str.strip()
    if (data["electoral_unit"] == "").any():
        raise ValueError(f"Blank electoral-unit label in {input_path}")
    if data.duplicated(["election_year", "electoral_unit"]).any():
        raise ValueError(f"Duplicate state-year row in {input_path}")
    return data.sort_values(["election_year", "electoral_unit"]).reset_index(drop=True)


def _spread_log_positions(
    values: pd.Series,
    *,
    lower: float,
    upper: float,
    minimum_log_gap: float = 0.12,
) -> dict[int, float]:
    """Spread labels vertically on a log axis while preserving their order."""
    ordered = sorted(
        ((int(index), float(value)) for index, value in values.items()),
        key=lambda item: item[1],
    )
    logs = [float(np.log(value)) for _, value in ordered]
    lower_log = float(np.log(lower))
    upper_log = float(np.log(upper))

    for position in range(1, len(logs)):
        logs[position] = max(logs[position], logs[position - 1] + minimum_log_gap)
    if logs and logs[-1] > upper_log:
        shift = logs[-1] - upper_log
        logs = [value - shift for value in logs]
    for position in range(len(logs) - 2, -1, -1):
        logs[position] = min(logs[position], logs[position + 1] - minimum_log_gap)
    if logs and logs[0] < lower_log:
        shift = lower_log - logs[0]
        logs = [value + shift for value in logs]

    return {
        index: float(np.exp(log_value))
        for (index, _), log_value in zip(ordered, logs, strict=True)
    }


def render_district_electoral_weight(data: pd.DataFrame, output_path: Path) -> Path:
    """Render three year panels and save the standalone diagnostic PDF."""
    plt.rcParams.update(
        {
            "font.size": 9,
            "axes.titlesize": 11,
            "axes.labelsize": 10,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
        }
    )
    figure, axes = plt.subplots(
        1,
        len(EXPECTED_YEARS),
        figsize=(14.6, 5.5),
        sharex=True,
        sharey=True,
        constrained_layout=False,
    )
    y_limits = (0.5, 7.0)
    y_ticks = (0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0)
    y_tick_labels = ("0.5", "0.75", "1", "1.5", "2", "3", "4", "6")

    for axis, year in zip(axes, EXPECTED_YEARS, strict=True):
        selected = data.loc[data["election_year"] == year].copy()
        axis.scatter(
            selected["S_d"],
            selected["district_electoral_weight"],
            s=31,
            color=POINT_COLOR,
            edgecolor="white",
            linewidth=0.55,
            zorder=3,
        )
        axis.axhline(1.0, color=REFERENCE_COLOR, linewidth=1.0, linestyle=(0, (3, 2)), zorder=1)
        axis.set_yscale("log", base=2)
        axis.set_ylim(*y_limits)
        axis.set_xlim(2.5, 73.5)
        axis.yaxis.set_major_locator(FixedLocator(y_ticks))
        axis.yaxis.set_major_formatter(FixedFormatter(y_tick_labels))
        axis.yaxis.set_minor_locator(NullLocator())
        axis.set_xticks([8, 20, 30, 40, 50, 60, 70])
        axis.grid(axis="y", which="major", color=GRID_COLOR, linewidth=0.65, zorder=0)
        axis.grid(axis="x", which="major", color=GRID_COLOR, linewidth=0.45, alpha=0.55, zorder=0)
        axis.set_title(str(year), pad=8)
        axis.spines["top"].set_visible(False)
        axis.spines["right"].set_visible(False)
        axis.spines["left"].set_color("#89919A")
        axis.spines["bottom"].set_color("#89919A")

        floor = selected.loc[selected["S_d"] == 8]
        label_positions = _spread_log_positions(
            floor["district_electoral_weight"],
            lower=0.58,
            upper=6.55,
        )
        for index, row in floor.iterrows():
            axis.annotate(
                str(row["electoral_unit"]),
                xy=(float(row["S_d"]), float(row["district_electoral_weight"])),
                xytext=(5.7, label_positions[int(index)]),
                textcoords="data",
                ha="right",
                va="center",
                fontsize=7.2,
                color="#27313A",
                arrowprops={
                    "arrowstyle": "-",
                    "color": "#97A2AD",
                    "linewidth": 0.45,
                    "shrinkA": 1,
                    "shrinkB": 2,
                },
                bbox={
                    "boxstyle": "round,pad=0.08",
                    "facecolor": "white",
                    "edgecolor": "none",
                    "alpha": 0.82,
                },
                zorder=4,
            )

        directly_labeled = set(floor.index)
        low_magnitude = selected.loc[(selected["S_d"] > 8) & (selected["S_d"] <= 10)]
        extremes = pd.concat(
            [
                selected.nsmallest(2, "district_electoral_weight"),
                selected.nlargest(2, "district_electoral_weight"),
            ]
        ).drop_duplicates()
        remaining = pd.concat([low_magnitude, extremes]).drop_duplicates()
        remaining = remaining.loc[~remaining.index.isin(directly_labeled)]

        for index, row in remaining.iterrows():
            x_value = float(row["S_d"])
            y_value = float(row["district_electoral_weight"])
            if x_value >= 60:
                offset = (-6, 6)
                alignment = "right"
            elif int(index) % 2:
                offset = (5, -9)
                alignment = "left"
            else:
                offset = (5, 6)
                alignment = "left"
            axis.annotate(
                str(row["electoral_unit"]),
                xy=(x_value, y_value),
                xytext=offset,
                textcoords="offset points",
                ha=alignment,
                va="center",
                fontsize=7.5,
                fontweight="semibold" if str(row["electoral_unit"]) == "SP" else "normal",
                color="#27313A",
                bbox={
                    "boxstyle": "round,pad=0.08",
                    "facecolor": "white",
                    "edgecolor": "none",
                    "alpha": 0.78,
                },
                zorder=4,
            )

    figure.suptitle(
        "District electoral weight by district magnitude",
        x=0.51,
        y=0.98,
        fontsize=14,
        fontweight="semibold",
    )
    figure.text(
        0.51,
        0.932,
        "Each point is a state; 1 is the national seats-per-valid-vote rate.",
        ha="center",
        va="top",
        fontsize=9.5,
        color="#4B5563",
    )
    figure.supxlabel(r"District magnitude ($S_d$)", x=0.51, y=0.075, fontsize=10)
    figure.supylabel(
        r"District electoral weight $(S_d/V_d)/(513/V)$",
        x=0.035,
        y=0.52,
        fontsize=10,
    )
    figure.text(
        0.51,
        0.018,
        "Labels identify all 8–10-seat districts and the two lowest and highest "
        "weights in each election; "
        "the vertical scale is logarithmic.",
        ha="center",
        va="bottom",
        fontsize=8,
        color="#5F6872",
    )
    figure.subplots_adjust(left=0.085, right=0.985, bottom=0.16, top=0.865, wspace=0.12)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(
        output_path,
        bbox_inches="tight",
        metadata={
            "Title": "District electoral weight by district magnitude",
            "Author": "Reproducible electoral-inversions diagnostic",
        },
    )
    plt.close(figure)
    return output_path


