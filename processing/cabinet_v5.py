#!/usr/bin/env python3
"""Published election-year cabinet calendars and unchanged electoral accounting.

The legacy output directory is retained for manuscript paths. Memberships,
coverage masks and complete scenarios come only from processing.cabinet_contract.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'processing/Processing/data'
OUT = ROOT / 'build/results/cabinet'
PAPER = ROOT / 'build/results/domains'
DECOMP = ROOT / 'build/results/accounting'
START, END = '2015-01-01', '2026-03-20'
COMMAND = 'make paper'


def read(path):
    with Path(path).open(newline='', encoding='utf-8-sig') as f:
        return list(csv.DictReader(f))


def write(path, rows, fields=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fields or list(rows[0]), lineterminator='\n')
        w.writeheader()
        w.writerows(rows)


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def tokens(value):
    return set(filter(None, (x.strip() for x in str(value).split(';'))))


def joined(values):
    return ';'.join(sorted(set(values)))


def truth(value):
    return str(value).lower() in ('true', 'yes', '1')


def dates(start, end):
    s, e = date.fromisoformat(start), date.fromisoformat(end)
    return [(s + timedelta(days=i)).isoformat() for i in range((e-s).days)]


def tomorrow(t):
    return (date.fromisoformat(t) + timedelta(days=1)).isoformat()


from cabinet_contract import load_release, primary_calendar, require_current_outputs


def validate_inputs():
    return load_release()


def prepare():
    release=load_release()
    daily,periods=primary_calendar(release)
    write(OUT/'cabinet_analysis_daily.csv',daily)
    write(OUT/'cabinet_analysis_periods.csv',periods)
    register=[dict(sensitivity_id=r['sensitivity_id'],scenario_id=r['scenario_id'],start=r['start_inclusive'],
                   end=r['end_exclusive'],kind=r['kind'],unbounded_personal_uncertainty=r['unbounded_personal_uncertainty'])
              for r in release['definitions'].values()]
    # Unbounded affiliations have a coverage scope, never an invented membership.
    register += [dict(sensitivity_id='unbounded@'+r['start_inclusive'],scenario_id='',start=r['start_inclusive'],
                      end=r['end_exclusive'],kind='unbounded_unknown',unbounded_personal_uncertainty=True)
                 for r in release['coverage'] if r['status']=='provisional']
    write(OUT/'sensitivity_register.csv',register)
    (OUT/'provenance.json').write_text(json.dumps(dict(source_release='data/cabinet',
        release_version=release['metadata']['release_version'],release_metadata_sha256=release['metadata_sha256'],
        data_checksum=release['metadata']['data_checksum'],build_command=COMMAND,
        transformation='published election-party periods + coverage -> actual occurrences -> electoral quantities',
        days=len(daily),established_days=sum(not r['provisional_day'] for r in daily),
        provisional_days=sum(r['provisional_day'] for r in daily),analytical_periods=len(periods)),indent=2)+'\n')
    from cabinet_party_sets import prepare_registry
    prepare_registry(daily,periods)
    print(f'Cabinet snapshot: {len(periods)} published periods; {len(daily)} dates.')
    return daily,periods


class Quantities:
    """Cabinet schema projection of the canonical exact coalition result."""
    def __init__(self):
        from Processing.decomposition.scientific_results import CoalitionResults
        self.results = CoalitionResults(DECOMP)

    def __call__(self, year, members):
        row = self.results.row(year, tokens(members))
        result = {key: float(row[key]) if row[key] else ""
                  for key in ("vote_share", "seat_share", "q_C", "d_C", "R_C", "A_C", "B_C")}
        return dict(votes=int(row["votes"]), national_vote_total=int(row["V"]),
                    vote_share=result.pop("vote_share"), seats=int(row["seats"]),
                    **result, inversion_status=row["inversion"] == "true")


def concrete_sensitivities(release,daily,quantify):
    """Quantify exported alternatives; candidate labels are opaque, never rules."""
    primary={r['date']:r for r in daily}
    rows=[];scenario_periods=[]
    for scenario,periods in sorted(release['scenarios'].items()):
        definition=release['definitions'][scenario]
        alternative={t:p for p in periods for t in dates(p['start_inclusive'],p['end_exclusive'])}
        local=[]
        for t in dates(definition['start_inclusive'],definition['end_exclusive']):
            base=primary[t];changed=alternative[t]
            before=quantify(base['election_year'],base['election_party_set'])
            after=quantify(changed['election_year'],changed['party_set'])
            rec=dict(sensitivity_id=definition['sensitivity_id'],scenario_id=scenario,scenario_type=definition['kind'],
                candidate=definition['candidate'],start_inclusive=t,end_exclusive=tomorrow(t),days=1,
                primary_election_party_set=base['election_party_set'],alternative_election_party_set=changed['party_set'],
                primary_provisional_day=truth(base['provisional_day']),
                comparison_scope='conditional on V5 no-additional-party assumptions' if truth(base['provisional_day']) else 'concrete released alternative',
                unbounded_personal_uncertainty=definition['unbounded_personal_uncertainty'],
                inversion_classification_changes=before['inversion_status']!=after['inversion_status'])
            for prefix,values in [('primary',before),('alternative',after)]:
                rec.update({prefix+'_'+k:v for k,v in values.items()})
            key=lambda r:{k:v for k,v in r.items() if k not in ('start_inclusive','end_exclusive','days')}
            if local and key(rec)==key(local[-1]):
                local[-1]['end_exclusive']=tomorrow(t);local[-1]['days']+=1
            else:local.append(rec)
        rows.extend(local)
        for p in periods:
            scenario_periods.append(dict(scenario_id=scenario,sensitivity_id=definition['sensitivity_id'],
                scenario_period_id=p['period_id'],election_year=int(p['election_year']),start_inclusive=p['start_inclusive'],
                end_exclusive=p['end_exclusive'],days=len(dates(p['start_inclusive'],p['end_exclusive'])),
                election_party_set=p['party_set'],**quantify(p['election_year'],p['party_set'])))
    rows.sort(key=lambda r:(r['sensitivity_id'],r['candidate'],r['start_inclusive']))
    write(OUT/'cabinet_sensitivity_results.csv',rows)
    write(OUT/'cabinet_sensitivity_periods.csv',scenario_periods)
    return rows


def analyze():
    release = require_current_outputs()
    daily, periods = read(OUT/'cabinet_analysis_daily.csv'),read(OUT/'cabinet_analysis_periods.csv')
    quantify = Quantities()
    pipeline = {(int(r['election_year']),r['period']):r for r in read(PAPER/'raw/cabinet_coalition_metrics.csv')}
    for p in periods:
        q=quantify(p['election_year'],p['election_party_set']); p.update(q)
        source=pipeline[int(p['election_year']),p['period']]
        for a,b in [('votes','votes'),('seats','seats'),('vote_share','vote_share'),('q_C','quota'),('d_C','seat_diff'),('R_C','representation_ratio')]:
            assert abs(float(q[a])-float(source[b]))<1e-10,(p['analytical_period_id'],a)
        assert truth(source['coalition_inversion'])==q['inversion_status']
    byid={p['analytical_period_id']:p for p in periods}
    for d in daily:
        d.update(quantify(d['election_year'],d['election_party_set']))
        assert all(d[k]==byid[d['analytical_period_id']][k] for k in quantify(d['election_year'],d['election_party_set']))
    write(OUT/'cabinet_analysis_daily.csv',daily)
    sensitivities=concrete_sensitivities(release,daily,quantify)
    inversions=[]
    for p in periods:
        touched=[s for s in sensitivities if s['start_inclusive']<p['end_exclusive'] and s['end_exclusive']>p['start_inclusive']]
        p['concrete_sensitivity_ids']=joined(s['sensitivity_id'] for s in touched)
        p['robust_to_all_recorded_concrete_sensitivities']='no' if any(s['inversion_classification_changes'] for s in touched) else 'yes'
        if p['inversion_status']:
            inversions.append(dict(p,notes=('Primary set includes a flagged no-additional-party assumption; unknown affiliations are unbounded. ' if int(p['provisional_days']) else '')+
                ('Recorded concrete alternatives change inversion status on some dates.' if p['robust_to_all_recorded_concrete_sensitivities']=='no' else 'No recorded concrete alternative changes inversion status on these dates.')))
    write(OUT/'cabinet_analysis_periods.csv',periods)
    write(OUT/'cabinet_inversions.csv',inversions,list(inversions[0]) if inversions else list(periods[0])+['notes'])
    summaries=[]
    for sid in sorted({s['scenario_id'] for s in sensitivities}):
        ss=[s for s in sensitivities if s['scenario_id']==sid]
        summaries.append(dict(scenario_id=sid,sensitivity_id=ss[0]['sensitivity_id'],
            affected_days=sum(s['days'] for s in ss),changed_classification_days=sum(s['days'] for s in ss if s['inversion_classification_changes']),
            primary_inversion_days=sum(s['days'] for s in ss if s['primary_inversion_status']),
            alternative_inversion_days=sum(s['days'] for s in ss if s['alternative_inversion_status'])))
    write(PAPER/'raw/cabinet_date_sensitivity_summary.csv',summaries)
    print(f'Cabinet analysis: {len(periods)} periods, {len(inversions)} primary inversions; {len(summaries)} concrete scenarios.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=['prepare','analyze'])
    args=parser.parse_args()
    if args.stage=='prepare':prepare()
    else:analyze()
