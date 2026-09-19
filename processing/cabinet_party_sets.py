#!/usr/bin/env python3
"""Shared cabinet-set identity and temporal linkage; no electoral recalculation.

Memberships are published in election-year identity convention. Julia
attaches the verified exact electoral vector. All dates use [start, end).
"""
from __future__ import annotations
import csv
import hashlib
import json
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/results/cabinet_sets'


def canonical_members(value):
    """Existing translated semicolon-delimited identities; no lineage harmonization."""
    values = value.split(';') if isinstance(value, str) else value
    return ';'.join(sorted({str(p).strip() for p in values if str(p).strip()}))


def set_id(year, members):
    payload = json.dumps([int(year), canonical_members(members).split(';')], ensure_ascii=False, separators=(',', ':'))
    return f'C{int(year)}-' + hashlib.sha256(payload.encode()).hexdigest()[:20]


def write(path, rows, fields=None):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields or list(rows[0]), lineterminator='\n')
        w.writeheader(); w.writerows(rows)


def read(path):
    with Path(path).open(newline='') as f: return list(csv.DictReader(f))


def tomorrow(t):
    return (date.fromisoformat(t) + timedelta(days=1)).isoformat()


def day_range(start, end):
    while start < end:
        yield start
        start=tomorrow(start)


def true(v): return str(v).lower() in ('true', '1', 'yes')


def union_field(rows, field):
    return ';'.join(sorted({x for r in rows for x in str(r.get(field, '')).split(';') if x}))


def build_registry(daily, periods=None, scenario_id='primary'):
    """Build identity from all observed days, including nonconsecutive recurrence.

    Periods may be split arbitrarily: neither identity nor analytical weights nor
    occurrence counts depend on that partition. Evidence never enters identity.
    """
    groups = defaultdict(list); seen = set(); day_links = []
    for r in sorted(daily, key=lambda x: x['date']):
        assert r['date'] not in seen, 'Duplicate primary/scenario date'
        seen.add(r['date'])
        year, members = int(r['election_year']), canonical_members(r['election_party_set'])
        sid = set_id(year, members)
        link = dict(r, scenario_id=scenario_id, cabinet_party_set_id=sid, canonical_membership=members)
        groups[year, members].append(link); day_links.append(link)
    registry, occurrences, provenance, period_links, members_out = [], [], [], [], []
    annual = defaultdict(int)
    for (year, members), days in sorted(groups.items(), key=lambda pair: (pair[0][0], pair[1][0]['date'], pair[0][1])):
        sid = set_id(year, members); annual[year] += 1
        label = f'{str(year)[-2:]}-{annual[year]:02d}'
        intervals = []
        for r in days:
            if intervals and tomorrow(intervals[-1][-1]['date']) == r['date']: intervals[-1].append(r)
            else: intervals.append([r])
        for n, dd in enumerate(intervals, 1):
            oid = f'{sid}@{dd[0]["date"]}'
            for r in dd: r['occurrence_id'] = oid; r['display_label'] = label
            occurrences.append(dict(scenario_id=scenario_id,cabinet_party_set_id=sid,display_label=label,
                occurrence_id=oid,election_year=year,canonical_membership=members,
                start_inclusive=dd[0]['date'],end_exclusive=tomorrow(dd[-1]['date']),days=len(dd),
                established_days=sum(not true(r['provisional_day']) for r in dd),
                provisional_days=sum(true(r['provisional_day']) for r in dd),
                administrations=union_field(dd,'administration'),analytical_period_ids=union_field(dd,'analytical_period_id'),
                analytical_period_labels=union_field(dd,'period')))
        np = sum(true(r['provisional_day']) for r in days)
        row = dict(scenario_id=scenario_id,cabinet_party_set_id=sid,display_label=label,election_year=year,
            canonical_membership=members,party_count=len(members.split(';')) if members else 0,
            first_observed=days[0]['date'],last_observed=days[-1]['date'],total_observed_days=len(days),
            established_days=len(days)-np,provisional_days=np,
            evidence_status='provisional_only' if np==len(days) else 'mixed' if np else 'established_only',
            occurrence_count=len(intervals),analytical_period_count=len({r['analytical_period_id'] for r in days}),
            analytical_period_ids=union_field(days,'analytical_period_id'),analytical_period_labels=union_field(days,'period'),
            administrations=union_field(days,'administration'),
            observation_intervals=json.dumps([[dd[0]['date'],tomorrow(dd[-1]['date'])] for dd in intervals],separators=(',',':')),
            sensitivity_ids=union_field(days,'sensitivity_ids'),
            evidence_qualification='UNKNOWN affiliations remain UNKNOWN; primary assumptions add no party' if np else 'Observed on established days',
            endpoint_convention='start inclusive; end exclusive; first/last dates do not fill recurrence gaps')
        registry.append(row)
        for member in members.split(';') if members else []:
            members_out.append(dict(scenario_id=scenario_id,cabinet_party_set_id=sid,display_label=label,election_year=year,party=member))
        byperiod = defaultdict(list)
        chunks = []
        for r in days:
            byperiod[r['analytical_period_id']].append(r)
            key = tuple(str(r.get(k,'')) for k in ('occurrence_id','analytical_period_id','primary_analytical_period_id','administration','provisional_day','sensitivity_ids'))
            if chunks and chunks[-1][0]==key and tomorrow(chunks[-1][1][-1]['date'])==r['date']: chunks[-1][1].append(r)
            else: chunks.append((key,[r]))
        for pid, dd in byperiod.items():
            period_links.append(dict(scenario_id=scenario_id,cabinet_party_set_id=sid,display_label=label,election_year=year,
                analytical_period_id=pid,period=dd[0]['period'],canonical_membership=members,
                start_inclusive=dd[0]['date'],end_exclusive=tomorrow(dd[-1]['date']),days=len(dd),
                established_days=sum(not true(r['provisional_day']) for r in dd),provisional_days=sum(true(r['provisional_day']) for r in dd),
                administrations=union_field(dd,'administration')))
        for _, dd in chunks:
            r=dd[0]
            provenance.append(dict(scenario_id=scenario_id,cabinet_party_set_id=sid,display_label=label,election_year=year,
                occurrence_id=r['occurrence_id'],analytical_period_id=r['analytical_period_id'],period=r['period'],
                primary_analytical_period_id=r.get('primary_analytical_period_id',r['analytical_period_id']),primary_period=r.get('primary_period',r['period']),administration=r.get('administration',''),
                start_inclusive=r['date'],end_exclusive=tomorrow(dd[-1]['date']),days=len(dd),
                provisional_day=r['provisional_day'],historical_status=r.get('historical_status',''),
                sensitivity_ids=r.get('sensitivity_ids','')))
    assert len({r['cabinet_party_set_id'] for r in registry}) == len(registry)
    assert sum(r['total_observed_days'] for r in registry) == len(daily)
    assert len({r['analytical_period_id'] for r in period_links}) == len(period_links), 'Period spans different sets'
    if periods is not None:
        pp={p['analytical_period_id']:p for p in periods}
        assert set(pp)=={r['analytical_period_id'] for r in period_links}
        for l in period_links:
            p=pp[l['analytical_period_id']]
            assert (int(p['election_year']),canonical_members(p['election_party_set']))==(l['election_year'],l['canonical_membership'])
            assert int(p['days'])==l['days']
    return dict(identity=registry,members=members_out,occurrences=occurrences,period_linkage=period_links,provenance_intervals=provenance,daily_linkage=day_links)


