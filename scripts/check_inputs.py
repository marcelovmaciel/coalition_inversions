"""Validate retained frozen scientific inputs and owned build paths."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'processing'))
from cabinet_contract import load_release


def owned(path):
    path = ROOT / path
    if not path.is_relative_to(ROOT / 'build') or path.resolve() != path:
        raise ValueError(f'Build path must be owned, without symlinks: {path}')
    if path.exists() and any(p.is_symlink() for p in path.rglob('*')):
        raise ValueError(f'Build tree contains a symlink: {path}')
    return path


def validate():
    load_release()  # Complete four-file snapshot, public schema and explicit pin.
    for row in json.loads((ROOT / 'data/frozen_electoral_inputs.json').read_text()):
        path = ROOT / row['path']
        with path.open('rb') as handle:
            actual = hashlib.file_digest(handle, 'sha256').hexdigest()
        if actual != row['sha256']:
            raise ValueError(f'Frozen electoral input changed: {path}')
    for relative in ('scrape_classification/output/classificacao_2023/party_ordinal_classificacao.json',
                     'scrape_classification/output/classificacao_2025/party_classificacao_2025.csv'):
        if not (ROOT / relative).is_file():
            raise FileNotFoundError(relative)
    owned('build')
    print('Complete pinned cabinet snapshot and all frozen scientific inputs: PASS')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--remove']:
        for relative in sys.argv[2:]:
            path = owned(relative)
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
    else:
        validate()
