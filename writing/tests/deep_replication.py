"""Costly portability regression: reconstruct scientific payload from the exported source."""
import gzip
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import package

def payload(root):
    result={}
    for path in root.rglob('*'):
        relative=path.relative_to(root)
        if path.suffix not in ('.csv','.gz') or any(p in ('audit','diagnostics') for p in relative.parts) or path.name=='artifact_manifest.csv':continue
        opener=gzip.open if path.suffix=='.gz' else open
        with opener(path,'rb') as f:result[str(relative)]=hashlib.file_digest(f,'sha256').hexdigest()
    if not result:raise AssertionError('Scientific results are required; make test-deep builds them first')
    return result

class ExtractedReplication(unittest.TestCase):
    def test_frozen_source_reconstructs_scientific_payload(self):
        package.replication()
        expected=payload(package.ROOT/'build/results')
        with tempfile.TemporaryDirectory(prefix='replication-',dir=package.ROOT/'build/cache/tmp') as directory:
            root=Path(directory)
            self.assertEqual(root.resolve(),root)
            subprocess.run(['unzip','-q',str(package.ROOT/'build/submission/replication.zip'),'-d',str(root)],check=True)
            self.assertFalse(any(p.is_symlink() for p in root.rglob('*')))
            self.assertTrue((root/'processing/tests/fixtures/manuscript_results.csv').is_file())
            env=os.environ.copy();env.pop('PYTHONPATH',None)
            subprocess.run(['make','analysis','results','PYTHON_BIN='+sys.executable],cwd=root,env=env,check=True)
            self.assertEqual(payload(root/'build/results'),expected)
            print('Extracted replication:',len(expected),'scientific CSV/gzip payloads match',flush=True)

if __name__=='__main__':unittest.main(verbosity=2)