def prepare_registry(daily, periods):
    result=build_registry(daily,periods)
    for name, rows in result.items(): write(OUT/f'{name}.csv',rows)
    write(OUT/'label_lookup.csv',[{k:r[k] for k in ('cabinet_party_set_id','display_label','election_year','canonical_membership')} for r in result['identity']])
    return result


def summarize_sets(rows, periods):
    """Unweighted set statistics; temporal and period totals are explicitly separate."""
    result=[]
    import statistics
    for year in ('2014','2018','2022','all'):
        rr=[r for r in rows if year=='all' or r['election_year']==year]
        pp=[r for r in periods if year=='all' or r['election_year']==year]
        rec=dict(election_year=year,unit='distinct election-year cabinet party sets; unweighted',
            analytical_periods=len(pp),distinct_sets=len(rr),inverted_sets=sum(true(r['coalition_inversion']) for r in rr),
            inversion_episodes=sum(int(r['occurrence_count']) for r in rr if true(r['coalition_inversion'])),
            observed_days=sum(int(r['total_observed_days']) for r in rr),established_days=sum(int(r['established_days']) for r in rr),
            provisional_days=sum(int(r['provisional_days']) for r in rr),inversion_days=sum(int(r['total_observed_days']) for r in rr if true(r['coalition_inversion'])),
            provisional_only_sets=sum(r['evidence_status']=='provisional_only' for r in rr),mixed_evidence_sets=sum(r['evidence_status']=='mixed' for r in rr),
            large_positive_exceeds_negative=sum(float(r['large_positive_minus_all_negative_A'])>0 for r in rr))
        inversion_dates=sorted({t for r in rr if true(r['coalition_inversion']) for start,end in json.loads(r['observation_intervals']) for t in day_range(start,end)})
        rec['inverted_occurrences']=rec['inversion_episodes']
        rec['inversion_episodes']=sum(i==0 or tomorrow(inversion_dates[i-1])!=t for i,t in enumerate(inversion_dates))
        for field in ('A_C','B_C','d_C','R_C','A_over_q','B_over_q','large_party_share_gross_positive_A'):
            v=[float(r[field]) for r in rr if r[field] not in ('','missing')]
            for op,fn in [('min',min),('max',max),('mean',statistics.mean),('median',statistics.median)]:rec[f'{field}_{op}']=fn(v) if v else ''
            quartiles=statistics.quantiles(v,n=4,method='inclusive') if len(v)>1 else v*3
            rec[f'{field}_q25']=quartiles[0] if v else '';rec[f'{field}_q75']=quartiles[2] if v else ''
            for op,fn in [('positive',lambda x:x>0),('negative',lambda x:x<0),('zero',lambda x:x==0)]:rec[f'{field}_{op}']=sum(fn(x) for x in v)
        rec['overrepresented_sets']=sum(float(r['R_C'])>1 for r in rr if r['R_C'] not in ('','missing'));rec['underrepresented_sets']=sum(float(r['R_C'])<1 for r in rr if r['R_C'] not in ('','missing'))
        rec['inverted_set_percent']=100*rec['inverted_sets']/len(rr)
        result.append(rec)
    return result


