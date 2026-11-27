"""Windows UI, organization and culling smoke tests with a disposable project."""
import argparse
import hashlib
import shutil
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from time import monotonic, sleep
from unittest.mock import patch

from PIL import Image
from PySide6.QtCore import QPoint, QSettings, QSize, QTimer, Qt
from PySide6.QtGui import QFont
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QBoxLayout, QDialogButtonBox, QMessageBox, QToolButton, QTreeWidget, QTreeWidgetItemIterator

from windows.app import Window
from windows import media, operations as ops


def wait_for(predicate, name, seconds=20):
    end = monotonic()+seconds
    while not predicate():
        if monotonic() > end:
            raise AssertionError('Timed out: '+name)
        QApplication.processEvents()
        sleep(.015)


def digest(path):
    with path.open('rb') as image:
        return hashlib.file_digest(image,'sha256').hexdigest()


def answer_pool_confirmation(ui, confirm):
    expected = '\n'.join(str(Path(path).relative_to(ui.root)) if Path(path).is_relative_to(ui.root) else path
                         for path in ui.library['poolDirectories'])
    seen = []

    def respond():
        dialog = QApplication.activeModalWidget()
        if not isinstance(dialog,QMessageBox):
            if dialog:
                dialog.reject()
            return
        seen.append(dialog.detailedText())
        seen.append(dialog.text())
        if confirm:
            move = next((b for b in dialog.buttons() if dialog.buttonRole(b) == QMessageBox.ButtonRole.DestructiveRole),None)
            if move:
                move.click()
                return
        QTest.keyClick(dialog,Qt.Key.Key_Escape)

    QTimer.singleShot(0,respond)
    ui.pool_delete_button.click()
    assert len(seen) == 2 and seen[0] == expected and 'Windows 系统回收站' in seen[1]


def choose_folder(ui, folder):
    seen = []

    def respond():
        dialog = QApplication.activeModalWidget()
        if not dialog:
            return
        tree = dialog.findChild(QTreeWidget)
        if tree:
            iterator = QTreeWidgetItemIterator(tree)
            while item := iterator.value():
                path = item.data(0,Qt.ItemDataRole.UserRole)
                if path == (str(folder) if folder else None):
                    seen.append(item.text(0))
                    seen.append(dialog.objectName() == 'folderPicker' and tree.objectName() == 'folderTree'
                                and tree.parentWidget().dark == ui.dark)
                    tree.setCurrentItem(item)
                    dialog.findChild(QDialogButtonBox).button(QDialogButtonBox.StandardButton.Open).click()
                    return
                iterator += 1
        dialog.reject()

    QTimer.singleShot(0,respond)
    ui.folders_button.click()
    assert seen == [folder.name if folder else '全部文件夹', True] and ui.selected_folders.get(ui.pool) == folder


def assert_system_recycle(journal, project, count):
    batches = ops.read_journal(journal)
    assert len(batches) == 1 and len(batches[0]) == count
    for entry in batches[0]:
        path = Path(entry['trash'])
        assert entry['systemRecycle'] and path.exists() and not path.is_relative_to(project.resolve())
        if sys.platform == 'win32':
            assert path.parts[1].casefold() == '$recycle.bin', path
            assert path.name.upper().startswith('$R'), path
    assert not (project/'.nikonfilter_logs'/'recycle').exists()


