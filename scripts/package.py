"""Check manuscript closure, or package existing publication/replication inputs."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
MANUSCRIPT_ROOT = ROOT / 'writing/submission_inversions_review/manuscript'
MAIN_TEX = MANUSCRIPT_ROOT / 'main_rw_again.tex'
PDF = ROOT / 'build/manuscript/main_rw_again.pdf'
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def referenced_assets():
    source = re.sub(r'(?<!\\)(?:\\\\)*%[^\n]*', '', MAIN_TEX.read_text())
    tables = re.findall(r'\\input\s*\{([^{}]+\.tex)\}', source)
    figures = re.findall(r'\\includegraphics\*?(?:\[[^]]*\])?\s*\{([^{}]+\.(?:pdf|png|jpg|jpeg))\}', source)
    return tuple(sorted({(MANUSCRIPT_ROOT / name).resolve() for name in names}) for names in (tables, figures))


def require_files(paths):
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(f'Missing required package/asset input: {path}')


def manuscript_tex_sources():
    tables, _ = referenced_assets()
    return sorted({MAIN_TEX, *tables})


def write_archive(destination, members):
    """Verify membership and actual file bytes immediately; no persistent manifest."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, 'w', compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name, source in sorted(members.items()):
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError(f'Unsafe archive member: {name}')
            data = source.read_bytes() if isinstance(source, Path) else source
            info = ZipInfo(name, FIXED_ZIP_TIME)
            info.external_attr = (0o100755 if isinstance(source, Path) and source.stat().st_mode & 0o111 else 0o100644) << 16
            archive.writestr(info, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    with ZipFile(destination) as archive:
        if sorted(archive.namelist()) != sorted(members):
            raise ValueError('Package membership mismatch')
        for name, source in members.items():
            expected = source.read_bytes() if isinstance(source, Path) else source
            if archive.read(name) != expected:
                raise ValueError(f'Package content mismatch: {name}')
    print(f'{destination.relative_to(ROOT)}: {len(members)} verified members')


def check():
    tables, figures = referenced_assets()
    require_files([MAIN_TEX, MANUSCRIPT_ROOT / 'refs2.bib', *tables, *figures])
    for asset in tables + figures:
        if asset.parent != ROOT / 'build/assets':
            raise ValueError(f'Manuscript asset outside the canonical build location: {asset}')
    print(f'Manuscript closure: {len(tables)} tables, {len(figures)} figures; every asset resolves.')
    return tables, figures


def publication():
    tables, figures = check()
    require_files([PDF])
    sources = [MAIN_TEX, MANUSCRIPT_ROOT / 'refs2.bib', *tables, *figures]
    if any(p.stat().st_mtime_ns > PDF.stat().st_mtime_ns for p in sources):
        raise ValueError('Manuscript inputs are newer than the PDF; run make compile first.')
    text = MAIN_TEX.read_text()
    members = {PDF.name: PDF, 'refs2.bib': MANUSCRIPT_ROOT / 'refs2.bib'}
    for path in tables + figures:
        original = '../../../build/assets/' + path.name
        text = text.replace('{' + original + '}', '{assets/' + path.name + '}')
        members['assets/' + path.name] = path
    members[MAIN_TEX.name] = text.encode()
    write_archive(ROOT / 'build/submission/publication.zip', members)


def replication():
    # Frozen inputs are included, not replaced by links to a different release.
    import sys
    sys.path.insert(0, str(ROOT / 'scripts'))
    from check_inputs import validate
    validate()
    inputs = [r['path'] for r in json.loads((ROOT / 'data/frozen_electoral_inputs.json').read_text())]
    inputs += ['data/frozen_electoral_inputs.json', 'data/cabinet_release.json',
               'scrape_classification/output/classificacao_2023/party_ordinal_classificacao.json',
               'scrape_classification/output/classificacao_2025/party_classificacao_2025.csv']
    paths = [ROOT / p for p in inputs] + list((ROOT / 'data/cabinet').iterdir())
    paths += [ROOT / p for p in ('Makefile', 'README.md', 'processing/Processing/Project.toml',
              'processing/Processing/Manifest.toml', 'processing/Processing/decomposition/MATHEMATICAL_SPEC.md',
              'processing/Processing/data/electoral_notes/psc_2018_input_decision.md')]
    for directory in ('scripts', 'processing/Processing/src', 'processing/Processing/decomposition',
                      'processing/Processing/test', 'processing/Processing/running', 'processing/tests', 'writing/tests'):
        paths += [p for p in (ROOT / directory).rglob('*') if p.suffix in ('.py','.jl','.sh')]
    paths += list((ROOT / 'processing/Processing/test/fixtures').glob('*.txt'))
    paths += list((ROOT / 'processing/tests/fixtures').glob('*'))
    paths += list((ROOT / 'processing').glob('*.py')) + list((ROOT / 'processing').glob('*.sh'))
    paths += [ROOT / 'writing/make_district_electoral_weight_diagnostic.py', MAIN_TEX, MANUSCRIPT_ROOT / 'refs2.bib']
    require_files(paths)
    members = {p.relative_to(ROOT).as_posix(): p for p in sorted(set(paths))}
    members['REPLICATION.txt'] = (
        'Frozen inputs and current code for the complete current scientific domain and manuscript.\n'
        'Use the unchanged Julia Project/Manifest and existing Python/TeX environment described in README.md.\n'
        'Run make test (fresh analysis), make test-deep (exhaustive), or make paper (manuscript).\n'
        'make test-deep adds exhaustive domains/A/B and a fresh extracted replication rebuild.\n'
        'No cabinet producer, historical review tree, original project or migration baselines are required.\n'
        'Julia/Python/TeX runtimes and package caches are not bundled.\n').encode()
    write_archive(ROOT / 'build/submission/replication.zip', members)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check','publication','replication'])
    args = parser.parse_args()
    {'check': check, 'publication': publication, 'replication': replication}[args.command]()
