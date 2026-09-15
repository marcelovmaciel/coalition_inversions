from __future__ import annotations

import csv
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path


DECOMPOSITION_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DECOMPOSITION_DIR))

import audit_empirical_assets as audit  # noqa: E402


class EmpiricalAssetAuditTests(unittest.TestCase):
    def _fixture(self, temporary_root: str) -> dict[str, Path]:
        repo = Path(temporary_root) / "repo"
        paper = repo / "processing" / "Processing" / "output" / "paper"
        raw = paper / "raw"
        raw.mkdir(parents=True)
        data_path = raw / "example.csv"
        data_path.write_text("case,value\nA,1\n", encoding="utf-8")

        manifest_path = paper / "artifact_manifest.csv"
        with manifest_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=("path", "artifact_type", "description", "rows", "columns"),
                lineterminator="\n",
            )
            writer.writeheader()
            writer.writerow(
                {
                    "path": "raw/example.csv",
                    "artifact_type": "raw",
                    "description": "Fixture data.",
                    "rows": 1,
                    "columns": 2,
                }
            )
            writer.writerow(
                {
                    "path": "artifact_manifest.csv",
                    "artifact_type": "manifest",
                    "description": "Fixture manifest.",
                    "rows": 2,
                    "columns": 5,
                }
            )

        review = repo / "writing" / "submission_inversions_review"
        manuscript = review / "manuscript"
        manuscript.mkdir(parents=True)
        main_tex = manuscript / "main.tex"
        main_tex.write_text(
            "\\documentclass{article}\n"
            "% \\input{commented_out_missing}\n"
            "\\input{generated_table}\n"
            "\\includegraphics[width=.8\\textwidth]\n"
            "  {generated_figure}\n",
            encoding="utf-8",
        )
        title_page = review / "title_page.tex"
        title_page.write_text("\\documentclass{article}\n", encoding="utf-8")
        table_path = manuscript / "generated_table.tex"
        table_path.write_text("fixture table\n", encoding="utf-8")
        figure_path = manuscript / "generated_figure.pdf"
        figure_path.write_bytes(b"%PDF-1.4\nfixture figure\n%%EOF\n")
        (manuscript / "unreferenced_table.tex").write_text(
            "unreferenced\n", encoding="utf-8"
        )

        return {
            "repo": repo,
            "manifest": manifest_path,
            "data": data_path,
            "main": main_tex,
            "title": title_page,
            "manuscript": manuscript,
            "table": table_path,
            "figure": figure_path,
            "audit": (
                repo
                / "processing"
                / "Processing"
                / "output"
                / "decomposition"
                / "audit"
            ),
        }

    def test_writes_paper_hashes_and_manuscript_reference_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            fixture = self._fixture(temporary_root)
            result = audit.run_audit(
                paper_manifest=fixture["manifest"],
                manuscript_sources=(fixture["main"], fixture["title"]),
                audit_directory=fixture["audit"],
                repository_root=fixture["repo"],
                generated_manuscript_directory=fixture["manuscript"],
            )

            with result.paper_hash_path.open(
                "r", encoding="utf-8", newline=""
            ) as handle:
                paper_rows = list(csv.DictReader(handle))
            self.assertEqual(
                {row["path"] for row in paper_rows},
                {"artifact_manifest.csv", "raw/example.csv"},
            )
            data_row = next(
                row for row in paper_rows if row["path"] == "raw/example.csv"
            )
            self.assertEqual(int(data_row["bytes"]), fixture["data"].stat().st_size)
            self.assertEqual(
                data_row["sha256"],
                hashlib.sha256(fixture["data"].read_bytes()).hexdigest(),
            )

            with result.manuscript_reference_path.open(
                "r", encoding="utf-8", newline=""
            ) as handle:
                reader = csv.DictReader(handle)
                self.assertEqual(reader.fieldnames, ["reference_source", "reference_kind", "target"])
                manuscript_rows = list(reader)
            self.assertEqual(len(manuscript_rows), 2)
            self.assertEqual(
                {(row["reference_source"].rsplit(":", 1)[1], row["reference_kind"])
                 for row in manuscript_rows},
                {("3", "input"), ("4", "includegraphics")},
            )
            self.assertEqual(
                {row["target"] for row in manuscript_rows},
                {
                    (
                        "writing/submission_inversions_review/manuscript/"
                        "generated_table.tex"
                    ),
                    (
                        "writing/submission_inversions_review/manuscript/"
                        "generated_figure.pdf"
                    ),
                },
            )
            self.assertEqual(
                [path.name for path in result.unreferenced_manuscript_assets],
                ["unreferenced_table.tex"],
            )

    def test_rendering_changes_do_not_change_reference_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            fixture = self._fixture(temporary_root)
            before = audit.audit_manuscript_references([fixture["main"]])
            fixture["table"].write_text("Revised table rendering\n", encoding="utf-8")
            fixture["figure"].write_bytes(b"Updated PDF rendering")
            self.assertEqual(before, audit.audit_manuscript_references([fixture["main"]]))

    def test_tracks_image_formats_and_reports_unreferenced_images(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            fixture = self._fixture(temporary_root)
            with fixture["main"].open("a", encoding="utf-8") as source:
                for suffix in ("png", "jpg", "jpeg"):
                    source.write("\\includegraphics{image." + suffix + "}\n")
                    (fixture["manuscript"] / ("image." + suffix)).write_bytes(b"image")
            orphan = fixture["manuscript"] / "orphan.png"
            orphan.write_bytes(b"unreferenced")
            records = audit.audit_manuscript_references([fixture["main"]])
            self.assertEqual(len(records), 5)
            self.assertIn(orphan, audit.find_unreferenced_manuscript_assets(
                fixture["manuscript"], records, manuscript_sources=[fixture["main"]],
            ))

    def test_fails_if_paper_manifest_lists_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            fixture = self._fixture(temporary_root)
            with fixture["manifest"].open(
                "a", encoding="utf-8", newline=""
            ) as handle:
                writer = csv.writer(handle, lineterminator="\n")
                writer.writerow(
                    ("raw/missing.csv", "raw", "Missing fixture.", 1, 1)
                )

            with self.assertRaisesRegex(
                audit.AuditError, r"missing files: raw/missing\.csv"
            ):
                audit.run_audit(
                    paper_manifest=fixture["manifest"],
                    manuscript_sources=(fixture["main"], fixture["title"]),
                    audit_directory=fixture["audit"],
                    repository_root=fixture["repo"],
                )
            self.assertFalse(fixture["audit"].exists())

    def test_fails_if_manuscript_generated_target_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            fixture = self._fixture(temporary_root)
            fixture["figure"].unlink()

            with self.assertRaisesRegex(
                audit.AuditError, r"missing generated asset target\(s\)"
            ):
                audit.run_audit(
                    paper_manifest=fixture["manifest"],
                    manuscript_sources=(fixture["main"], fixture["title"]),
                    audit_directory=fixture["audit"],
                    repository_root=fixture["repo"],
                )
            self.assertFalse(fixture["audit"].exists())


if __name__ == "__main__":
    unittest.main()
