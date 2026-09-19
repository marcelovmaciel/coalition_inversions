import sys
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import package


class PublicationTests(unittest.TestCase):
    def test_archive_round_trip_and_stable_membership(self):
        with tempfile.TemporaryDirectory(dir=package.ROOT / 'build/cache/tmp') as tmp:
            root=Path(tmp);source=root/'source.csv';source.write_text('a,b\n1,2\n')
            destination=root/'package.zip';members={'assets/source.csv':source,'main.tex':b'paper'}
            package.write_archive(destination,members)
            first=destination.read_bytes()
            package.write_archive(destination,dict(reversed(list(members.items()))))
            self.assertEqual(first,destination.read_bytes())
            with ZipFile(destination) as archive:
                self.assertEqual(archive.namelist(),sorted(members))
                self.assertEqual(archive.read('assets/source.csv'),source.read_bytes())
                self.assertTrue(all(i.date_time==package.FIXED_ZIP_TIME for i in archive.infolist()))

    def test_missing_source_and_unsafe_member_fail(self):
        with tempfile.TemporaryDirectory(dir=package.ROOT / 'build/cache/tmp') as tmp:
            path=Path(tmp)
            with self.assertRaises(FileNotFoundError):
                package.require_files([path/'missing'])
            for name in ('../outside','/absolute'):
                with self.assertRaises(ValueError):
                    package.write_archive(path/'bad.zip',{name:b'bad'})

    def test_stale_compilation_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=package.ROOT / 'build/cache/tmp') as tmp:
            pdf=Path(tmp)/'old.pdf';pdf.write_bytes(b'old')
            import os
            os.utime(pdf,(1,1))
            with patch.object(package,'check',return_value=([],[])), patch.object(package,'PDF',pdf), self.assertRaisesRegex(ValueError,'newer than the PDF'):
                package.publication()
