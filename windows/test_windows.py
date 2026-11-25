"""Windows UI, organization and culling smoke tests with a disposable project."""
import argparse
import hashlib
import shutil
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from time import monotonic, sleep

from PIL import Image
from PySide6.QtCore import QPoint, QSettings, QSize, QTimer, Qt
from PySide6.QtGui import QFont
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QMessageBox, QToolButton

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
    expected = '\n'.join(str(Path(path).relative_to(ui.root)) for path in ui.library['poolDirectories'])
    seen = []

    def respond():
        dialog = QApplication.activeModalWidget()
        if not isinstance(dialog,QMessageBox):
            if dialog:
                dialog.reject()
            return
        seen.append(dialog.detailedText())
        if confirm:
            move = next((b for b in dialog.buttons() if dialog.buttonRole(b) == QMessageBox.ButtonRole.DestructiveRole),None)
            if move:
                move.click()
                return
        QTest.keyClick(dialog,Qt.Key.Key_Escape)

    QTimer.singleShot(0,respond)
    ui.pool_delete_button.click()
    assert seen == [expected]


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
        assert ops.read_journal(ui.journal)
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
        assert len(ops.read_journal(ui.journal)) == 1 and len(ops.read_journal(ui.journal)[0]) == 3
        assert len(ui.library['photos']) == 1 and ui.library['counts']['video'] == 1
        ui.restore_delete()
        wait_for(lambda: not ui.busy and len(ui.library['poolDirectories'])==3,'Ctrl+Z restores all pending folders')
        assert sidecar.read_bytes() == b'review notes' and ui.library['poolBatches']
        assert all(folder.is_dir() for folder in folders) and not ops.read_journal(ui.journal)
        print('PASS: Windows whole-pool confirmation/cancellation, all scopes, sidecar recovery and grouped Ctrl+Z')
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
        print('PASS: Windows UI, Unicode project, travel dry run, organize, paired JPEG, RAW scope, focus, scrub, W/S, restore, undo')
    finally:
        for pool in ui.tasks.pools.values():
            pool.waitForDone(5000)
        QTest.qWait(10)
        ui.close()


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw',type=Path)
    parser.add_argument('--nikon-samples',type=Path)
    parser.add_argument('--screenshot',type=Path)
    args = parser.parse_args()
    with TemporaryDirectory(prefix='zfilter-check-') as temp:
        test_workflow(Path(temp),args.raw,args.screenshot)
    if args.nikon_samples:
        test_nikon_metadata(args.nikon_samples)


if __name__ == '__main__':
    main()
