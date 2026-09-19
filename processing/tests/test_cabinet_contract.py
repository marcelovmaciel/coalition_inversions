"""The released boundary fails closed, independent of historical source files."""
import csv
import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import cabinet_contract as contract

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.release=self.root/'cabinet'
        shutil.copytree(contract.RELEASE,self.release)
        self.pin=self.root/'pin.json';shutil.copyfile(contract.PIN,self.pin)
        self.patches=[patch.object(contract,'RELEASE',self.release),patch.object(contract,'PIN',self.pin)]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.tmp.cleanup()
    def repin_fixture(self):
        meta=json.loads((self.release/'metadata.json').read_text());h=hashlib.sha256()
        for name in sorted(contract.FIELDS):h.update(name.encode()+b'\0'+(self.release/name).read_bytes()+b'\0')
        meta['data_checksum']['value']=h.hexdigest()
        (self.release/'metadata.json').write_text(json.dumps(meta))
        self.pin.write_text(json.dumps(dict(release_version=meta['release_version'],metadata_sha256=hashlib.sha256((self.release/'metadata.json').read_bytes()).hexdigest())))
    def change_rows(self,name,fn):
        path=self.release/name
        with path.open() as f:r=csv.DictReader(f);fields=r.fieldnames;rows=list(r)
        fn(rows)
        with path.open('w') as f:w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
        self.repin_fixture()
    def test_valid_and_opaque_candidates(self):
        meta=json.loads((self.release/'metadata.json').read_text())
        meta['scenarios'][0]['candidate']='opaque: NOT a party or a date'
        (self.release/'metadata.json').write_text(json.dumps(meta));self.repin_fixture()
        release=contract.load_release();daily,periods=contract.primary_calendar(release)
        self.assertEqual((len(daily),len(periods),len(release['scenarios'])),(4096,53,52))
        self.assertEqual(sum(r['provisional_day'] for r in daily),100)
    def test_missing_file_fails_with_other_releases_present(self):
        for name in ('metadata.json', *contract.FIELDS):
            with self.subTest(missing=name):
                path=self.release/name; data=path.read_bytes(); path.unlink()
                try:
                    with self.assertRaises(contract.CabinetInputError):contract.load_release()
                finally:path.write_bytes(data)
    def test_incompatible_schema(self):
        p=self.release/'metadata.json';m=json.loads(p.read_text());m['schema_version']=2;p.write_text(json.dumps(m));self.repin_fixture()
        with self.assertRaisesRegex(contract.CabinetInputError,'unsupported schema'):contract.load_release()
    def test_checksum_detects_changed_data(self):
        p=self.release/'cabinet_periods.csv';p.write_text(p.read_text()+'\n')
        with self.assertRaisesRegex(contract.CabinetInputError,'checksum'):contract.load_release()
    def test_metadata_pin(self):
        p=self.release/'metadata.json';p.write_text(p.read_text()+'\n')
        with self.assertRaisesRegex(contract.CabinetInputError,'metadata differs'):contract.load_release()
    def test_duplicate_members_rejected(self):
        self.change_rows('cabinet_periods.csv',lambda rr:rr[0].update(party_set='PT;PT'))
        with self.assertRaisesRegex(contract.CabinetInputError,'sorted, unique'):contract.load_release()
    def test_coverage_gap(self):
        self.change_rows('cabinet_coverage.csv',lambda rr:rr[0].update(end_exclusive='2015-01-02'))
        with self.assertRaisesRegex(contract.CabinetInputError,'coverage gap'):contract.load_release()
    def test_undefined_scenario(self):
        self.change_rows('cabinet_sensitivity_periods.csv',lambda rr:rr[0].update(scenario_id='absent'))
        with self.assertRaisesRegex(contract.CabinetInputError,'undefined scenario'):contract.load_release()
    def test_election_boundary(self):
        self.change_rows('cabinet_periods.csv',lambda rr:rr[0].update(election_year='2018'))
        with self.assertRaisesRegex(contract.CabinetInputError,'election window'):contract.load_release()
    def test_missing_membership_cell(self):
        p=self.release/'cabinet_periods.csv';lines=p.read_text().splitlines();lines[1]=','.join(lines[1].split(',')[:-1]);p.write_text('\n'.join(lines)+'\n');self.repin_fixture()
        with self.assertRaisesRegex(contract.CabinetInputError,'missing cells'):contract.load_release()
    def test_change_outside_declared_scope(self):
        self.change_rows('cabinet_sensitivity_periods.csv',lambda rr:rr[0].update(party_set='PT'))
        with self.assertRaisesRegex(contract.CabinetInputError,'outside its published affected scope'):contract.load_release()

if __name__=='__main__':unittest.main()