def test_workflow(base, raw, screenshot):
    app = QApplication.instance() or QApplication([])
    app.setStyle('Fusion')
    app.setFont(QFont('Microsoft YaHei UI' if sys.platform=='win32' else 'PingFang SC',10))
    project = base / '外置盘模拟' / '影像项目'
    card = project / '存储卡'
    card.mkdir(parents=True)
    stamp = Image.Exif()
    stamp[0x8769] = {0x9003:'2026:11:01 14:01:39', 0x9204:-0.7, 0x9207:5, 0x9209:0}
    timestamp = media.metadata(raw).rows.get('拍摄时间') if raw else None
    if timestamp:
        stamp[0x8769][0x9003] = timestamp[:10].replace('-',':')+timestamp[10:]
    jpg = card / '照片01.JPG'
    second = card / '独立02.JPG'
    Image.new('RGB',(640,480),(65,128,190)).save(jpg,exif=stamp)
    Image.new('RGB',(640,480),(169,68,84)).save(second,exif=stamp)
    nef = card / '照片01.NEF'
    if raw:
        shutil.copyfile(raw,nef)
    else:
        nef.write_bytes(b'RAW placeholder for file operations')
    (card/'视频.MOV').write_bytes(b'video placeholder')
    original = {path.name:digest(path) for path in card.iterdir()}
    preferences = QSettings(str(base/'zfilter.ini'),QSettings.Format.IniFormat)
    ui = Window(preferences,base/'recycle.json')
    try:
        ui.show()
        ui.activateWindow()
        icons = [widget for widget in ui.findChildren(QToolButton) if widget.objectName() == 'tool']
        assert len(icons) >= 16 and all(widget.size() == QSize(36,36) and widget.iconSize() == QSize(18,18)
                                        and not widget.icon().isNull() for widget in icons)
        ui.collapse_button.click()
        assert ui.collapsed and ui.collapse_button.property('glyph') == 'sidebar-expand'
        ui.collapse_button.click()
        assert not ui.collapsed and ui.collapse_button.property('glyph') == 'sidebar-collapse'
        ui.open_project(project)
        assert ui.busy and ui.library is None
        wait_for(lambda: not ui.busy and ui.library is not None, 'JPEG/RAW/MOV inventory')
        assert ui.root == project.resolve()
        assert ui.library['pending'] == 4 and ui.library['paired'] == 1
        ui.travel.click()
        wait_for(lambda: not ui.busy and ui.library['preview']['travel_date_folders'] > 0,'travel preview')
        ui.dry.click()
        ui.organize()
        wait_for(lambda: not ui.busy,'dry run')
        assert ui.library['pending'] == 4 and not ui.library['history']
        ui.dry.click()
        ui.organize()
        wait_for(lambda: not ui.busy and ui.library['organized'],'organize')
        assert ui.library['paired'] == 1 and len(ui.library['history']) == 1
        assert ui.library['sizes']['jpg'] > 0

        ui.nav[1].click()
        assert ui.pages.currentIndex() == 1
        assert not ui.pool_delete_button.isVisible()
        wait_for(lambda: ui.frame is not None,'paired JPEG decode')
        assert ui.path.endswith('照片01.JPG') and len(ui.photos) == 1
        initial_theme = ui.dark
        for width,direction in [(980,QBoxLayout.Direction.TopToBottom),(1320,QBoxLayout.Direction.LeftToRight)]:
            ui.resize(width,720)
            QTest.qWait(40)
            assert ui.viewer_header_layout.direction() == direction
            assert ui.folders_button.width() >= 154 and ui.folders_button.height() == ui.pool_buttons[0].height()
            assert ui.folders_button.iconSize() == QSize(18,18) and not ui.folders_button.icon().isNull()
            choose_folder(ui,None)
            ui.brand.click()
        assert ui.dark == initial_theme
        ui.resize(1320,880)
        print('PASS: folder toolbar sizing, alignment and themed directory surface in light/dark')
        dated_folder = Path(ui.path).parent
        assert dated_folder.parent != ui.root
        choose_folder(ui,dated_folder)
        assert len(ui.photos) == 1
        choose_folder(ui,None)
        ui.info_toggle.click()
        assert ui.info_toggle.isChecked() and ui.file_details.rowCount() >= 3
        assert ui.frame.metadata.rows['拍摄时间'] == stamp[0x8769][0x9003].replace(':','-',2)
        assert sum(ui.frame.histogram[0]) == sum(ui.frame.histogram[3])
        assert not ui.frame.blur.isNull()
        ui.scope_buttons[0].click()
        assert ui.scope == 0 and len(ui.photos) == 2
        ui.zoom_button.click()
        assert ui.photo_view.tracking and ui.viewport_label.startswith('100%')
        ui.step(-1 if ui.index else 1)
        wait_for(lambda: ui.frame is not None and ui.photo_view.tracking and ui.viewport_label.startswith('100%'),'focus tracking across next JPEG')
        ui.fit_button.click()
        assert ui.photo_view.fit and not ui.photo_view.tracking
        ui.scrubber.resize(600,20)
        ui.scrubber.setMaximum(999)
        ui.scrubber.seek_to(8 + (600-16)*.9)
        assert ui.scrubber.value() == 899
        # Restore the short project's range before simulating a real rail click.
        ui.render_filmstrip()
        QTest.mouseClick(ui.scrubber,Qt.MouseButton.LeftButton,pos=QPoint(ui.scrubber.width()-8,ui.scrubber.height()//2))
        assert ui.index == 1
        ui.scope_buttons[1].click()
        assert ui.scope == 1 and len(ui.photos) == 1
        if raw:
            wait_for(lambda: ui.frame is not None or ui.placeholder.text().startswith('无法解码'),'full RAW LibRaw decode',45)
            assert ui.frame is not None, ui.statusBar().currentMessage()
            assert ui.path.endswith('.NEF') and ui.frame.image.height()>2000
        ui.scope_buttons[2].click()
        wait_for(lambda: ui.frame is not None,'return to paired JPEG')
        active = tuple(ops.selected_paths(ui.photo,ui.scope_name))
        ui.w_button.click()
        assert not ui.photos, 'the parked frame leaves the viewer immediately'
        wait_for(lambda: not ui.busy and len(ui.library['poolPhotos'])==1,'W stage')
        assert not any(Path(path).exists() for path in active)
        ui.pool_buttons[1].click()
        assert ui.pool and len(ui.photos)==1
        assert ui.w_button.property('glyph') == 'unstage'
        assert ui.path and Path(ui.path).exists()
        ui.s_button.click()
        wait_for(lambda: not ui.busy and not ui.library['poolPhotos'],'S recycle from pending pool')
        assert_system_recycle(ui.journal,project,2)
        ui.restore_delete()
        wait_for(lambda: not ui.busy and len(ui.library['poolPhotos'])==1,'Ctrl+Z restores to pending pool')

        extra = project/'待复核'/'DJpg只有附属文件'
        extra.mkdir(parents=True)
        sidecar = extra/'notes.xmp'
        sidecar.write_bytes(b'review notes')
        ui.rescan()
        wait_for(lambda: not ui.busy and len(ui.library['poolDirectories'])==3,'inventory of complete pending pool')
        ui.scope_buttons[0].click()
        folders = tuple(map(Path,ui.library['poolDirectories']))
        assert ui.pool_delete_button.isVisible() and ui.pool_delete_button.isEnabled()
        assert ui.pool_delete_button.iconSize() == QSize(18,18) and not ui.pool_delete_button.icon().isNull()
        answer_pool_confirmation(ui,False)
        assert all(folder.is_dir() for folder in folders) and not ops.read_journal(ui.journal)
        answer_pool_confirmation(ui,True)
        wait_for(lambda: not ui.busy and not ui.library['poolDirectories'],'confirmed whole-pool removal')
        assert ui.pool and not ui.pool_delete_button.isEnabled() and not ui.library['poolBatches']
        assert not any(folder.exists() for folder in folders)
        assert_system_recycle(ui.journal,project,3)
        assert len(ui.library['photos']) == 1 and ui.library['counts']['video'] == 1
        ui.restore_delete()
        wait_for(lambda: not ui.busy and len(ui.library['poolDirectories'])==3,'Ctrl+Z restores all pending folders')
        assert sidecar.read_bytes() == b'review notes' and ui.library['poolBatches']
        assert all(folder.is_dir() for folder in folders) and not ops.read_journal(ui.journal)
        print('PASS: system Recycle Bin for photos and whole pools, confirmation/cancellation, sidecars and grouped Ctrl+Z')
        ui.scope_buttons[2].click()
        ui.w_button.click()
        wait_for(lambda: not ui.busy and not ui.library['poolPhotos'],'W restores pair to formal pool')
        assert all(Path(path).exists() for path in active)
        ui.pool_buttons[0].click()
        assert not ui.pool and len(ui.photos)==1
        wait_for(lambda: ui.frame is not None,'restored JPEG')
        initial = ui.dark
        ui.brand.click()
        assert ui.dark != initial and ui.settings.value('theme') in {'dark','light'}
        if screenshot:
            screenshot.parent.mkdir(parents=True,exist_ok=True)
            assert ui.grab().save(str(screenshot))
        ui.organize(undo=True)
        wait_for(lambda: not ui.busy and ui.library['pending']==4,'undo organization')
        assert original == {path.name:digest(path) for path in card.iterdir()}
        assert len(ui.projects)==1
        ui.remove_project(ui.projects[0])
        assert not ui.projects and jpg.exists() and nef.exists()
        check_shadow_project(ui,base,jpg,nef)
        print('PASS: Windows UI, Unicode project, travel dry run, organize, paired JPEG, RAW scope, focus, scrub, W/S, restore, undo')
    finally:
        for pool in ui.tasks.pools.values():
            pool.waitForDone(5000)
        QTest.qWait(10)
        ui.close()


def check_shadow_project(ui, base, jpg, nef):
    root = base.resolve() / '原始素材'
    for branch in ('相册甲','相册乙'):
        folder = root / branch / '原始卡'
        folder.mkdir(parents=True)
        shutil.copyfile(jpg,folder/'照片.JPG')
        shutil.copyfile(nef,folder/'照片.NEF')
    (root/'相册乙'/'空目录').mkdir()
    ui.open_project(root)
    wait_for(lambda: not ui.busy and bool(ui.library),'new folder project')
    ui.show_page(0)
    ui.mode_buttons.button(3).click()
    ui.run_button.click()
    wait_for(lambda: not ui.busy and ui.pages.currentIndex()==1 and bool(ui.library['shadowPool']),'create shadow pool')
    mirror = Path(ui.library['shadowPool']['path'])
    assert mirror.parent == root.parent and (mirror/'相册乙'/'空目录').is_dir()
    assert not ui.library['history'] and not any(path.is_file() for path in mirror.rglob('照片.*'))
    choose_folder(ui,root/'相册甲')
    assert len(ui.photos) == 1 and Path(ui.path).is_relative_to(root/'相册甲')
    formal = Path(ui.path)
    relative = formal.relative_to(root)
    ui.w_button.click()
    wait_for(lambda: not ui.busy and (mirror/relative).exists(),'staging a scoped pair into the shadow')
    assert not formal.exists() and (root/'相册乙'/'原始卡'/'照片.JPG').exists()
    ui.pool_buttons[1].click()
    choose_folder(ui,mirror/'相册甲'/'原始卡')
    assert len(ui.photos) == 1 and Path(ui.path) == mirror/relative
    ui.w_button.click()
    wait_for(lambda: not ui.busy and formal.exists(),'restore a shadow pair to its original nested location')
    assert not ui.photos
    ui.pool_buttons[0].click()
    assert ui.selected_folders[False] == root/'相册甲' and len(ui.photos) == 1
    ui.w_button.click()
    wait_for(lambda: not ui.busy and (mirror/relative).exists(),'stage again for bulk recycle')
    ui.pool_buttons[1].click()
    answer_pool_confirmation(ui,True)
    wait_for(lambda: not ui.busy and not mirror.exists(),'recycle the owned sibling')
    assert_system_recycle(ui.journal,root,1)
    ui.restore_delete()
    wait_for(lambda: not ui.busy and (mirror/relative).exists(),'undo the entire shadow directory recycle')
    ui.open_project(root)
    wait_for(lambda: not ui.busy and bool(ui.library),'reopen shadow project')
    assert ui.mode_buttons.checkedId() == 3 and ui.library['shadowPool']['path'] == str(mirror)
    print('PASS: travel folder tree, shadow initialization, nested duplicate names, scoped W, restored sibling, persistent mode')


def test_nikon_metadata(sample):
    jpg = next(sample.rglob('DSC_0926.JPG'))
    nef = next(sample.rglob('DSC_0926.NEF'))
    jpeg, raw = media.metadata(jpg),media.metadata(nef)
    assert jpeg.focus == raw.focus and abs(raw.focus[0]-3813/8256)<.00001
    assert jpeg.rows['色彩预设'] == raw.rows['色彩预设'] == 'ArmitageProvia100F'
    assert raw.rows['对焦距离'] == '约 1.26 m' and jpeg.rows['曝光补偿'] == '-0.7 EV'
    paths = [next(sample.rglob(f'DSC_{index:04d}.JPG')) for index in range(920,923)]
    assert len({media.metadata(path).burst for path in paths}) == 1 and media.metadata(paths[0]).burst
    print('PASS: actual Z8 JPEG/NEF EXIF, focus center/box, distance, preset and burst identity')


def test_recycle_refusal_and_legacy_undo(base):
    root = base.resolve() / 'recovery-test'
    root.mkdir()
    original = root / 'photo.JPG'
    original.write_bytes(b'original')
    journal = base / 'recovery-test.json'
    with patch.object(ops, 'QFile') as native_file:
        native_file.return_value.moveToTrash.return_value = False
        native_file.return_value.fileName.return_value = str(original)
        try:
            ops.recycle(root, [original], journal)
        except OSError:
            pass
        else:
            raise AssertionError('a refused native recycle must report failure')
    assert original.read_bytes() == b'original' and not ops.read_journal(journal)
    older_path = root / '.nikonfilter_logs/recycle/older/photo.JPG'
    ops.move_without_overwrite(original, older_path)
    ops.write_journal(journal, [[{'root': str(root), 'original': str(original), 'trash': str(older_path)}]])
    ops.restore_recycle(journal)
    assert original.read_bytes() == b'original' and not older_path.exists() and not ops.read_journal(journal)
    print('PASS: refused system recycle leaves the original in place; older preview deletes still undo')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw',type=Path)
    parser.add_argument('--nikon-samples',type=Path)
    parser.add_argument('--screenshot',type=Path)
    args = parser.parse_args()
    with TemporaryDirectory(prefix='zfilter-check-') as temp:
        test_recycle_refusal_and_legacy_undo(Path(temp))
        test_workflow(Path(temp),args.raw,args.screenshot)
    if args.nikon_samples:
        test_nikon_metadata(args.nikon_samples)


if __name__ == '__main__':
    main()
