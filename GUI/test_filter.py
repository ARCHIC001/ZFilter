"""Run: python3 GUI/test_filter.py. Uses copies; original test photos are untouched."""
import hashlib
import json
import shutil
import sys
import struct
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nikonfilter as core
from filter_bridge import scan


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file() and not any(x.startswith('.') for x in p.relative_to(root).parts)}


def main():
    source = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'test'
    original = snapshot(source)
    with tempfile.TemporaryDirectory(prefix='filter-check-') as temp:
        base = Path(temp)
        template = base / '_input'; template.mkdir()
        for path in source.rglob('*'):
            if path.is_file() and path.suffix.lower() in core.JPEG_EXT | core.RAW_PHOTO_EXT:
                destination = template / path.name
                assert not destination.exists(), '测试样本存在同名重复文件，请指定独立样本目录'
                shutil.copy2(path, destination)
        for mode, travel in [('normal', False), ('normal', True), ('red', True)]:
            root = base / (mode + str(travel)); shutil.copytree(template, root)
            before = snapshot(root)
            pre = core.preview_scan(root, core.resolve_effective_rules(mode, set()), travel)
            assert pre['jpg'] == 7 and pre['raw_photos'] == 7
            result, _, log = core.organize_folder(root, mode, set(), dry_run=True, verbose=False, travel_mode=travel)
            assert result.moved == 14 and log is None and snapshot(root) == before
            assert scan(root)['paired'] == 7
            result, _, log = core.organize_folder(root, mode, set(), verbose=False, travel_mode=travel)
            assert result.moved == 14 and not result.errors
            lib = scan(root); assert lib['paired'] == 7 and lib['orphanRaw'] == 0
            assert len(lib['history']) == 1
            data = json.loads(log.read_text()); assert len(data['entries']) == 14
            assert all(Path(e['dst_after']).exists() for e in data['entries'])
            if travel: assert all('20261101' in e['dst_after'] for e in data['entries'])
            # A second empty run must not hide the last undoable operation.
            core.organize_folder(root, mode, set(), verbose=False, travel_mode=travel)
            restored = core.undo_last_execution(root, verbose=False)
            assert restored.reverted == 14 and not restored.errors
            assert snapshot(root) == before
            assert scan(root)['paired'] == 7
            print('PASS sample:', mode, 'travel=', travel, 'dry-run / run / pairing / empty-run / undo / SHA256')
        root = base / 'video'; root.mkdir()
        for name in ['clip.nev', 'clip.mp4', 'other.mov', 'other.avi', 'pic.cr3', 'note.txt']:
            (root/name).write_bytes(name.encode())
        before = snapshot(root)
        for mode in ['normal', 'red']:
            result, _, _ = core.organize_folder(root, mode, set(), verbose=False)
            targets = core.build_target_dirs(root)
            if mode == 'red':
                assert (targets['G10RED_R3D']/'clip.r3d').exists()
                assert targets['G10RED_RED265'].is_dir()
                assert (targets['G10RED_AGENT']/'clip.mp4').exists()
                assert scan(root)['formats']['R3D'] == 1 and scan(root)['counts']['rawvideo'] == 1
            else:
                assert (targets['NRAW_NEV']/'clip.nev').exists()
                assert (targets['NRAW_AGENT']/'clip.mp4').exists()
            assert result.moved == 5 and result.skipped == 1
            assert core.undo_last_execution(root, False).reverted == 5
            assert snapshot(root) == before
        print('PASS NEV / RED rename / proxy / video formats / unsupported / undo')
        root = base/'duplicates'; root.mkdir()
        for folder in ['card1','card2']:
            (root/folder).mkdir()
            for ext in ['JPG','NEF']: (root/folder/f'X.{ext}').write_bytes((folder+ext).encode())
        # Destination collision changes JPEG and RAW names differently: logs preserve identity.
        (root/'Jpgduplicates').mkdir(); (root/'Jpgduplicates'/'X.JPG').write_bytes(b'old')
        core.organize_folder(root, 'normal', set(), verbose=False)
        lib = scan(root)
        assert lib['paired'] == 2 and len(lib['photos']) == 3
        for p in lib['photos']:
            if p['raw']: assert Path(p['jpeg']).read_bytes()[:5] == Path(p['raw']).read_bytes()[:5]
        print('PASS duplicate stems / unequal collision suffixes / logged identities')
        root = base/'ambiguous'; root.mkdir()
        for folder, ext in [('j','jpg'),('r1','nef'),('r2','nef')]:
            (root/folder).mkdir(); (root/folder/f'X.{ext}').write_bytes(b'x')
        lib=scan(root); assert lib['ambiguous']==1 and lib['paired']==0 and lib['orphanRaw']==2
        print('PASS ambiguous RAW never auto-associated')
        root = base/'custom'; shutil.copytree(template, root)
        result, _, _ = core.organize_folder(root, 'custom', {'1'}, verbose=False)
        assert result.moved==7 and result.skipped==7 and scan(root)['paired']==7
        assert core.undo_last_execution(root,False).reverted==7
        print('PASS custom rules / partial pair movement')
        distant = base/'distant.NEF'
        header = b'II' + struct.pack('<HI', 42, 8) + struct.pack('<H', 1) + struct.pack('<HHII', 0x0132, 2, 20, 70000) + struct.pack('<I', 0)
        distant.write_bytes(header.ljust(70000, b'\x00') + b'2026:11:01 12:00:00\x00')
        assert core.extract_photo_date(distant) == '20261101'
        print('PASS fast EXIF header reader retains distant-IFD fallback')
        root = base/'shadow'; root.mkdir()
        for folder in ['DJpgshadow', 'DRawshadow']:
            (root/folder/'20261101').mkdir(parents=True)
            (root/folder/'20261101'/'X.JPG').write_bytes(b'do not organize')
        (root/'keep.JPG').write_bytes(b'active')
        pre = core.preview_scan(root, {'1','2','3','4'})
        assert pre['jpg'] == 1 and len(core.collect_candidates(root)) == 1
        core.organize_folder(root, 'normal', set(), verbose=False)
        assert len(list((root/'DJpgshadow').rglob('X.JPG'))) == 1
        assert scan(root)['counts']['jpg'] == 1
        print('PASS organizer and inventory exclude D-prefix pools')
    assert snapshot(source) == original
    print('ALL PASS; original test photos unchanged')

if __name__ == '__main__': main()
