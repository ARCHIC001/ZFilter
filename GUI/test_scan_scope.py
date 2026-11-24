"""Focused regressions for selected-root scope, deep scans and completion status."""
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch
sys.path[:0] = [str(Path(__file__).resolve().parents[1]), str(Path(__file__).resolve().parent)]
import nikonfilter as core
from filter_bridge import scan


def write(root, name, data=b'photo'):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def main():
    with tempfile.TemporaryDirectory(prefix='filter-scope-') as temp:
        base = Path(temp).resolve()
        parent = base / 'NEFNIKON'
        selected = parent / '261101viltrox'
        write(selected, 'DSC_0930.JPG'); write(selected, 'DSC_0930.NEF')
        write(parent, 'sibling/other.JPG')
        write(parent, '.nikonfilter_logs/old.json', json.dumps({'run_id':'old', 'timestamp':'old', 'mode_label':'normal', 'stats':{'moved':1}, 'entries':[{'src_before':str(parent/'old.JPG'), 'dst_after':str(parent/'sibling/other.JPG')}]}).encode())
        lib = scan(selected)
        assert Path(lib['root']) == selected
        assert lib['counts'] == {'jpg':1, 'raw':1, 'video':0, 'rawvideo':0}
        assert lib['pending'] == 2 and not lib['organized'] and not lib['history']
        assert all(Path(p['jpeg']).is_relative_to(selected) for p in lib['photos'])
        print('PASS exact reported layout: ancestor logs never replace selected child or include siblings')

        split = base/'split'
        write(split, 'Jpgsplit/a.JPG'); write(split, 'Rawsplit/a.NEF')
        lib = scan(split/'Jpgsplit')
        assert Path(lib['root']) == split/'Jpgsplit'
        assert lib['counts']['jpg'] == 1 and lib['counts']['raw'] == 0
        print('PASS selecting JPEG category preserves selected scope, no implicit sibling import')

        deep = base/'deep'
        write(deep, 'one/two/three/four/five/a.JPEG')
        write(deep, 'one/two/three/four/five/a.ARW')
        write(deep, 'Drawings/six/seven/b.JPG')
        write(deep, 'video/eight/nine/c.MOV')
        write(deep, 'video/eight/nine/d.R3D')
        write(deep, 'DJpgdeep/not-active.JPG')
        lib = scan(deep)
        assert lib['counts'] == {'jpg':2, 'raw':1, 'video':1, 'rawvideo':1}
        assert lib['formats'] == {'JPEG':1, 'ARW':1, 'JPG':1, 'MOV':1, 'R3D':1}
        assert lib['pending'] == 4 and not lib['organized']
        assert len(core.collect_candidates(deep)) == 5  # R3D is inventoried, not a move rule.
        print('PASS arbitrary depth, Drawings is ordinary content, D-prefix pools excluded')

        root = base/'incremental'
        write(root, 'a.JPG'); write(root, 'a.NEF')
        core.organize_folder(root, 'normal', set(), verbose=False)
        assert scan(root)['organized'] and scan(root)['pending'] == 0
        write(root, 'new/card/at/arbitrary/depth/b.JPG')
        write(root, 'new/card/at/arbitrary/depth/b.NEF')
        lib = scan(root)
        assert not lib['organized'] and lib['pending'] == 2
        assert lib['counts']['jpg'] == 2 and lib['counts']['raw'] == 2
        core.organize_folder(root, 'custom', {'1'}, verbose=False)
        lib = scan(root, 'custom', ['1'])
        assert lib['pending'] == 1 and not lib['organized']
        core.organize_folder(root, 'normal', set(), verbose=False)
        assert scan(root)['organized'] and scan(root)['pending'] == 0
        print('PASS old completion log + new media, partial custom run, remaining files determine completion')

        misplaced = base/'misplaced'
        write(misplaced, 'Jpgmisplaced/already.JPG', b'keep')
        wrong = write(misplaced, 'Jpgmisplaced/wrong.NEF', b'raw')
        nested = write(misplaced, 'Jpgmisplaced/import/card/fresh.JPG', b'new')
        lib = scan(misplaced)
        assert lib['counts']['jpg'] == 2 and lib['counts']['raw'] == 1 and lib['pending'] == 2
        result, _, _ = core.organize_folder(misplaced, 'normal', set(), verbose=False)
        assert result.moved == 2 and result.errors == 0
        assert (misplaced/'Jpgmisplaced/already.JPG').read_bytes() == b'keep'
        assert (misplaced/'Rawmisplaced/wrong.NEF').read_bytes() == b'raw'
        assert (misplaced/'Jpgmisplaced/fresh.JPG').read_bytes() == b'new'
        assert scan(misplaced)['pending'] == 0
        print('PASS category folder does not hide misplaced types or deeper unsorted files')

        outside = base/'outside'; write(outside, 'secret.JPG')
        (deep/'external-link').symlink_to(outside, target_is_directory=True)
        (deep/'external-file.JPG').symlink_to(outside/'secret.JPG')
        assert scan(deep)['counts']['jpg'] == 2
        print('PASS symlinks do not broaden scope')
        def inaccessible(*args, **kwargs):
            kwargs['onerror'](PermissionError('unreadable child'))
            return iter([])
        with patch.object(core.os, 'walk', inaccessible):
            try:
                core.collect_candidates(deep)
                raise AssertionError('unreadable subtree must fail visibly')
            except PermissionError:
                pass
        print('PASS inaccessible subtree produces an error instead of silent undercount')
    print('ALL SCAN SCOPE TESTS PASS')


if __name__ == '__main__':
    main()
