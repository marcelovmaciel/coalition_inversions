import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from cabinet_party_sets import build_registry, set_id, summarize_sets

class PartySetIdentityTests(unittest.TestCase):
    def day(self,t,members='PT;PDT',year=2014,period='p1',pro=False,admin='a'):
        return dict(date=t,election_year=year,election_party_set=members,analytical_period_id=period,period=period,
                    provisional_day=pro,administration=admin)
    def test_nonconsecutive_recurrence_and_distinct_keys(self):
        days=[self.day('2015-01-01'),self.day('2015-01-02','PT',period='p2'),self.day('2015-01-03',period='p3'),
              self.day('2019-01-01',year=2018,period='p4')]
        r=build_registry(days)
        self.assertEqual(len(r['identity']),3)
        first=r['identity'][0]
        self.assertEqual(first['total_observed_days'],2)
        self.assertEqual(first['occurrence_count'],2)
        self.assertEqual(first['observation_intervals'],'[["2015-01-01","2015-01-02"],["2015-01-03","2015-01-04"]]')
        self.assertNotEqual(set_id(2014,'PT'),set_id(2018,'PT'))
        self.assertNotEqual(set_id(2014,'PT'),set_id(2014,'PT;PDT'))
    def test_member_and_row_permutation(self):
        days=[self.day('2015-01-01'),self.day('2015-01-02')]
        altered=[dict(d,election_party_set='PDT;PT;PDT') for d in reversed(days)]
        self.assertEqual(build_registry(days)['identity'],build_registry(altered)['identity'])
    def test_splitting_periods_leaves_sample_and_duration_unchanged(self):
        days=[self.day('2015-01-01'),self.day('2015-01-02'),self.day('2015-01-03')]
        split=[dict(d,period=f'p{i}',analytical_period_id=f'p{i}') for i,d in enumerate(days)]
        a,b=build_registry(days)['identity'][0],build_registry(split)['identity'][0]
        for k in ('cabinet_party_set_id','canonical_membership','total_observed_days','occurrence_count','first_observed','last_observed','observation_intervals'):
            self.assertEqual(a[k],b[k])
    def test_unweighted_empirical_summaries_invariant_to_period_splitting(self):
        daily=[]
        for year,start in ((2014,'2015'),(2018,'2019'),(2022,'2023')):
            daily += [self.day(start+'-01-01',year=year,period=start+'a'),
                      self.day(start+'-01-02',year=year,period=start+'a'),
                      self.day(start+'-01-03','PT',year=year,period=start+'b')]
        split=[dict(d,analytical_period_id=d['date'],period=d['date']) for d in daily]
        vectors={r['cabinet_party_set_id']:dict(coalition_inversion=r['party_count']==2,
            large_positive_minus_all_negative_A=1, A_C=2, B_C=-1, d_C=1,
            R_C=1.1, A_over_q=.2, B_over_q=-.1, large_party_share_gross_positive_A=.7)
            for r in build_registry(daily)['identity']}
        results=[]
        for days in (daily,split):
            built=build_registry(days)
            rows=[dict(vectors[r['cabinet_party_set_id']],**{k:str(v) for k,v in r.items()}) for r in built['identity']]
            periods=[dict(r,election_year=str(r['election_year'])) for r in built['period_linkage']]
            results.append(summarize_sets(rows,periods))
        for old,new in zip(*results):
            self.assertNotEqual(old['analytical_periods'],new['analytical_periods'])
            self.assertEqual({k:v for k,v in old.items() if k!='analytical_periods'}, {k:v for k,v in new.items() if k!='analytical_periods'})

    def test_evidence_and_administration_do_not_split_identity(self):
        days=[self.day('2015-01-01'),self.day('2015-01-02',pro=True,admin='b'),self.day('2015-01-03','PT',period='p2',pro=True)]
        r=build_registry(days)
        self.assertEqual(len(r['identity']),2)
        self.assertEqual(r['identity'][0]['evidence_status'],'mixed')
        self.assertEqual(r['identity'][0]['established_days'],1)
        self.assertEqual(r['identity'][1]['evidence_status'],'provisional_only')
        self.assertEqual(len(r['provenance_intervals']),3)
        self.assertEqual(sum(d['provisional_day'] for d in r['daily_linkage']),2)
    def test_scenarios_separate_without_changing_membership_identity(self):
        days=[self.day('2015-01-01')]
        a=build_registry(days);b=build_registry(days,scenario_id='alternative')
        self.assertEqual(a['identity'][0]['cabinet_party_set_id'],b['identity'][0]['cabinet_party_set_id'])
        self.assertNotEqual(a['identity'][0]['scenario_id'],b['identity'][0]['scenario_id'])
    def test_duplicate_dates_and_period_spanning_sets_fail(self):
        with self.assertRaises(AssertionError):build_registry([self.day('2015-01-01')]*2)
        with self.assertRaises(AssertionError):build_registry([self.day('2015-01-01'),self.day('2015-01-02','PT')])

if __name__=='__main__':unittest.main()
