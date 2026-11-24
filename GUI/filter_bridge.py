"""JSON-lines adapter; the CLI remains the single organizer implementation."""
import json
import sys
from dataclasses import asdict
from pathlib import Path
import nikonfilter as core


def scan(root, mode="normal", rules=None, travel=False):
    root = root.resolve()
    # The selected directory is the project boundary. Pair discovery must never
    # silently broaden the scan or change the root used for subsequent moves.
    files = sorted((p for p in core.iter_files_recursive(root, set()) if p.is_file() and not p.is_symlink()), key=lambda p: str(p).lower())
    file_set = set(files)
    jpgs = [p for p in files if p.suffix.lower() in core.JPEG_EXT]
    raws = [p for p in files if p.suffix.lower() in core.RAW_PHOTO_EXT]
    rawset = set(raws)
    recorded = {}
    moved_paths = {}
    logs = root / core.LOG_DIR_NAME
    if logs.exists():
        for log in sorted(logs.glob('*.json')):
            if log.name in {'latest.json', 'pool.json'}:
                continue
            try:
                data = json.loads(log.read_text())
                if not isinstance(data, dict):
                    continue
                groups = {}
                for e in data.get('entries', []):
                    original = Path(e['src_before']).resolve()
                    actual = Path(e['src_before'] if e.get('reverted') else e['dst_after']).resolve()
                    if actual.is_file(): moved_paths[original] = actual
                    key = (str(original.parent), original.stem.casefold())
                    groups.setdefault(key, []).append(actual)
                for group in groups.values():
                    js = [p for p in group if p.suffix.lower() in core.JPEG_EXT]
                    rs = [p for p in group if p.suffix.lower() in core.RAW_PHOTO_EXT]
                    if len(js) == len(rs) == 1:
                        recorded[js[0]] = rs[0]
            except (ValueError, KeyError, OSError):
                continue
    pool_path = logs / 'pool.json'
    batches = json.loads(pool_path.read_text()) if pool_path.exists() else []
    for batch in batches:
        if batch['photo'].get('jpeg'): batch['photo']['jpeg'] = str(Path(batch['photo']['jpeg']).resolve())
        if batch['photo'].get('raw'): batch['photo']['raw'] = str(Path(batch['photo']['raw']).resolve())
        for entry in batch['entries']:
            entry['original'] = str(Path(entry['original']).resolve())
            entry['trash'] = str(Path(entry['trash']).resolve())
    def mapped(path, batch):
        if not path: return None
        for e in batch['entries']:
            if e['original'] == path and Path(e['trash']).is_file():
                return Path(e['trash'])
        original = Path(path)
        return original if original.is_file() else moved_paths.get(original, original)
    def shadow(path):
        return any(core.is_shadow_directory(Path(part)) for part in path.relative_to(root).parts[:-1])
    for batch in batches:
        photo = batch['photo']
        j, r = mapped(photo['jpeg'], batch), mapped(photo.get('raw'), batch)
        # Each physical file belongs to its own pool. Moving only RAW must not
        # hide its untouched JPEG, or manufacture a JPEG in the RAW pool.
        if j and r and j.is_file() and r.is_file() and shadow(j) == shadow(r): recorded[j] = r
        batch['photo'] = {'jpeg': str(j) if j and j.is_file() else '', 'raw': str(r) if r and r.is_file() else None, 'status': photo['status'], 'source': photo.get('source', '')}
    # Logs use formal paths; manually moved D-folders can still recover their identity.
    shadow_aliases = {}
    for path in jpgs + raws:
        if shadow(path):
            relative = path.relative_to(root)
            parts = [part[1:] if core.is_shadow_directory(Path(part)) else part for part in relative.parts]
            shadow_aliases[root.joinpath(*parts)] = path
    for j, r in list(recorded.items()):
        actual_j, actual_r = shadow_aliases.get(j, j), shadow_aliases.get(r, r)
        if actual_j != j or actual_r != r: recorded[actual_j] = actual_r
    jgroups, rgroups = {}, {}
    for p in jpgs:
        jgroups.setdefault(p.stem.casefold(), []).append(p)
    for p in raws:
        rgroups.setdefault(p.stem.casefold(), []).append(p)
    recorded = {j: r for j, r in recorded.items() if j in file_set and r in rawset and shadow(j) == shadow(r)}
    reserved = set(recorded.values())
    photos, used = [], set()
    for j in jpgs:
        candidates = [r for r in rgroups.get(j.stem.casefold(), []) if shadow(r) == shadow(j)]
        raw = recorded.get(j)
        source = '整理记录'
        if raw is not None:
            raw = raw if raw in rawset else None
        else:
            candidates = [r for r in candidates if r not in reserved]
            local = [r for r in candidates if r.parent == j.parent]
            if len(local) == 1 and len([p for p in jgroups[j.stem.casefold()] if p.parent == j.parent]) == 1:
                raw, source = local[0], '同目录同名'
            elif len(candidates) == 1 and len([p for p in jgroups[j.stem.casefold()] if shadow(p) == shadow(j)]) == 1:
                raw, source = candidates[0], '唯一同名'
        if raw and source != '整理记录':
            jpeg_date, raw_date = core.extract_photo_date(j), core.extract_photo_date(raw)
            if jpeg_date and raw_date and jpeg_date != raw_date:
                raw = None
            elif jpeg_date and raw_date:
                source += ' · EXIF 日期一致'
        if raw in used:
            raw = None
        if raw:
            used.add(raw)
        status = '已配对' if raw else ('配对歧义' if candidates and j not in recorded else '仅 JPEG')
        photos.append({'jpeg': str(j), 'raw': str(raw) if raw else None, 'status': status, 'source': source if raw else ''})
    active = [p for p in photos if not shadow(Path(p['jpeg']))]
    pool = [p for p in photos if shadow(Path(p['jpeg']))]
    reverse = {p['raw']: p for p in photos if p['raw']}
    raw_photos = [dict(reverse[str(r)]) if str(r) in reverse else {'jpeg': '', 'raw': str(r), 'status': '仅 RAW', 'source': ''} for r in raws]
    active_raw = [p for p in raw_photos if not shadow(Path(p['raw']))]
    pool_raw = [p for p in raw_photos if shadow(Path(p['raw']))]
    active_files = [p for p in files if not shadow(p)]
    formats = {}
    for p in active_files:
        if core.classify_file(p) != 'OTHER' or p.suffix.lower() == '.r3d': formats[p.suffix.upper().lstrip('.')] = formats.get(p.suffix.upper().lstrip('.'), 0) + 1
    counts = {'jpg': sum(p.suffix.lower() in core.JPEG_EXT for p in active_files), 'raw': sum(p.suffix.lower() in core.RAW_PHOTO_EXT for p in active_files), 'video': sum(p.suffix.lower() in core.VIDEO_CONTAINER_EXT for p in active_files), 'rawvideo': sum(p.suffix.lower() in (core.RAW_VIDEO_EXT | {'.r3d'}) for p in active_files)}
    # Logical file bytes, same scope as the visible project. Hidden control logs
    # and symlinks are excluded; D-pool bytes are included in the project total.
    file_sizes = {p: p.stat().st_size for p in files}
    def category(p):
        ext = p.suffix.lower()
        if ext in core.JPEG_EXT: return 'jpg'
        if ext in core.RAW_PHOTO_EXT: return 'raw'
        if ext in core.VIDEO_CONTAINER_EXT: return 'video'
        if ext in core.RAW_VIDEO_EXT | {'.r3d'}: return 'rawvideo'
        return 'other'
    sizes = {key: sum(file_sizes[p] for p in active_files if category(p) == key) for key in ('jpg', 'raw', 'video', 'rawvideo', 'other')}
    sizes.update(project=sum(file_sizes.values()), active=sum(file_sizes[p] for p in active_files), pool=sum(file_sizes[p] for p in files if shadow(p)), media=sum(size for p,size in file_sizes.items() if category(p) != 'other'))
    media_count = sum(category(p) != 'other' for p in files)
    for photo in active + pool + active_raw + pool_raw:
        photo['jpegBytes'] = file_sizes.get(Path(photo['jpeg']), 0) if photo['jpeg'] else 0
        photo['rawBytes'] = file_sizes.get(Path(photo['raw']), 0) if photo['raw'] else 0
    history = []
    has_moves = False
    if logs.exists():
        for p in sorted(logs.glob('*.json'), reverse=True):
            if p.name in {'latest.json', 'pool.json'}:
                continue
            try:
                d = json.loads(p.read_text())
                if not isinstance(d, dict):
                    continue
                has_moves = has_moves or any(not e.get('reverted') and Path(e.get('dst_after', '')).resolve() in file_set for e in d.get('entries', []))
                history.append({'id': d['run_id'], 'timestamp': d['timestamp'], 'mode': d['mode_label'], 'moved': d['stats'].get('moved', 0), 'path': str(p)})
            except (OSError, ValueError, KeyError):
                pass
    preview = core.preview_scan(root, core.resolve_effective_rules(mode, set(rules or [])), travel)
    # Completion is independent of which custom rules are currently selected.
    pending = sum(core.classify_file(p) != 'OTHER' for p in core.collect_candidates(root))
    organized = has_moves and pending == 0
    return {'root': str(root), 'pending': pending, 'photos': active, 'rawPhotos': active_raw, 'poolPhotos': pool, 'poolRawPhotos': pool_raw, 'poolBatches': batches, 'counts': counts, 'formats': formats, 'sizes': sizes, 'mediaCount': media_count, 'organized': organized, 'preview': preview, 'paired': sum(p['raw'] is not None for p in active), 'orphanRaw': sum(not p['jpeg'] for p in active_raw), 'ambiguous': sum(p['status']=='配对歧义' for p in active), 'history': history}


def emit(data):
    print(json.dumps(data, ensure_ascii=False), flush=True)


def main():
    req = json.load(sys.stdin)
    root = core.safe_resolve_dir(req['root'])
    action = req['action']
    mode = req.get('mode', 'normal')
    rules = set(req.get('rules', ['1', '2', '3', '4']))
    travel = req.get('travel', False)
    if action == 'scan':
        emit(scan(root, mode, rules, travel))
    elif action == 'preview':
        emit(core.preview_scan(root, core.resolve_effective_rules(mode, rules), travel))
    elif action == 'run':
        def progress(current, total, name):
            emit({'progress': current / max(total, 1), 'name': name})
        result, preview, log = core.organize_folder(root, mode, rules, dry_run=req.get('dry', False), verbose=False, travel_mode=travel, progress_callback=progress)
        emit({'result': asdict(result), 'preview': preview, 'log': str(log) if log else None, 'library': scan(root, mode, rules, travel)})
    elif action == 'undo':
        emit({'result': asdict(core.undo_last_execution(root, verbose=False)), 'library': scan(root, mode, rules, travel)})
    else:
        raise ValueError('未知操作')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit({'error': str(error)})
        sys.exit(1)
