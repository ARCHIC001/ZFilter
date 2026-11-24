"""Exact byte accounting, including D pools, sidecars and refresh changes."""
import sys
import tempfile
from pathlib import Path
sys.path[:0] = [str(Path(__file__).resolve().parents[1]), str(Path(__file__).resolve().parent)]
from filter_bridge import scan

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    files = {'one/card/a.JPG':100, 'one/card/a.NEF':200, 'video/x.MOV':300,
             'video/y.NEV':400, 'video/z.R3D':500, 'note.xmp':600,
             'DJpgbatch/rejected.JPG':70, 'DRawbatch/rejected.NEF':80,
             '.hidden.JPG':9000, '.nikonfilter_logs/ignore.bin':10000}
    for name,size in files.items():
        p = root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'x'*size)
    before = {str(p):p.stat().st_mtime_ns for p in root.rglob('*') if p.is_file()}
    lib = scan(root)
    assert lib['sizes'] == {'jpg':100,'raw':200,'video':300,'rawvideo':900,'other':600,
                            'project':2250,'active':2100,'pool':150,'media':1650}
    assert lib['mediaCount'] == 7
    assert lib['counts'] == {'jpg':1,'raw':1,'video':1,'rawvideo':2}
    assert before == {str(p):p.stat().st_mtime_ns for p in root.rglob('*') if p.is_file()}
    (root/'new.JPG').write_bytes(b'new'*100)
    changed = scan(root)
    assert changed['sizes']['project'] == 2550 and changed['sizes']['jpg'] == 400 and changed['mediaCount'] == 8
    outside = root.parent/(root.name+'-external.JPG'); outside.write_bytes(b'x'*800)
    try:
        (root/'symlink.JPG').symlink_to(outside)
        assert scan(root)['sizes'] == changed['sizes']
    finally: outside.unlink()
print('PASS exact category / project / media / D-pool bytes, hidden/log exclusions, rescan and symlink scope; read-only')
