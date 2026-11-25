"""File operations shared with the project's existing organizer and log format."""
from dataclasses import asdict
import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

import nikonfilter as core
from GUI.filter_bridge import scan

SCOPES = ("仅 JPEG", "仅 RAW", "JPEG + RAW")


def scoped(library, scope, pool):
    if not library:
        return []
    if scope == SCOPES[1]:
        return library['poolRawPhotos' if pool else 'rawPhotos']
    photos = library['poolPhotos' if pool else 'photos']
    if scope == SCOPES[2]:
        return [photo for photo in photos if photo['raw'] and photo['status'] == '已配对']
    return photos


def display_path(photo, scope):
    return photo['raw'] if scope == SCOPES[1] else photo['jpeg']


def selected_paths(photo, scope):
    if scope == SCOPES[2]:
        if not (photo.get('raw') and photo.get('jpeg') and photo['status'] == '已配对'):
            raise ValueError('没有经过验证的 JPEG／RAW 配对。')
        return [photo['jpeg'], photo['raw']]
    path = display_path(photo, scope)
    return [path] if path else []


def without_paths(library, paths, pool):
    """Preview the removal while the filesystem worker commits and rescans."""
    result = dict(library)
    for key, display in (('poolPhotos' if pool else 'photos','jpeg'),
                         ('poolRawPhotos' if pool else 'rawPhotos','raw')):
        rows = []
        for photo in library[key]:
            if photo[display] in paths:
                continue
            jpeg = '' if photo['jpeg'] in paths else photo['jpeg']
            raw = None if photo['raw'] in paths else photo['raw']
            if jpeg != photo['jpeg'] or raw != photo['raw']:
                photo = {**photo, 'jpeg': jpeg, 'raw': raw,
                         'status': '仅 RAW' if not jpeg else '仅 JPEG', 'source': ''}
            rows.append(photo)
        result[key] = rows
    return result


def organize(root, mode, rules, travel, dry, progress=None):
    result, _, _ = core.organize_folder(root, mode, set(rules), dry_run=dry,
                                        verbose=False, travel_mode=travel, progress_callback=progress)
    return asdict(result)


def undo(root):
    return asdict(core.undo_last_execution(root, verbose=False))


def read_journal(path):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else []


def write_journal(path, batches):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as output:
            temp = Path(output.name)
            json.dump(batches, output, ensure_ascii=False)
            output.flush()
            os.fsync(output.fileno())
        temp.replace(path)
    finally:
        if temp:
            temp.unlink(missing_ok=True)


def move_without_overwrite(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if os.name == 'nt':
        source.rename(target)  # Windows rename fails atomically if target exists.
    else:
        os.link(source, target)
        try:
            source.unlink()
        except OSError:
            target.unlink()
            raise


def inside(root, path):
    path = Path(path)
    if path.is_symlink() or not path.resolve().is_relative_to(root) or path.resolve() == root:
        raise ValueError(f'路径超出项目或指向符号链接：{path}')
    return path.resolve()


def shadow_destination(root, path, raw):
    relative = path.relative_to(root)
    if any(core.is_shadow_directory(Path(part)) for part in relative.parts[:-1]):
        raise ValueError('文件不在正式池。')
    for parent in path.parents:
        if parent == root:
            break
        if parent.name.lower().startswith(('jpg', 'jpeg', 'raw')):
            return parent.with_name('D'+parent.name) / path.relative_to(parent)
    return root / (('DRaw' if raw else 'DJpg')+root.name) / relative


def unique_destination(path):
    if path.exists() or path.is_symlink():
        return path.with_name(f'{path.stem}.{uuid4().hex}{path.suffix}')
    return path


def pool_journal(root):
    return root / core.LOG_DIR_NAME / 'pool.json'


def record_then_move(journal, batches, batch, entries):
    batches.append(batch)
    write_journal(journal, batches)
    moved = []
    try:
        for entry in entries:
            move_without_overwrite(Path(entry['original']), Path(entry['trash']))
            moved.append(entry)
    except OSError:
        for entry in reversed(moved):
            try:
                move_without_overwrite(Path(entry['trash']), Path(entry['original']))
            except OSError:
                pass  # Keep a recovery entry when an interrupted move could not be rolled back.
        moved = [entry for entry in moved if Path(entry['trash']).exists()]
        entries[:] = moved
        write_journal(journal, batches if moved else batches[:-1])
        raise


def stage(root, photo, paths):
    journal = inside(root, pool_journal(root))
    entries = []
    for path in paths:
        original = inside(root, path)
        if not original.is_file():
            raise FileNotFoundError(original)
        target = inside(root, unique_destination(shadow_destination(root, original, str(original) == photo.get('raw'))))
        entries.append({'original': str(original), 'trash': str(target)})
    if entries:
        batch = {'id': uuid4().hex, 'photo': photo, 'entries': entries}
        record_then_move(journal, read_journal(journal), batch, entries)


def restore_pool(root, paths=(), all_batches=False):
    journal = inside(root, pool_journal(root))
    batches = read_journal(journal)
    requested = {inside(root, path) for path in paths}
    selected = {}
    for batch in batches:
        for entry in batch['entries']:
            source = inside(root, entry['trash'])
            if all_batches or source in requested:
                selected[source] = inside(root, entry['original'])
    for source in requested.difference(selected):
        parts = list(source.relative_to(root).parts)
        index = next((i for i, part in enumerate(parts[:-1]) if core.is_shadow_directory(Path(part))), None)
        if index is None:
            raise ValueError(f'找不到待删文件的恢复目录：{source}')
        parts[index] = parts[index][1:]
        selected[source] = inside(root, root.joinpath(*parts))
    restore_entries(selected)
    for batch in batches:
        batch['entries'] = [entry for entry in batch['entries'] if Path(entry['trash']) not in selected]
    if batches:
        write_journal(journal, [batch for batch in batches if batch['entries']])


def recycle(root, paths, journal):
    # Same-volume recovery between launches. Keep all moved bytes under the project
    # so an external disk can be detached without leaving media on the system drive.
    target_dir = root / core.LOG_DIR_NAME / 'recycle' / uuid4().hex
    entries = []
    for path in paths:
        original = inside(root, path)
        if not original.is_file():
            raise FileNotFoundError(original)
        target = inside(root, unique_destination(target_dir / uuid4().hex / original.name))
        entries.append({'original': str(original), 'trash': str(target), 'root': str(root)})
    if entries:
        record_then_move(journal, read_journal(journal), entries, entries)


def restore_entries(selected):
    if len(set(selected.values())) != len(selected):
        raise ValueError('多份文件指向同一个恢复路径。')
    for source, target in selected.items():
        if source.exists():
            if target.exists() or target.is_symlink():
                raise FileExistsError(f'原路径已有文件，恢复已停止：{target}')
        elif not target.is_file():
            raise FileNotFoundError(f'找不到可恢复的文件：{source}')
    for source, target in selected.items():
        if source.exists():
            move_without_overwrite(source, target)


def restore_recycle(journal):
    batches = read_journal(journal)
    if not batches:
        return None
    selected = {}
    for entry in batches[-1]:
        root = core.safe_resolve_dir(entry['root'])
        source = inside(root, entry['trash'])
        target = inside(root, entry['original'])
        if not source.is_relative_to(root / core.LOG_DIR_NAME / 'recycle'):
            raise ValueError('文件不在项目的 ZFilter 废纸篓。')
        selected[source] = target
    restore_entries(selected)
    write_journal(journal, batches[:-1])
    return batches[-1][0]['root']
