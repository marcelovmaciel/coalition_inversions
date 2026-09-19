"""Fresh-output integration: independently recompute every exported cabinet scenario."""
import csv
from collections import defaultdict
from datetime import date, timedelta
from fractions import Fraction
from functools import lru_cache
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'processing'))
from cabinet_contract import load_release, primary_calendar
RESULTS=ROOT/'build/results'

def read(path):
    with (RESULTS/path).open(newline='') as f:return list(csv.DictReader(f))
def days(start,end):
    start,end=date.fromisoformat(start),date.fromisoformat(end)
    return [(start+timedelta(days=i)).isoformat() for i in range((end-start).days)]
def fraction(value):return Fraction(value.replace('//','/'))
def truth(value):return str(value).lower()=='true'
def members(value):return frozenset(filter(None,value.split(';')))

class CabinetIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release=load_release()
        cls.expected,_=primary_calendar(cls.release)
        cls.daily=read('cabinet/cabinet_analysis_daily.csv')
        cls.party={(r['election_year'],r['party']):r for r in read('accounting/raw/party_accounting_all_years.csv')}
        cls.cells=defaultdict(list)
        for r in read('accounting/raw/party_district_accounting_all_years.csv'):
            cls.cells[r['election_year'],r['party']].append(r)

    @lru_cache(None)
    def electoral(self,year,parties):
        selected=[self.party[year,p] for p in parties]
        V={int(r['V']) for (y,p),r in self.party.items() if y==year}
        self.assertEqual(len(V),1);V=V.pop()
        v=sum(int(r['v_i']) for r in selected);s=sum(int(r['s_i']) for r in selected)
        A=B=Fraction()
        for party in parties:
            for cell in self.cells[year,party]:
                local=Fraction(int(cell['S_d'])*int(cell['v_id']),int(cell['V_d']))
                A+=int(cell['s_id'])-local
                B+=local-Fraction(513*int(cell['v_id']),V)
        self.assertEqual(A,sum((fraction(r['A_i_exact']) for r in selected),Fraction()))
        self.assertEqual(B,sum((fraction(r['B_i_exact']) for r in selected),Fraction()))
        q=Fraction(513*v,V);self.assertEqual(A+B,s-q)
        return dict(votes=v,seats=s,national_vote_total=V,vote_share=Fraction(v,V),seat_share=Fraction(s,513),
                    q_C=q,d_C=s-q,A_C=A,B_C=B,R_C=Fraction(s)/q if q else None,
                    inversion_status=2*v<V and s>=257)

    def assert_vector(self,row,parties):
        for key,value in self.electoral(row['election_year'],parties).items():
            if value is None:self.assertIn(row[key],('', 'missing','NaN'))
            elif isinstance(value,bool):self.assertEqual(truth(row[key]),value)
            elif isinstance(value,int):self.assertEqual(int(row[key]),value)
            else:self.assertAlmostEqual(float(row[key]),float(value),delta=1e-10)

    def test_primary_dates_status_and_independent_electoral_effects(self):
        self.assertEqual(len(self.daily),len(self.expected))
        self.assertEqual(len(self.daily),len({r['date'] for r in self.daily}))
        self.assertEqual([{k:str(r[k]).lower() for k in e} for r,e in zip(self.daily,self.expected)],
                         [{k:str(v).lower() for k,v in e.items()} for e in self.expected])
        byperiod=defaultdict(list)
        for d in self.daily:byperiod[d['analytical_period_id']].append(d)
        periods=read('cabinet/cabinet_analysis_periods.csv')
        self.assertEqual(set(byperiod),{r['analytical_period_id'] for r in periods})
        for p in periods:
            dd=byperiod[p['analytical_period_id']]
            self.assertEqual([d['date'] for d in dd],days(p['start_inclusive'],p['end_exclusive']))
            self.assertEqual(int(p['days']),len(dd))
            self.assert_vector(p,members(p['election_party_set']))
            for d in dd:
                self.assertEqual({k:d[k] for k in self.electoral(p['election_year'],members(p['election_party_set']))},
                                 {k:p[k] for k in self.electoral(p['election_year'],members(p['election_party_set']))})

    def test_all_52_exported_scenarios_and_duration_unions(self):
        scenarios=defaultdict(list)
        for r in read('cabinet/cabinet_sensitivity_periods.csv'):scenarios[r['scenario_id']].append(r)
        self.assertEqual(set(scenarios),set(self.release['scenarios']))
        self.assertEqual(len(scenarios),52)
        sets=defaultdict(list)
        for r in read('cabinet_sets/sensitivity_sets.csv'):sets[r['scenario_id']].append(r)
        self.assertEqual(set(sets),set(scenarios))
        for sid,rows in scenarios.items():
            published={r['period_id']:r for r in self.release['scenarios'][sid]}
            self.assertEqual(len(rows),len(published))
            self.assertEqual({r['scenario_period_id'] for r in rows},set(published))
            observed=defaultdict(set);all_dates=[]
            for r in rows:
                source=published[r['scenario_period_id']]
                self.assertEqual([r[k] for k in ('election_year','start_inclusive','end_exclusive')],
                                 [str(source[k]) for k in ('election_year','start_inclusive','end_exclusive')])
                self.assertEqual(r['election_party_set'],source['party_set'])
                dd=days(r['start_inclusive'],r['end_exclusive']);all_dates+=dd
                self.assertEqual(int(r['days']),len(dd));self.assert_vector(r,members(r['election_party_set']))
                observed[r['election_year'],members(r['election_party_set'])].update(dd)
            self.assertEqual(len(all_dates),len(set(all_dates)))
            self.assertEqual(set(all_dates),{r['date'] for r in self.expected})
            self.assertEqual(len(sets[sid]),len(observed))
            for row in sets[sid]:
                key=row['election_year'],members(row['canonical_membership'])
                union=[d for a,b in json.loads(row['observation_intervals']) for d in days(a,b)]
                self.assertEqual(len(union),len(set(union)))
                self.assertEqual(set(union),observed[key])
                self.assertEqual(int(row['total_observed_days']),len(union))
                self.assert_vector(row,key[1])

    def test_distinct_set_identity_occurrences_and_status(self):
        identity=read('cabinet_sets/identity.csv')
        accounting=read('accounting/raw/cabinet_party_set_accounting.csv')
        byid={r['cabinet_party_set_id']:r for r in accounting}
        self.assertEqual(len(identity),len(byid));self.assertEqual(len(accounting),len(byid))
        grouped=defaultdict(list)
        for d in self.daily:grouped[d['election_year'],members(d['election_party_set'])].append(d)
        self.assertEqual(len(identity),len(grouped))
        for r in identity:
            self.assertEqual(r,{k:byid[r['cabinet_party_set_id']][k] for k in r})
            dd=grouped[r['election_year'],members(r['canonical_membership'])]
            intervals=json.loads(r['observation_intervals']);union=[d for a,b in intervals for d in days(a,b)]
            self.assertEqual(len(union),len(set(union)));self.assertEqual(set(union),{d['date'] for d in dd})
            self.assertEqual(int(r['occurrence_count']),len(intervals))
            self.assertEqual(int(r['total_observed_days']),len(dd))
            provisional=sum(truth(d['provisional_day']) for d in dd)
            self.assertEqual((int(r['established_days']),int(r['provisional_days'])),(len(dd)-provisional,provisional))
            self.assertEqual(r['evidence_status']=='provisional_only',provisional==len(dd))
            vector=dict(byid[r['cabinet_party_set_id']],inversion_status=byid[r['cabinet_party_set_id']]['coalition_inversion'])
            self.assert_vector(vector,members(r['canonical_membership']))
        for name,key,source in (('daily_linkage.csv','date',self.daily),('period_linkage.csv','analytical_period_id',read('cabinet/cabinet_analysis_periods.csv'))):
            links=read('cabinet_sets/'+name)
            self.assertEqual(len(links),len({r[key] for r in links}))
            self.assertEqual({r[key] for r in links},{r[key] for r in source})
            self.assertTrue(all(r['cabinet_party_set_id'] in byid for r in links))
        for suffix in ('','_all_parties'):
            for row in read('domains/tables/table_appendix_cabinet_interval_bridge'+suffix+'.csv'):
                order=[r['party'] for r in read('domains/raw/ideology_order_'+row['election_year']+suffix+'.csv')]
                split=lambda v:set(filter(None,(p.strip() for p in v.split(','))))
                cabinet=split(row['cabinet_parties']) & set(order)
                indices=[order.index(p) for p in cabinet]
                closure=set(order[min(indices):max(indices)+1]) if indices else set()
                self.assertEqual(closure,split(row['closure_parties']))
                self.assertEqual(closure-cabinet,split(row['closure_gap_parties']))
                self.assertEqual(len(closure-cabinet),int(row['closure_gap_n']))
                for prefix in ('closest_mcw','closest_mci'):
                    near=split(row[prefix+'_parties'])
                    if near:self.assertAlmostEqual(float(row[prefix+'_jaccard']),len(cabinet & near)/len(cabinet | near),delta=1e-10)