def finalize():
    """Publish mirrors of the Julia exact registry, plus scenario-specific views."""
    import shutil
    from cabinet_contract import require_current_outputs
    require_current_outputs()
    from cabinet_v5 import Quantities, OUT as V5
    raw=ROOT/'build/results/accounting/raw'
    # Refresh day-level linkage with original (unchanged) electoral quantities.
    prepare_registry(read(V5/'cabinet_analysis_daily.csv'),read(V5/'cabinet_analysis_periods.csv'))
    quantify=Quantities(); primary={d['date']:d for d in read(V5/'cabinet_analysis_daily.csv')}
    scenarios=defaultdict(list)
    for p in read(V5/'cabinet_sensitivity_periods.csv'):scenarios[p['scenario_id']].append(p)
    scenarios_out=[];scenario_links=[];scenario_occurrences=[];scenario_provenance=[];summaries=[]
    for scenario,periods in sorted(scenarios.items()):
        dd=[]
        for p in periods:
            t=p['start_inclusive']
            while t<p['end_exclusive']:
                dd.append(dict(primary[t],primary_analytical_period_id=primary[t]['analytical_period_id'],primary_period=primary[t]['period'],election_party_set=p['election_party_set'],analytical_period_id=p['scenario_period_id'],period=p['scenario_period_id']))
                t=tomorrow(t)
        built=build_registry(dd,scenario_id=scenario)
        for r in built['identity']:
            r.update(quantify(r['election_year'],r['canonical_membership']))
        scenarios_out.extend(built['identity']);scenario_links.extend(built['period_linkage']);scenario_occurrences.extend(built['occurrences']);scenario_provenance.extend(built['provenance_intervals'])
        for year in (2014,2018,2022):
            rr=[r for r in built['identity'] if r['election_year']==year]
            summaries.append(dict(scenario_id=scenario,election_year=year,distinct_sets=len(rr),inverted_sets=sum(true(r['inversion_status']) for r in rr),
                inversion_days=sum(r['total_observed_days'] for r in rr if true(r['inversion_status'])),observed_days=sum(r['total_observed_days'] for r in rr),
                scope='Unweighted sets within this scenario; evidence flags refer to primary chronology, not validation of the hypothetical change'))
    for name,rows in [('sensitivity_sets',scenarios_out),('sensitivity_period_linkage',scenario_links),('sensitivity_occurrences',scenario_occurrences),('sensitivity_provenance_intervals',scenario_provenance),('sensitivity_summary',summaries)]:write(OUT/f'{name}.csv',rows)
    rows=read(raw/'cabinet_party_set_accounting.csv')
    result=summarize_sets(rows,read(V5/'cabinet_analysis_periods.csv'))
    write(OUT/'summary.csv',result)
    linked=read(OUT/'daily_linkage.csv'); byid={r['cabinet_party_set_id']:r for r in rows}
    administration=[]
    for admin in sorted({d['administration'] for d in linked}):
        dd=[d for d in linked if d['administration']==admin]; ids={d['cabinet_party_set_id'] for d in dd}
        administration.append(dict(administration=admin,distinct_sets=len(ids),inverted_sets=sum(true(byid[i]['coalition_inversion']) for i in ids),
            observed_days=len(dd),inversion_days=sum(true(byid[d['cabinet_party_set_id']]['coalition_inversion']) for d in dd),
            established_days=sum(not true(d['provisional_day']) for d in dd),provisional_days=sum(true(d['provisional_day']) for d in dd),
            scope='Sets counted once within administration; pooled count deduplicates across administrations within election'))
    write(OUT/'administration_summary.csv',administration)
    participation=[]
    for p in read(raw/'party_accounting_all_years.csv'):
        dd=[d for d in linked if d['election_year']==p['election_year'] and p['party'] in d['canonical_membership'].split(';')]
        participation.append(dict(election_year=p['election_year'],party=p['party'],ever_in_cabinet=bool(dd),
            distinct_cabinet_sets=len({d['cabinet_party_set_id'] for d in dd}),analytical_period_count=len({d['analytical_period_id'] for d in dd}),
            cabinet_days=len(dd),
            days_in_established_primary_sets=sum(not true(d['provisional_day']) for d in dd),days_in_provisional_primary_sets=sum(true(d['provisional_day']) for d in dd)))
    write(OUT/'party_participation.csv',participation)
    print('Distinct cabinet party sets:',[(r['election_year'],r['distinct_sets']) for r in result])

if __name__=='__main__':finalize()
