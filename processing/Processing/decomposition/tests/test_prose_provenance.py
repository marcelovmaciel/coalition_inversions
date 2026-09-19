from __future__ import annotations

import csv
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_prose_provenance import ProvenanceError, parse_blocks, validate_provenance
from manuscript_results import build_results, write_results

EXAMPLE = """There are four inversions with 47.25 percent of the vote.

% PROVENANCE-BEGIN example-claim
% source: output.csv
% row:
%   key: election=2018; universe=seat_winning
%   row_at_generation: 1
%   fields:
%     count: 4
%     vote_share: 0.4725
%   display:
%     count: four
%     vote_share: 47.25
% PROVENANCE-END example-claim
"""


class ProseProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manuscript = self.root / "main_rw_again.tex"
        self.manuscript.write_text(EXAMPLE)
        self.csv = self.root / "output.csv"
        self.csv.write_text("election,universe,count,vote_share\n2018,seat_winning,4,0.4725\n2014,seat_winning,2,0.45\n")

    def validate(self, text=None):
        if text is not None:
            self.manuscript.write_text(text)
        return validate_provenance(self.manuscript, self.root)

    def test_semantic_key_survives_reorder_and_reports_current_data_row(self):
        records, warnings = self.validate()
        self.assertEqual(len(records), 2)
        self.assertFalse(warnings)
        self.csv.write_text("election,universe,count,vote_share\n2014,seat_winning,2,0.45\n2018,seat_winning,4,0.4725\n")
        records, warnings = self.validate()
        self.assertEqual(records[0]["current_row"], 2)
        self.assertEqual(records[0]["row_at_generation"], 1)
        self.assertEqual(len(warnings), 1)

    def test_missing_source(self):
        self.csv.unlink()
        with self.assertRaisesRegex(ProvenanceError, "missing source"):
            self.validate()

    def test_zero_and_multiple_matching_rows(self):
        with self.assertRaisesRegex(ProvenanceError, "resolves to 0 rows"):
            self.validate(EXAMPLE.replace("election=2018", "election=2022"))
        self.csv.write_text(self.csv.read_text() + "2018,seat_winning,4,0.4725\n")
        with self.assertRaisesRegex(ProvenanceError, "resolves to 2 rows"):
            self.validate(EXAMPLE)

    def test_missing_fields_and_keys(self):
        for text in [EXAMPLE.replace("count:", "unknown:"), EXAMPLE.replace("election=", "missing=")]:
            with self.subTest(text=text), self.assertRaisesRegex(ProvenanceError, "unknown CSV field"):
                self.validate(text)

    def test_raw_numeric_and_string_drift(self):
        for replacement in ["5,0.4725", "4,0.472500000000001", "four,0.4725"]:
            self.csv.write_text("election,universe,count,vote_share\n2018,seat_winning," + replacement + "\n")
            with self.subTest(replacement=replacement), self.assertRaisesRegex(ProvenanceError, "recorded"):
                self.validate()

    def test_equal_numeric_notation_is_allowed(self):
        self.validate(EXAMPLE.replace("count: 4", "count: 4.0").replace("0.4725", "4.725e-1"))

    def test_display_is_local_and_word_bounded(self):
        for text in [EXAMPLE.replace("There are four", "There are fourteen"),
                     EXAMPLE.replace("with 47.25", "with 147.25"),
                     EXAMPLE.replace("\n\n% PROVENANCE-BEGIN", "\n\nUnrelated paragraph.\n\n% PROVENANCE-BEGIN")]:
            with self.subTest(text=text), self.assertRaisesRegex(ProvenanceError, "immediately preceding"):
                self.validate(text)
        self.validate(EXAMPLE.replace("47.25 percent", "47.25\npercent"))

    def test_malformed_blocks_fail(self):
        mutations = [
            EXAMPLE.replace("% PROVENANCE-END example-claim", ""),
            EXAMPLE.replace("% PROVENANCE-END example-claim", "% PROVENANCE-END wrong-id"),
            EXAMPLE.replace("% PROVENANCE-BEGIN example-claim", "% PROVENANCE-BEGIN"),
            EXAMPLE.replace("% source: output.csv", "% row:\n% source: output.csv"),
            EXAMPLE.replace("%   key:", "% key:"),
            EXAMPLE.replace("%   key: election=2018; universe=seat_winning", "%   key: election=2018; election=2014"),
            EXAMPLE.replace("%   row_at_generation: 1\n", ""),
            EXAMPLE.replace("%   row_at_generation: 1", "%   row_at_generation: 0"),
            EXAMPLE.replace("%   fields:", "%   fields:\n%     count: 4"),
            EXAMPLE.replace("%   fields:", "not a comment"),
            EXAMPLE.replace("%   display:", "%   unknown:"),
            EXAMPLE.replace("% PROVENANCE-END", "% source: output.csv\n% PROVENANCE-END"),
            EXAMPLE + EXAMPLE,
            EXAMPLE.replace("% source:", "% PROVENANCE-BEGIN nested\n% source:"),
            "% PROVENANCE-END unmatched\n",
        ]
        for text in mutations:
            with self.subTest(text=text), self.assertRaises(ProvenanceError):
                self.validate(text)

    def test_multiple_sources_and_multiple_rows(self):
        second = EXAMPLE[EXAMPLE.index("% source:"):EXAMPLE.index("% PROVENANCE-END")]
        second = second.replace("% source: output.csv", "% source[2]: second.csv").replace("% row:", "% row[2]:")
        (self.root / "second.csv").write_text(self.csv.read_text())
        records, _ = self.validate(EXAMPLE.replace("% PROVENANCE-END", second + "% PROVENANCE-END"))
        self.assertEqual(len(records), 4)
        same_source = second[second.index("% row[2]:"):].replace("% row[2]:", "% row:")
        records, _ = self.validate(EXAMPLE.replace("% PROVENANCE-END", same_source + "% PROVENANCE-END"))
        self.assertEqual(len(records), 4)

    def test_compact_single_row_format(self):
        text = EXAMPLE.replace("% row:\n", "")
        for old, new in [("%     ", "%   "), ("%   key:", "% key:"),
                         ("%   row_at_generation:", "% row_at_generation:"),
                         ("%   fields:", "% fields:"), ("%   display:", "% display:")]:
            text = text.replace(old, new)
        self.validate(text)

    def test_csv_header_and_record_errors(self):
        for text in ["", "election,election\n2018,2018\n", "election,universe,count,vote_share\n2018,seat_winning,4\n"]:
            self.csv.write_text(text)
            with self.subTest(text=text), self.assertRaises(ProvenanceError):
                self.validate()

    def test_source_path_cannot_escape_repository(self):
        for path in ["../output.csv", str(self.csv), "output.tex"]:
            with self.subTest(path=path), self.assertRaisesRegex(ProvenanceError, "repository-relative CSV"):
                self.validate(EXAMPLE.replace("source: output.csv", "source: " + path))

    def test_missing_provenance_fails(self):
        with self.assertRaises(ProvenanceError):
            self.validate("An unannotated manuscript.")

    def test_compact_results_use_source_values_and_survive_removal_of_exhaustive_source(self):
        # The producer must never copy the annotated expectation into the data.
        self.manuscript.write_text(EXAMPLE.replace("count: 4", "count: 99"))
        records = build_results(self.manuscript, self.root, include_summaries=False)
        self.assertEqual(next(r["value"] for r in records if r["field"] == "count"), "4")
        compact = self.root / "manuscript_results.csv"
        write_results(compact, records)
        self.csv.unlink()
        with self.assertRaisesRegex(ProvenanceError, "recorded"):
            validate_provenance(self.manuscript, self.root, results=compact)
        self.manuscript.write_text(EXAMPLE)
        actual, warnings = validate_provenance(self.manuscript, self.root, results=compact)
        self.assertEqual(len(actual), 2)
        self.assertFalse(warnings)

    def test_compact_results_require_complete_unique_selectors(self):
        records = build_results(self.manuscript, self.root, include_summaries=False)
        compact = self.root / "manuscript_results.csv"
        for altered, message in ((records[:1], "selectors differ"),
                                 (records + records[:1], "Duplicate")):
            write_results(compact, altered)
            with self.subTest(message=message), self.assertRaisesRegex(ProvenanceError, message):
                validate_provenance(self.manuscript, self.root, results=compact)
        records[0]["value"] = "5"
        write_results(compact, records)
        with self.assertRaisesRegex(ProvenanceError, "recorded"):
            validate_provenance(self.manuscript, self.root, results=compact)

    def test_compact_result_selection_is_independent_of_key_order(self):
        records = build_results(self.manuscript, self.root, include_summaries=False)
        compact = self.root / "manuscript_results.csv"
        write_results(compact, records)
        self.manuscript.write_text(EXAMPLE.replace("election=2018; universe=seat_winning", "universe=seat_winning; election=2018"))
        validate_provenance(self.manuscript, self.root, results=compact)


if __name__ == "__main__":
    unittest.main()
