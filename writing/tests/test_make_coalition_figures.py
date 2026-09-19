import os
import sys
import tempfile
import unittest
from pathlib import Path

import pandas as pd


os.environ.setdefault("MPLBACKEND", "Agg")

REPO_ROOT = Path(__file__).resolve().parents[2]
WRITING_DIR = REPO_ROOT / "scripts"
sys.path.insert(0, str(WRITING_DIR))

import make_figures as figures  # noqa: E402


# A deliberately small fixture registry checks dynamic focal-case handling.
FIXTURE_STATE_WEIGHTING_CASES = (
    ("cabinet/test/first", "Cabinet first"),
    ("ideological/seat_winning/test/second", "Parliamentary second"),
    ("ideological/seat_winning/test/third", "Parliamentary third"),
)


def state_weighting_fixture() -> pd.DataFrame:
    rows = []
    for focal_order, (case_id, case_display) in enumerate(
        FIXTURE_STATE_WEIGHTING_CASES, start=1
    ):
        positive_eight = 3.0 + 0.25 * focal_order
        positive_other = 2.0
        negative_sp = 4.0
        negative_other = 1.5
        rows.append(
            {
                "case_id": case_id,
                "case_display": case_display,
                "case_order": 100 - focal_order,
                "focal_order": focal_order,
                "b_positive_eight_seat": positive_eight,
                "b_positive_other": positive_other,
                "b_negative_sp": negative_sp,
                "b_negative_other": negative_other,
                "B_C": positive_eight + positive_other - negative_sp - negative_other,
                "largest_positive_state": "RR",
                "largest_positive_b_Cd": 1.25,
            }
        )
    return pd.DataFrame(rows[::-1])


def write_state_weighting_fixture(artifact_root: Path, data: pd.DataFrame) -> Path:
    figure_data_dir = artifact_root.parent / "accounting/figure_data"
    figure_data_dir.mkdir(parents=True, exist_ok=True)
    path = figure_data_dir / "accounting_state_weighting_anatomy.csv"
    data.to_csv(path, index=False)
    tables_dir = artifact_root.parent / "accounting/tables"
    tables_dir.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(FIXTURE_STATE_WEIGHTING_CASES, columns=["case_id", "case_display"]).to_csv(
        tables_dir / "table_accounting_focal_cases.csv", index=False
    )
    return path


class StateWeightingAnatomyRegressions(unittest.TestCase):
    def test_loader_accepts_generated_case_registry_and_sorts_focal_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="state-weighting-loader-") as temp_dir:
            artifact_root = Path(temp_dir) / "domains"
            write_state_weighting_fixture(artifact_root, state_weighting_fixture())
            loaded = figures.load_accounting_state_weighting_anatomy(artifact_root)

        self.assertEqual(tuple(loaded["focal_order"]), tuple(range(1, len(FIXTURE_STATE_WEIGHTING_CASES) + 1)))
        self.assertEqual(
            tuple(loaded["case_id"]),
            tuple(case_id for case_id, _ in FIXTURE_STATE_WEIGHTING_CASES),
        )
        self.assertEqual(len(loaded), len(FIXTURE_STATE_WEIGHTING_CASES))

    def test_loader_rejects_missing_schema_column(self) -> None:
        with tempfile.TemporaryDirectory(prefix="state-weighting-schema-") as temp_dir:
            artifact_root = Path(temp_dir) / "domains"
            data = state_weighting_fixture().drop(columns="b_negative_sp")
            write_state_weighting_fixture(artifact_root, data)
            with self.assertRaisesRegex(ValueError, "b_negative_sp"):
                figures.load_accounting_state_weighting_anatomy(artifact_root)

    def test_loader_rejects_changed_focal_registry(self) -> None:
        with tempfile.TemporaryDirectory(prefix="state-weighting-registry-") as temp_dir:
            artifact_root = Path(temp_dir) / "domains"
            data = state_weighting_fixture()
            data.loc[data.index[0], "case_id"] = "ideological/2022/unrestricted"
            write_state_weighting_fixture(artifact_root, data)
            with self.assertRaisesRegex(ValueError, "differs from the generated focal registry"):
                figures.load_accounting_state_weighting_anatomy(artifact_root)

    def test_renderer_writes_pdf_from_validated_csv(self) -> None:
        with tempfile.TemporaryDirectory(prefix="state-weighting-render-") as temp_dir:
            root = Path(temp_dir)
            artifact_root = root / "artifacts"
            output_dir = root / "figures"
            output_dir.mkdir()
            write_state_weighting_fixture(artifact_root, state_weighting_fixture())
            output = figures.save_accounting_state_weighting_anatomy(
                artifact_root, output_dir
            )
            self.assertEqual(output.read_bytes()[:5], b"%PDF-")


