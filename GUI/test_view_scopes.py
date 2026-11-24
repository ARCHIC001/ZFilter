"""Run: python3 GUI/test_view_scopes.py. Small disposable file fixtures only."""
import json
import shutil
import tempfile
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from filter_bridge import scan


def main():
    with tempfile.TemporaryDirectory(prefix='filter-view-scopes-') as temp:
        root = Path(temp)
        for name in ['a/Pair.JPG', 'b/Pair.NEF', 'a/JOnly.JPG', 'b/ROnly.NEF', 'a/Amb.JPG', 'b/Amb.NEF', 'c/Amb.NEF']:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        lib = scan(root)
        assert len(lib['photos']) == 3 and len(lib['rawPhotos']) == 4
        assert lib['paired'] == 1 and lib['ambiguous'] == 1 and lib['orphanRaw'] == 3
        assert len({p['raw'] for p in lib['rawPhotos']}) == 4
        assert sum(bool(p['jpeg']) for p in lib['rawPhotos']) == 1
        pair = next(p for p in lib['photos'] if p['raw'])
        logs = root / '.nikonfilter_logs'
        logs.mkdir()
        for scope in ['RAW', 'JPEG', 'BOTH', 'ORPHAN_RAW']:
            photo = pair if scope != 'ORPHAN_RAW' else {'jpeg': '', 'raw': str(root/'b/ROnly.NEF'), 'status': '仅 RAW', 'source': ''}
            selected = [photo['raw']] if scope in ['RAW', 'ORPHAN_RAW'] else [photo['jpeg']] if scope == 'JPEG' else [photo['jpeg'], photo['raw']]
            entries = []
            for path in selected:
                source = Path(path)
                dest = root / ('DRawtest' if source.suffix == '.NEF' else 'DJpgtest') / source.name
                dest.parent.mkdir(exist_ok=True)
                shutil.move(source, dest)
                entries.append({'original': str(source), 'trash': str(dest)})
            (logs/'pool.json').write_text(json.dumps([{'id': scope, 'photo': photo, 'entries': entries}]))
            lib = scan(root)
            assert len(lib['photos']) == (2 if scope in ['JPEG', 'BOTH'] else 3)
            assert len(lib['rawPhotos']) == (4 if scope == 'JPEG' else 3)
            assert len(lib['poolPhotos']) == (1 if scope in ['JPEG', 'BOTH'] else 0)
            assert len(lib['poolRawPhotos']) == (0 if scope == 'JPEG' else 1)
            assert lib['paired'] == (1 if scope == 'ORPHAN_RAW' else 0)
            if scope != 'BOTH':
                assert all(not p['raw'] for p in lib['poolPhotos'])
                assert all(not p['jpeg'] for p in lib['poolRawPhotos'])
            else:
                assert lib['poolPhotos'][0]['raw'] == lib['poolRawPhotos'][0]['raw']
            for entry in entries:
                shutil.move(entry['trash'], entry['original'])
            (logs/'pool.json').unlink()
            assert scan(root)['paired'] == 1
            print('PASS view inventory / physical pools / verified pairs:', scope)
    print('ALL VIEW SCOPE TESTS PASS')


if __name__ == '__main__':
    main()
