"""Small semantic regression pinned independently of the current computation."""
import csv
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
FIXTURES=Path(__file__).with_name('fixtures')

def read(path):
    with path.open(newline='') as f:return list(csv.DictReader(f))
def normalized(value):
    try:return Fraction(value.replace('//','/'))
    except (ValueError,ZeroDivisionError):return value

def selector(row):
    return row['block'],tuple(sorted(part.strip() for part in row['key'].split(';'))),row['field']

class EmpiricalResultsTests(unittest.TestCase):
    def test_compact_manuscript_scientific_results(self):
        actual=read(ROOT/'build/results/manuscript_results.csv')
        keyed={selector(r):r['value'] for r in actual}
        self.assertEqual(len(keyed),len(actual))
        expected=read(FIXTURES/'manuscript_results.csv')
        self.assertTrue(expected)
        for row in expected:
            with self.subTest(selector=selector(row)):
                self.assertEqual(normalized(keyed[selector(row)]),normalized(row['value']))

    def test_both_universes_and_gap_counts(self):
        fields=('election','ideological_universe','k','minimal_seat_majority_coalitions','minimal_inversions')
        expected=read(FIXTURES/'domains.csv')
        actual=read(ROOT/'build/results/domains/tables/ideological_universe_comparison.csv')
        self.assertEqual(len(actual),len(expected))
        self.assertEqual({tuple(r[k] for k in fields) for r in actual},{tuple(r[k] for k in fields) for r in expected})