class CabinetUnavailableAndEmptyTests(unittest.TestCase):
    def test_decimal_looking_period_identifiers_remain_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "periods.csv"
            path.write_text("period,cabinet_period,value\n2015.1,2015.1,1\n2015.10,2015.10,2\n")
            rows = figures.read_csv(path)
            self.assertEqual(list(rows.period), ["2015.1", "2015.10"])
            self.assertEqual(list(rows.cabinet_period), ["2015.1", "2015.10"])

    def test_no_inversions_and_unidentified_interval_render(self):
        with tempfile.TemporaryDirectory(prefix="cabinet-unidentified-") as directory:
            root = Path(directory) / "domains"
            (root.parent / "accounting/figure_data").mkdir(parents=True)
            (root / "figure_data").mkdir(parents=True)
            (root / "raw").mkdir()
            (root / "figures").mkdir()
            pd.DataFrame([dict(election_year=2014, period="14-01", cabinet_party_set_id="synthetic-pt",
                display_label="14-01", first_observed="2015-01-01",
                period_start="2015-01-01", period_end="2015-01-03",
                vote_share=.4, seat_share=200 / 513, seats=200,
                representation_ratio=200 / (.4 * 513), coalition_inversion=False)]).to_csv(
                root / "raw/cabinet_party_sets.csv", index=False)
            pd.DataFrame(columns=["coalition_id", "election_year", "cabinet_period", "component", "seats"]).to_csv(
                root.parent / "accounting/figure_data/inversion_decomposition_components.csv", index=False)
            pd.DataFrame([dict(period_id="fixture-unidentified", start_inclusive="2015-01-04",
                end_exclusive="2015-01-07", days=3)]).to_csv(root / "raw/cabinet_unidentified_intervals.csv", index=False)
            self.assertTrue(figures.load_inversion_decomposition_components(root).empty)
            gaps = figures.load_cabinet_unidentified_intervals(root)
            self.assertEqual(int(gaps.days.sum()), 3)
            self.assertEqual(len(figures.load_observed_coalition_timeline(root)), 1)
            for render in (figures.save_inversion_decomposition_components, figures.save_observed_coalition_timeline):
                path = render(root, root / "figures")
                self.assertEqual(path.read_bytes()[:5], b"%PDF-")

    def test_gap_duration_is_not_silently_inclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "raw").mkdir()
            pd.DataFrame([dict(start_inclusive="2015-01-04", end_exclusive="2015-01-07", days=4)]).to_csv(
                root / "raw/cabinet_unidentified_intervals.csv", index=False)
            with self.assertRaisesRegex(ValueError, "durations"):
                figures.load_cabinet_unidentified_intervals(root)



class TableInputAndNumericTests(unittest.TestCase):
    def test_required_csv_and_unique_selection_fail_closed(self):
        import make_tables as tables
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'table.csv'
            for value in ('', 'year,year\n1,1\n', 'year,value\n2014\n', 'year\n2014\n'):
                path.write_text(value)
                with self.subTest(csv=value),self.assertRaises(ValueError):tables.read_rows(path,{'year','value'})
            with self.assertRaises(ValueError):tables.one([],year='2014')
            with self.assertRaises(ValueError):tables.one([{'year':'2014'}]*2,year='2014')

    def test_percent_rounding_does_not_change_inversion_marker(self):
        import make_tables as tables
        rows=[dict(election_year='2014',start_party='A',end_party='B',vote_share='0.4999999',
                   seats='257',seat_diff='0.5000513',coalition_inversion='true')]
        result=tables.interval_table(rows)
        data=[line for line in result.splitlines() if line.startswith('2014 &')]
        self.assertEqual(len(data),1)
        cells=[part.strip() for part in data[0].split('&')]
        self.assertEqual(len(cells),5)
        self.assertEqual(cells[2:4],['50.00','257'])
        self.assertIn(r'\(^{*}\)',cells[1])
        self.assertTrue(cells[4].startswith('0.50 '))
        self.assertEqual(result.count(r'\begin{tabular}'),result.count(r'\end{tabular}'))
