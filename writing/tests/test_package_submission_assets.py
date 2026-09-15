from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile
from unittest.mock import patch

from writing import package_submission_assets as package


class DeterministicSubmissionPackageTests(unittest.TestCase):
    def test_archive_is_stable_and_has_fixed_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            first = root / "b.txt"
            second = root / "a.txt"
            first.write_text("second alphabetically\n", encoding="utf-8")
            second.write_text("first alphabetically\n", encoding="utf-8")
            destination = root / "assets.zip"

            package.write_deterministic_zip(
                destination, [first, second]
            )
            first_bytes = destination.read_bytes()
            package.write_deterministic_zip(
                destination, [second, first]
            )

            self.assertEqual(first_bytes, destination.read_bytes())
            with ZipFile(destination) as archive:
                self.assertEqual(archive.namelist(), ["a.txt", "b.txt"])
                self.assertTrue(
                    all(info.date_time == package.FIXED_ZIP_TIME for info in archive.infolist())
                )

    def test_missing_input_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            with self.assertRaises(FileNotFoundError):
                package.write_deterministic_zip(
                    root / "assets.zip", [root / "missing.txt"]
                )


    def test_packages_authoritative_source_and_referenced_inputs(self) -> None:
        self.assertEqual(package.MAIN_TEX.name, "main_rw_again.tex")
        tables, figures = package.referenced_assets()
        self.assertIn("table_appendix_domain_counts_compact.tex", {p.name for p in tables})
        self.assertIn("table_accounting_minimal_ideological.tex", {p.name for p in tables})
        self.assertNotIn("manuscript_values.tex", {p.name for p in tables})
        self.assertNotIn("accounting_numeric_macros.tex", {p.name for p in tables})
        self.assertNotIn("AccountingIntegration.jl", {p.name for p in package.manuscript_tex_sources()})
        self.assertEqual(set(package.manuscript_tex_sources()), {package.MAIN_TEX, *tables})
        self.assertNotIn("main.tex", {p.name for p in package.manuscript_tex_sources()})
        self.assertEqual((len(tables), len(figures)), (6, 9))
        self.assertIn(
            package.MANUSCRIPT_ROOT / "figures/minimal_connected_winning_inversions_3x1_diamond.png",
            figures,
        )
        self.assertNotIn("party_vote_share_vs_seat_share.pdf", {p.name for p in figures})
        package.require_files(tables + figures)

    def test_rejects_missing_extra_duplicate_and_stale_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.tex"
            source.write_text("current", encoding="utf-8")
            destination = root / "assets.zip"
            for members, message in (
                ([], "membership mismatch"),
                ([("source.tex", "current"), ("extra.tex", "extra")], "membership mismatch"),
                ([("source.tex", "current"), ("source.tex", "current")], "membership mismatch"),
                ([("source.tex", "stale")], "content mismatch"),
            ):
                with self.subTest(members=members):
                    with ZipFile(destination, "w") as archive:
                        for name, content in members:
                            archive.writestr(name, content)
                    with self.assertRaisesRegex(ValueError, message):
                        package.verify_zip(destination, [source])

    def test_writer_verifies_after_closing_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.tex"
            source.write_text("current", encoding="utf-8")
            with patch.object(package, "verify_zip", side_effect=ValueError("content mismatch")):
                with self.assertRaisesRegex(ValueError, "content mismatch"):
                    package.write_deterministic_zip(root / "assets.zip", [source])

    def test_preserves_relative_paths_and_rejects_different_manuscript_archives(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "figures" / "plot.png"
            source.parent.mkdir()
            source.write_bytes(b"current image")
            inner, outer = root / "inner.zip", root / "outer.zip"
            for destination in (inner, outer):
                package.write_deterministic_zip(destination, [source], source_root=root)
            with ZipFile(inner) as archive:
                self.assertEqual(archive.namelist(), ["figures/plot.png"])
            package.verify_manuscript_archives(inner, outer)
            source.write_bytes(b"different image")
            package.write_deterministic_zip(outer, [source], source_root=root)
            with self.assertRaisesRegex(ValueError, "archives differ"):
                package.verify_manuscript_archives(inner, outer)
            with ZipFile(outer, "w"):
                pass
            with self.assertRaisesRegex(ValueError, "different members"):
                package.verify_manuscript_archives(inner, outer)


if __name__ == "__main__":
    unittest.main()
