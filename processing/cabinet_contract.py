#!/usr/bin/env python3
"""The single reader for the local, published cabinet election-calendar snapshot.

Only the four public files and the consumer's explicit pin are inputs. Upstream
provenance strings are informational and are never resolved or opened.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import io
import json
import re
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / 'data/cabinet'
PIN = ROOT / 'data/cabinet_release.json'
FIELDS = {
    'cabinet_periods.csv': ['period_id','election_year','start_inclusive','end_exclusive','party_set'],
    'cabinet_sensitivity_periods.csv': ['scenario_id','period_id','election_year','start_inclusive','end_exclusive','party_set'],
    'cabinet_coverage.csv': ['start_inclusive','end_exclusive','administration','status'],
}

class CabinetInputError(ValueError):
    """Missing, incompatible, or malformed public cabinet input."""

def require(ok, message):
    if not ok:
        raise CabinetInputError('Cabinet input error: ' + message)

def dates(start, end):
    current, stop = date.fromisoformat(start), date.fromisoformat(end)
    while current < stop:
        yield current.isoformat()
        current += timedelta(days=1)

def joined(values):
    return ';'.join(sorted(set(values)))

def interval(row, context):
    start, end = row['start_inclusive'], row['end_exclusive']
    require(date.fromisoformat(start).isoformat() == start and date.fromisoformat(end).isoformat() == end,
            context + ': dates must be YYYY-MM-DD')
    require(start < end, context + ': start must precede exclusive end')
    return start, end

def load_release():
    """Fail closed; there is no release discovery, source adapter, or fallback."""
    try:
        for path in (RELEASE, PIN, *(RELEASE/name for name in [*FIELDS,'metadata.json'])):
            require(path.resolve() == path and not path.is_symlink(), f'snapshot must be local, without symlinks: {path}')
        pin = json.loads(PIN.read_text())
        meta_bytes = (RELEASE/'metadata.json').read_bytes()
        meta = json.loads(meta_bytes)
        require(meta['schema'] == 'cabinet-election-periods' and meta['schema_version'] == 1, 'unsupported schema/version')
        require(meta['release_version'] == pin['release_version'], 'release version differs from explicit consumer pin')
        require(hashlib.sha256(meta_bytes).hexdigest() == pin['metadata_sha256'], 'metadata differs from explicit consumer pin')
        require(meta['files'] == FIELDS, 'incompatible required columns')
        require('start inclusive, end exclusive' in meta['date_convention'] and 'closing-state' in meta['date_convention'], 'unsupported date semantics')
        require('sorted unique' in meta['party_set_encoding'] and 'complete empty set' in meta['party_set_encoding'], 'unsupported membership representation')
        require(meta['unresolved_status'] == 'unbounded_unknown', 'unbounded uncertainty status is missing')
        for field in ('party_identity_convention','coding_policy','scenario_policy','unresolved_scope','period_identifiers'):
            require(isinstance(meta[field],str) and bool(meta[field]), 'missing semantics: '+field)
        start,end = interval(meta['coverage'],'coverage')
        windows = meta['election_windows']; years = set(); previous = start
        for window in windows:
            a,b = interval(window,'election window'); year=window['election_year']
            require(type(year) is int and year not in years, 'duplicate/invalid election identifier')
            require(a == previous and b <= end, 'election windows must partition coverage')
            previous=b; years.add(year)
        require(previous == end, 'incomplete election windows')
        tables={}; hasher=hashlib.sha256()
        for name, fields in FIELDS.items():
            payload=(RELEASE/name).read_bytes()
            reader=csv.DictReader(io.StringIO(payload.decode('utf-8')))
            require(reader.fieldnames == fields, name+': required columns differ')
            rows=list(reader)
            require(bool(rows) and all(set(r)==set(fields) and None not in r.values() for r in rows), name+': missing cells/rows or extra cells')
            for r in rows:
                a,b=interval(r,name)
                require(start <= a < b <= end, name+': interval outside coverage')
                if 'party_set' in r:
                    members=r['party_set'].split(';') if r['party_set'] else []
                    require(all(p and p.strip()==p and p not in {'UNKNOWN','UNAFFILIATED','missing','null'} for p in members)
                            and members==sorted(set(members)), name+': membership must be sorted, unique election-party labels')
                    year=int(r['election_year'])
                    require(str(year)==r['election_year'] and any(w['election_year']==year and w['start_inclusive']<=a<b<=w['end_exclusive'] for w in windows), name+': membership interval crosses election window')
                else:
                    require(r['status'] in ('established','provisional') and bool(r['administration'].strip()), name+': invalid coverage/status')
            tables[name]=rows
        for name in sorted(FIELDS):
            hasher.update(name.encode()+b'\0'+(RELEASE/name).read_bytes()+b'\0')
        require(meta['data_checksum']['algorithm']=='sha256' and hasher.hexdigest()==meta['data_checksum']['value'], 'CSV snapshot checksum mismatch')
        coverage=sorted(tables['cabinet_coverage.csv'],key=lambda r:r['start_inclusive'])
        previous=start
        for r in coverage:
            require(r['start_inclusive']==previous, 'coverage gap or overlap')
            previous=r['end_exclusive']
        require(previous==end, 'incomplete coverage/status calendar')
        definitions={}
        for r in meta['scenarios']:
            sid=r['scenario_id'];a,b=interval(r,'scenario scope')
            require(isinstance(sid,str) and bool(sid) and sid not in definitions, 'duplicate/empty scenario identifier')
            require(start<=a<b<=end and type(r['unbounded_personal_uncertainty']) is bool, 'invalid scenario scope/uncertainty flag')
            require(all(isinstance(r[k],str) and bool(r[k]) for k in ('sensitivity_id','candidate','kind','meaning')), 'incomplete scenario definition')
            definitions[sid]=r
        scenarios=defaultdict(list)
        for r in tables['cabinet_sensitivity_periods.csv']:
            require(r['scenario_id'] in definitions, 'scenario period references an undefined scenario')
            scenarios[r['scenario_id']].append(r)
        require(set(scenarios)==set(definitions), 'missing complete scenario calendar')
        def calendar(rows, name):
            rows=sorted(rows,key=lambda r:r['start_inclusive']);previous=start;last=None;seen=set();daily={}
            for i,r in enumerate(rows,1):
                require(r['period_id']==f'CV5-{i:03d}' and r['period_id'] not in seen, name+': invalid/duplicate period identifier')
                key=(r['election_year'],r['party_set'])
                require(r['start_inclusive']==previous and key!=last, name+': gap, overlap, or nonmaximal membership period')
                daily.update((t,key) for t in dates(r['start_inclusive'],r['end_exclusive']))
                seen.add(r['period_id']);previous=r['end_exclusive'];last=key
            require(previous==end, name+': incomplete membership calendar')
            return rows,daily
        primary,primary_days=calendar(tables['cabinet_periods.csv'],'primary')
        for sid,rows in scenarios.items():
            scenarios[sid],scenario_days=calendar(rows,'scenario '+sid)
            scope=definitions[sid]
            require(all(key==primary_days[t] for t,key in scenario_days.items() if not scope['start_inclusive']<=t<scope['end_exclusive']), 'scenario differs outside its published affected scope: '+sid)
        return dict(metadata=meta,metadata_sha256=pin['metadata_sha256'],periods=primary,coverage=coverage,
                    scenarios=dict(scenarios),definitions=definitions)
    except CabinetInputError:
        raise
    except (OSError,KeyError,TypeError,ValueError,csv.Error) as exc:
        raise CabinetInputError(f'Cabinet input error: incomplete or incompatible snapshot in {RELEASE}: {exc}') from exc

def primary_calendar(release):
    """Expand published membership/coverage intervals, retaining their public IDs."""
    mask={t:r for r in release['coverage'] for t in dates(r['start_inclusive'],r['end_exclusive'])}
    daily=[]; periods=[];annual=Counter()
    for p in release['periods']:
        annual[p['start_inclusive'][:4]]+=1
        label=p['start_inclusive'][:4]+'.'+str(annual[p['start_inclusive'][:4]])
        days=[]
        for t in dates(p['start_inclusive'],p['end_exclusive']):
            c=mask[t];pro=c['status']=='provisional'
            r=dict(date=t,administration=c['administration'],election_year=int(p['election_year']),election_party_set=p['party_set'],
                   analytical_period_id=p['period_id'],period=label,source_release='data/cabinet',
                   primary_set_status='primary_provisional' if pro else 'primary_adjudicated',
                   historical_status='unidentified' if pro else 'established',provisional_day=pro,
                   sensitivity_ids=joined(s['sensitivity_id'] for s in release['definitions'].values() if s['start_inclusive']<=t<s['end_exclusive']))
            days.append(r)
        np=sum(r['provisional_day'] for r in days)
        periods.append(dict(analytical_period_id=p['period_id'],period=label,administration=joined(r['administration'] for r in days),
            election_year=int(p['election_year']),start_inclusive=p['start_inclusive'],end_exclusive=p['end_exclusive'],days=len(days),
            election_party_set=p['party_set'],established_days=len(days)-np,provisional_days=np,proportion_provisional=np/len(days),
            historical_status='established' if not np else 'provisional' if np==len(days) else 'mixed',
            sensitivity_ids=joined(s for r in days for s in r['sensitivity_ids'].split(';') if s),source_release='data/cabinet'))
        daily.extend(days)
    return daily,periods

def require_current_outputs():
    release=load_release()
    path=ROOT/'build/results/cabinet/provenance.json'
    try:
        provenance=json.loads(path.read_text())
        require(provenance['release_metadata_sha256']==release['metadata_sha256'], 'stale cabinet outputs; run make paper')
    except (OSError,KeyError,ValueError) as exc:
        if isinstance(exc,CabinetInputError):raise
        raise CabinetInputError('Cabinet input error: missing current release provenance; run make paper') from exc
    return release

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['validate','calendar'],nargs='?',default='validate')
    args=parser.parse_args()
    try:
        release=load_release()
        if args.command=='calendar':print(json.dumps(primary_calendar(release)[1],ensure_ascii=False))
        else:print('Cabinet contract OK:',release['metadata']['release_version'],len(release['periods']),'primary periods;',len(release['scenarios']),'scenarios')
    except CabinetInputError as exc:
        parser.exit(2,str(exc)+'\n')
