"""Independent dual-universe regressions for exact accounting and plotted points."""
import csv
import gzip
import sys
import unittest
from collections import defaultdict
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cross_domain_components import validate_full_accounting
from scientific_results import CoalitionResults
PAPER = ROOT / 'build/results/domains'


class IdeologicalAccountingTests(unittest.TestCase):
    def test_every_coalition_and_party_closes_exactly(self):
        independent = validate_full_accounting(PAPER)
        self.assertEqual(independent['coalition_rows'], 31238)
        self.assertEqual(independent['distinct_sets'], 26166)
        print('Independent exhaustive accounting:', independent, flush=True)
        canonical = CoalitionResults(PAPER.parent/'accounting')
        registry = {}
        for suffix in ('', '_all_parties'):
            with (PAPER/f'raw/ideology_k_gap_coalitions{suffix}.csv').open(newline='') as handle:
                for row in csv.DictReader(handle):
                    registry[row['election'],row['ideological_universe'],row['k'],row['coalition_id']]=row
        with (PAPER.parent/'accounting/raw/party_accounting_all_years.csv').open(newline='') as handle:
            parties={(r['election_year'],r['party']):r for r in csv.DictReader(handle)}
        coalitions = {}
        with (PAPER / 'raw/ideology_k_gap_accounting_both_universes.csv').open(newline='', encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                key = row['election'], row['ideological_universe'], row['k'], row['coalition_id']
                self.assertNotIn(key, coalitions)
                source=registry[key]
                for field in ('parties','votes','seats','national_vote_total','minimal_seat_majority','minimal_inversion','inversion'):
                    self.assertEqual(row[field],source[field])
                expected=canonical.row(row['election'],row['coalition_id'].split('|'))
                for field in ('q_C','d_C','A_C','B_C','R_C'):
                    self.assertEqual(Fraction(row[field+'_exact'].replace('//','/')),
                                     Fraction(expected[field+'_exact'].replace('//','/')))
                self.assertEqual(row['inversion']=='true',2*int(row['votes'])<int(row['V']) and int(row['seats'])>=257)
                q, d, a, b = (Fraction(row[c + '_exact']) for c in ('q_C', 'd_C', 'A_C', 'B_C'))
                self.assertEqual(q, Fraction(513 * int(row['votes']), int(row['V'])))
                self.assertEqual(d, int(row['seats']) - q)
                self.assertEqual(a + b, d)
                if row['inversion'] == 'true':
                    self.assertLess(2 * int(row['votes']), int(row['V']))
                    self.assertGreaterEqual(int(row['seats']), 257)
                coalitions[key] = (q, d, a, b, int(row['votes']), int(row['seats']), int(row['party_count']))
        self.assertEqual(set(coalitions),set(registry))
        seen_members=set()
        sums = defaultdict(lambda: [Fraction(0), Fraction(0), Fraction(0), Fraction(0), 0, 0, 0])
        with gzip.open(PAPER / 'raw/ideology_k_gap_party_contributions_both_universes.csv.gz', 'rt', newline='', encoding='utf-8') as handle:
            for row in csv.DictReader(handle):
                key = row['election'], row['ideological_universe'], row['k'], row['coalition_id']
                member_key=(*key,row['party'])
                self.assertNotIn(member_key,seen_members);seen_members.add(member_key)
                self.assertIn(row['party'],row['coalition_id'].split('|'))
                party=parties[row['election'],row['party']]
                self.assertEqual((int(row['votes']),int(row['seats'])),(int(party['v_i']),int(party['s_i'])))
                for member,source in (('q_i','q_i'),('d_i','d_i'),('A_i','A_i'),('B_i','B_i')):
                    self.assertEqual(Fraction(row[member+'_exact'].replace('//','/')),Fraction(party[source+'_exact'].replace('//','/')))
                if row['ideological_universe'] == 'seat_winning':
                    self.assertGreater(int(row['seats']), 0)
                total = sums[key]
                for i,field in enumerate(('q_i','d_i','A_i','B_i')):total[i] += Fraction(row[field+'_exact'])
                total[4] += int(row['votes'])
                total[5] += int(row['seats'])
                total[6] += 1
        self.assertEqual(set(sums), set(coalitions))
        for key, total in sums.items():
            self.assertEqual(tuple(total), coalitions[key])


if __name__ == '__main__':
    unittest.main()
