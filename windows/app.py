"""ZFilter Windows desktop interface."""
from collections import OrderedDict
from functools import partial
import argparse
import json
from pathlib import Path
import sys

from PySide6.QtCore import QDateTime, QEvent, QObject, QRectF, QSettings, QSize, QStandardPaths, QThreadPool, QTimer, QUrl, Qt, Signal, Slot
from PySide6.QtGui import (
    QBrush, QColor, QDesktopServices, QFont, QIcon, QImage, QKeySequence, QLinearGradient,
    QPainter, QPalette, QPixmap, QShortcut,
)
from PySide6.QtWidgets import (
    QApplication, QAbstractButton, QBoxLayout, QButtonGroup, QCheckBox, QDateTimeEdit, QDialog, QDialogButtonBox,
    QFileDialog, QFormLayout, QFrame, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
    QMainWindow, QMenu, QMessageBox, QProgressBar, QPushButton, QScrollArea, QSizePolicy,
    QStackedWidget, QToolButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
)

import nikonfilter as core
from windows import media, operations as ops
from windows.icon import SIZE as ICON_SIZE, fluent_icon
from windows.viewer import Departure, Histogram, Material, PhotoView, Scrubber, Tile

ICON = Path(__file__).resolve().parents[1] / 'docs/images/zfilter-icon.png'
MODES = ('normal', 'red', 'custom', 'shadow')
RULES = ('JPEG 照片', 'RAW 照片', '普通视频', 'NEV 与代理', 'RED / R3D 与代理')
COLORS = ('#1dcd3a', '#ffbb10', '#fa382e')
POOL_COLORS = ('#1dcd3a', '#ff844a')


def byte_text(count):
    if count is None:
        return '未读取'
    value = float(count)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if value < 1000 or unit == 'TB':
            return f'{count:,} B' if unit == 'B' else f'{value:.1f} {unit}'
        value /= 1000


def label(text='', role='', wrap=False):
    widget = QLabel(text)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(wrap)
    if role:
        widget.setObjectName(role)
    return widget


def button(text, action, tip=None, checkable=False, compact=False, glyph=None):
    widget = QToolButton() if compact else QPushButton()
    widget.setText(text)
    if glyph:
        widget.setProperty('glyph',glyph)
        widget.setIconSize(ICON_SIZE)
        if compact:
            widget.setObjectName('tool')
            widget.setFixedSize(36,36)
    widget.setCheckable(checkable)
    widget.setCursor(Qt.CursorShape.PointingHandCursor)
    widget.setAccessibleName(tip or text)
    if tip:
        widget.setToolTip(tip)
    widget.clicked.connect(action)
    return widget


def folder_icon(online, active):
    pixmap = QPixmap(25, 25)
    pixmap.fill(Qt.GlobalColor.transparent)
    draw = QPainter(pixmap)
    draw.setRenderHint(QPainter.RenderHint.Antialiasing)
    draw.setPen(Qt.PenStyle.NoPen)
    draw.setBrush(QColor('#3482ff' if active else '#8796aa'))
    draw.drawRoundedRect(2, 6, 11, 7, 2, 2)
    draw.drawRoundedRect(2, 9, 19, 11, 2, 2)
    draw.setBrush(QColor('#1dcd3a' if online else '#ffbb10'))
    draw.drawEllipse(17, 16, 7, 7)
    draw.end()
    return QIcon(pixmap)


class Tasks(QObject):
    completed = Signal(object, object, object)
    progress = Signal(str, float)

    def __init__(self, parent):
        super().__init__(parent)
        self.pools = {}
        for category, limit in [('io',1),('decode',2),('thumb',2),('metadata',1),('presence',1)]:
            pool = QThreadPool(self)
            pool.setMaxThreadCount(limit)
            self.pools[category] = pool
        self.completed.connect(self.deliver, Qt.ConnectionType.QueuedConnection)
        self.stopping = False

    def submit(self, category, work, done):
        def run():
            try:
                result, error = work(), None
            except Exception as exc:
                result, error = None, exc
            if not self.stopping:
                self.completed.emit(done, result, error)
        self.pools[category].start(run)

    @Slot(object, object, object)
    def deliver(self, callback, result, error):
        callback(result, error)


class Window(QMainWindow):
    def __init__(self, preferences=None, journal=None):
        super().__init__()
        self.setWindowTitle('ZFilter')
        self.setWindowIcon(QIcon(str(ICON)))
        self.setMinimumSize(980, 660)
        self.resize(1320, 880)
        self.settings = preferences or QSettings('ZFilter', 'ZFilter')
        data = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppLocalDataLocation)
        self.journal = journal or Path(data) / 'trash-history.json'
        self.projects = json.loads(self.settings.value('projects', '[]', str))
        self.presence = {}
        self.presence_busy = False
        self.root = None
        self.library = None
        self.busy = False
        self.load_error = False
        self.scope = self.settings.value('scope', 2, int)
        self.scope = self.scope if 0 <= self.scope < 3 else 2
        self.pool = False
        self.index = 0
        self.photos = []
        self.pool_selection = {}
        self.selected_folders = {}
        self.burst_ids = {}
        self.bursts_scanned = False
        self.bursts_scanning = False
        self.burst_generation = 0
        self.fold_all = False
        self.burst_overrides = set()
        self.representatives = {}
        self.groups = {}
        self.collapsed = self.settings.value('sidebarCollapsed', False, bool)
        self.immersive = False
        self.theme = self.settings.value('theme', 'system', str)
        self.frame_cache = OrderedDict()
        self.thumb_cache = OrderedDict()
        self.thumb_pending = set()
        self.frame = None
        self.loading_path = None
        self.image_generation = 0
        self.viewport_label = '适应窗口'
        self.tasks = Tasks(self)
        self.tasks.progress.connect(self.progress_update)
        self.preview_timer = QTimer(self, interval=160, singleShot=True)
        self.preview_timer.timeout.connect(self.preview_project)
        self.build_ui()
        self.apply_theme()
        QApplication.instance().styleHints().colorSchemeChanged.connect(self.apply_theme)
        self.refresh_projects()
        self.presence_timer = QTimer(self, interval=5000)
        self.presence_timer.timeout.connect(self.check_presence)
        self.presence_timer.start()
        self.check_presence()
        self.show_page(0)

    def build_ui(self):
        surface = QWidget()
        surface.setObjectName('surface')
        outer = QHBoxLayout(surface)
        outer.setContentsMargins(14, 14, 14, 14)
        outer.setSpacing(13)
        self.setCentralWidget(surface)
        self.sidebar = QWidget()
        self.sidebar.setObjectName('sidebar')
        sidebar = QVBoxLayout(self.sidebar)
        sidebar.setContentsMargins(10, 10, 10, 10)
        sidebar.setSpacing(7)
        self.sidebar_header = header = QHBoxLayout()
        self.brand = button('ZFilter', self.toggle_theme, '点击切换深色或浅色')
        self.brand.setObjectName('brand')
        self.brand.setIcon(QIcon(str(ICON)))
        self.brand.setIconSize(QSize(28,28))
        self.collapse_button = button('',self.toggle_sidebar,'折叠或展开侧栏',compact=True,glyph='sidebar-collapse')
        header.addWidget(self.brand, 1)
        header.addWidget(self.collapse_button)
        sidebar.addLayout(header)
        self.nav = []
        for index, (title,glyph) in enumerate(zip(('素材整理','沉浸选片','操作记录'),('organize','photos','history'))):
            tab = button(title,partial(self.show_page,index),checkable=True,glyph=glyph)
            tab.setObjectName('nav')
            sidebar.addWidget(tab)
            self.nav.append(tab)
        sidebar.addSpacing(15)
        self.projects_label = label('影像项目', 'muted')
        sidebar.addWidget(self.projects_label)
        self.project_tools = project_tools = QHBoxLayout()
        for name, action, tip in [('add',self.choose,'添加影像项目'),('refresh',self.refresh_all,'刷新项目统计'),
                                  ('sort',self.sort_menu,'项目排序')]:
            project_tools.addWidget(button('',action,tip,compact=True,glyph=name))
        sidebar.addLayout(project_tools)
        self.project_list = QListWidget()
        self.project_list.setObjectName('projects')
        self.project_list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.project_list.customContextMenuRequested.connect(self.project_menu)
        self.project_list.itemClicked.connect(lambda item: self.open_project(item.data(Qt.ItemDataRole.UserRole)))
        sidebar.addWidget(self.project_list, 1)
        outer.addWidget(self.sidebar)

        self.pages = QStackedWidget()
        outer.addWidget(self.pages, 1)
        self.pages.addWidget(self.make_organizer())
        self.pages.addWidget(self.make_viewer())
        self.pages.addWidget(self.make_records())
        shortcuts = {'Left':partial(self.step,-1), 'A':partial(self.step,-1), 'Right':partial(self.step,1), 'D':partial(self.step,1),
                     'W':partial(self.cull,True), 'S':partial(self.cull,False), 'Delete':partial(self.cull,False),
                     'Ctrl+Z':self.restore_delete,'Ctrl+O':self.choose,'Ctrl+R':self.rescan,
                     '0':self.photo_view.focus_zoom,'O':self.photo_view.focus_zoom,',':self.photo_view.fit_window,
                     'F':self.focus_toggle.click,'I':self.info_toggle.click,'T':self.strip_toggle.click,
                     'B':self.toggle_bursts,'Tab':self.toggle_immersive,'F11':self.toggle_fullscreen,'Esc':self.exit_immersive}
        for key, action in shortcuts.items():
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.activated.connect(action)
        self.update_sidebar()

    def make_organizer(self):
        self.organizer = QScrollArea()
        self.organizer.setWidgetResizable(True)
        self.organizer.setFrameShape(QFrame.Shape.NoFrame)
        content = QWidget()
        content.setObjectName('paper')
        layout = QVBoxLayout(content)
        layout.setContentsMargins(26, 24, 26, 24)
        layout.setSpacing(13)
        top = QHBoxLayout()
        self.project_title = label('添加影像项目', 'title')
        top.addWidget(self.project_title, 1)
        top.addWidget(button('打开文件夹', self.choose))
        layout.addLayout(top)
        self.project_path = label('', 'muted', True)
        self.project_path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(self.project_path)
        self.project_summary = label('选择文件夹，读取 JPEG、RAW 与视频。', 'summary', True)
        layout.addWidget(self.project_summary)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(5)
        self.progress.hide()
        layout.addWidget(self.progress)
        self.organizer_body = QWidget()
        body = QVBoxLayout(self.organizer_body)
        body.setContentsMargins(0,4,0,0)
        body.setSpacing(14)
        stats = QHBoxLayout()
        self.stats = []
        for title, hue in [('JPEG','#1dcd3a'),('RAW','#842bc1'),('视频 / RAW 视频','#ff6d0a'),('已验证配对','#50b996')]:
            card = QFrame()
            card.setObjectName('card')
            v = QVBoxLayout(card)
            v.setContentsMargins(14,12,14,12)
            stripe = QFrame()
            stripe.setFixedSize(23,3)
            stripe.setStyleSheet(f'background: {hue}; border-radius: 1px')
            count = label('0','metric')
            size = label('','muted')
            v.addWidget(stripe)
            v.addWidget(label(title,'muted'))
            v.addWidget(count)
            v.addWidget(size)
            stats.addWidget(card,1)
            self.stats.append((count,size))
        body.addLayout(stats)
        self.formats = label('', 'muted', True)
        body.addWidget(self.formats)
        card = QFrame()
        card.setObjectName('card')
        controls = QVBoxLayout(card)
        controls.setContentsMargins(16,14,16,14)
        controls.setSpacing(9)
        controls.addWidget(label('整理方式','section'))
        modes = QHBoxLayout()
        self.mode_buttons = QButtonGroup(self)
        for index, title in enumerate(('普通模式','RED 模式','自定义规则','影子模式')):
            toggle = button(title,self.change_rules,checkable=True)
            self.mode_buttons.addButton(toggle,index)
            modes.addWidget(toggle)
        self.mode_buttons.button(0).setChecked(True)
        controls.addLayout(modes)
        self.custom_rules = QWidget()
        custom = QHBoxLayout(self.custom_rules)
        custom.setContentsMargins(0,5,0,0)
        self.rule_checks = []
        for i, name in enumerate(RULES,1):
            check = QCheckBox(name)
            check.setChecked(i < 5)
            check.toggled.connect(self.change_rules)
            custom.addWidget(check)
            self.rule_checks.append(check)
        controls.addWidget(self.custom_rules)
        self.custom_rules.hide()
        self.travel = QCheckBox('旅行模式 · 按 EXIF 拍摄日期分组')
        self.dry = QCheckBox('演练模式 · 预演结果')
        self.travel.toggled.connect(self.change_rules)
        self.dry.toggled.connect(self.update_organizer)
        controls.addWidget(self.travel)
        controls.addWidget(self.dry)
        body.addWidget(card)
        self.preview = label('', 'summary', True)
        body.addWidget(self.preview)
        actions = QHBoxLayout()
        self.preview_button = button('预检查', self.preview_project)
        self.run_button = button('开始整理', self.confirm_organize)
        self.run_button.setObjectName('primary')
        actions.addWidget(self.preview_button)
        actions.addWidget(self.run_button)
        actions.addWidget(button('开始选片', partial(self.show_page,1)))
        actions.addStretch()
        body.addLayout(actions)
        layout.addWidget(self.organizer_body)
        layout.addStretch()
        self.organizer.setWidget(content)
        return self.organizer

    def make_viewer(self):
        page = QWidget()
        page.setObjectName('paper')
        layout = QVBoxLayout(page)
        layout.setContentsMargins(12,12,12,12)
        layout.setSpacing(10)
        self.viewer_header = QWidget()
        self.viewer_header_layout = QBoxLayout(QBoxLayout.Direction.TopToBottom,self.viewer_header)
        self.viewer_header_layout.setContentsMargins(0,0,0,0)
        self.viewer_header_layout.setSpacing(7)
        self.viewer_scope_tools = QWidget()
        tools = QHBoxLayout(self.viewer_scope_tools)
        tools.setContentsMargins(0,0,0,0)
        tools.setSpacing(6)
        self.photo_title = label('沉浸选片','section')
        self.photo_subtitle = label('', 'muted')
        details = QWidget()
        details.setMinimumWidth(97)
        title = QVBoxLayout(details)
        title.setContentsMargins(0,0,0,0)
        title.setSpacing(2)
        for text in (self.photo_title,self.photo_subtitle):
            text.setSizePolicy(QSizePolicy.Policy.Ignored,QSizePolicy.Policy.Preferred)
        title.addWidget(self.photo_title)
        title.addWidget(self.photo_subtitle)
        tools.addWidget(details,1)
        self.folders_button = button('全部文件夹',self.choose_photo_folder,glyph='folder')
        self.folders_button.setObjectName('folderScope')
        self.folders_button.setMinimumWidth(154)
        self.folders_button.setMaximumWidth(204)
        self.folders_button.setFixedHeight(34)
        tools.addWidget(self.folders_button)
        self.pool_buttons = []
        for index, title in enumerate(('正式池','待删池')):
            toggle = button(title, partial(self.switch_pool,bool(index)), checkable=True)
            toggle.setFixedSize(106,34)
            self.pool_buttons.append(toggle)
            tools.addWidget(toggle)
        self.zoom_button = button('',self.focus_zoom,'100% 对焦点 · 0 / O',compact=True,glyph='zoom-in')
        self.fit_button = button('',self.photo_view_fit,'适应窗口 · ,',compact=True,glyph='zoom-out')
        self.focus_toggle = button('',self.toggle_focus_box,'绿色对焦框 · F',checkable=True,compact=True,glyph='focus')
        self.strip_toggle = button('',self.toggle_filmstrip,'预览条 · T',checkable=True,compact=True,glyph='filmstrip')
        self.burst_toggle = button('',self.toggle_bursts,'折叠或展开全部连拍 · B',checkable=True,compact=True,glyph='burst')
        self.info_toggle = button('',self.toggle_inspector,'照片信息 · I',checkable=True,compact=True,glyph='info')
        self.fullscreen_button = button('',self.toggle_fullscreen,'全屏 · F11',compact=True,glyph='maximize')
        self.focus_toggle.setChecked(self.settings.value('focusBox',False,bool))
        self.strip_toggle.setChecked(self.settings.value('filmstrip',True,bool))
        self.viewer_action_tools = QWidget()
        action_row = QHBoxLayout(self.viewer_action_tools)
        action_row.setContentsMargins(0,0,0,0)
        action_row.setSpacing(5)
        for widget in (self.zoom_button,self.fit_button,self.focus_toggle,self.strip_toggle,self.burst_toggle,self.info_toggle,
                       self.fullscreen_button,button('',self.rescan,'刷新配对 · Ctrl+R',compact=True,glyph='refresh')):
            action_row.addWidget(widget)
        self.viewer_header_layout.addWidget(self.viewer_scope_tools,1)
        self.viewer_header_layout.addWidget(self.viewer_action_tools,0,Qt.AlignmentFlag.AlignRight)
        self.viewer_header.installEventFilter(self)
        layout.addWidget(self.viewer_header)
        middle = QHBoxLayout()
        image_column = QVBoxLayout()
        image_column.setSpacing(9)
        self.canvas = QStackedWidget()
        self.canvas.setObjectName('canvas')
        self.photo_view = PhotoView()
        self.photo_view.show_box = self.focus_toggle.isChecked()
        self.photo_view.viewport_changed.connect(self.show_zoom)
        self.photo_view.tracking_changed.connect(self.zoom_button.setChecked)
        self.zoom_button.setCheckable(True)
        self.canvas.addWidget(self.photo_view)
        empty = QWidget()
        empty_layout = QVBoxLayout(empty)
        empty_layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder = label('打开影像项目','section', True)
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.spinner = QProgressBar()
        self.spinner.setRange(0,0)
        self.spinner.setTextVisible(False)
        self.spinner.setFixedSize(140,5)
        empty_layout.addWidget(self.placeholder,0,Qt.AlignmentFlag.AlignCenter)
        empty_layout.addWidget(self.spinner,0,Qt.AlignmentFlag.AlignCenter)
        self.canvas.addWidget(empty)
        image_column.addWidget(self.canvas,1)
        self.filmstrip = Material()
        strip = QVBoxLayout(self.filmstrip)
        strip.setContentsMargins(12,6,12,7)
        strip.setSpacing(3)
        tiles = QHBoxLayout()
        tiles.setSpacing(4)
        self.tiles = []
        for _ in range(7):
            tile = Tile()
            tile.selected.connect(lambda t=tile: self.select(t.index))
            tile.dragged.connect(self.step)
            tile.burst_toggled.connect(lambda t=tile: self.toggle_group(t.index))
            tiles.addWidget(tile,1)
            self.tiles.append(tile)
        strip.addLayout(tiles)
        self.scrubber = Scrubber(Qt.Orientation.Horizontal)
        self.scrubber.setAccessibleName('快速定位')
        self.scrubber.seek.connect(self.select)
        self.scrubber.valueChanged.connect(self.scrub_label)
        strip.addWidget(self.scrubber)
        self.strip_position = label('','muted')
        strip.addWidget(self.strip_position)
        image_column.addWidget(self.filmstrip)
        middle.addLayout(image_column,1)
        self.inspector = Material()
        self.inspector.setFixedWidth(273)
        panel = QVBoxLayout(self.inspector)
        panel.setContentsMargins(12,10,12,10)
        panel.addWidget(label('照片信息','section'))
        inspector_scroll = QScrollArea()
        inspector_scroll.setFrameShape(QFrame.Shape.NoFrame)
        inspector_scroll.setWidgetResizable(True)
        details = QWidget()
        detail = QVBoxLayout(details)
        detail.setContentsMargins(0,2,3,0)
        chart = QHBoxLayout()
        chart.addWidget(label('RGB / 亮度直方图','muted'),1)
        self.chart_mode = button('对数',self.change_histogram,compact=True)
        chart.addWidget(self.chart_mode)
        detail.addLayout(chart)
        self.histogram = Histogram()
        self.histogram.log = self.settings.value('histogramLog',True,bool)
        self.chart_mode.setText('对数' if self.histogram.log else '线性')
        detail.addWidget(self.histogram)
        self.histogram_caption = label('','muted',True)
        detail.addWidget(self.histogram_caption)
        self.exif = QFormLayout()
        self.exif.setContentsMargins(0,6,0,0)
        detail.addWidget(label('拍摄信息','section'))
        detail.addLayout(self.exif)
        detail.addWidget(label('文件与配对','section'))
        self.file_details = QFormLayout()
        detail.addLayout(self.file_details)
        self.reveal_button = button('在文件管理器中显示', self.reveal_photo)
        detail.addWidget(self.reveal_button)
        detail.addStretch()
        inspector_scroll.setWidget(details)
        panel.addWidget(inspector_scroll)
        self.inspector.hide()
        middle.addWidget(self.inspector)
        layout.addLayout(middle,1)
        footer = QHBoxLayout()
        self.scope_buttons = []
        for index, name in enumerate(ops.SCOPES):
            toggle = button(name,partial(self.set_scope,index),checkable=True)
            footer.addWidget(toggle)
            self.scope_buttons.append(toggle)
        footer.addStretch()
        self.pool_delete_button = button('删除整个待删池',self.confirm_remove_pool,glyph='delete')
        self.pool_delete_button.setObjectName('bulkTrash')
        self.pool_delete_button.hide()
        footer.addWidget(self.pool_delete_button)
        self.step_label = label('0 / 0','muted')
        footer.addWidget(button('',partial(self.step,-1),'上一张 · A / ←',compact=True,glyph='previous'))
        footer.addWidget(self.step_label)
        footer.addWidget(button('',partial(self.step,1),'下一张 · D / →',compact=True,glyph='next'))
        self.w_button = button('',partial(self.cull,True),'移入待删池 · W',compact=True,glyph='stage')
        self.s_button = button('',partial(self.cull,False),'移入 Windows 系统回收站 · S / Delete',compact=True,glyph='delete')
        footer.addWidget(self.w_button)
        footer.addWidget(self.s_button)
        footer.addWidget(button('',self.restore_delete,'撤回删除 · Ctrl+Z',compact=True,glyph='undo'))
        layout.addLayout(footer)
        self.departure = Departure(page)
        return page

    def make_records(self):
        page = QWidget()
        page.setObjectName('paper')
        layout = QVBoxLayout(page)
        layout.setContentsMargins(23,22,23,22)
        layout.addWidget(label('操作记录','title'))
        self.records_summary = label('','muted')
        layout.addWidget(self.records_summary)
        actions = QHBoxLayout()
        for title, action in [('刷新',self.rescan),('撤销上次整理',self.confirm_undo),('撤回最近删除',self.restore_delete),
                              ('恢复全部待删文件',self.restore_all_pool)]:
            actions.addWidget(button(title,action))
        actions.addStretch()
        layout.addLayout(actions)
        self.record_list = QListWidget()
        self.record_list.itemDoubleClicked.connect(lambda item: QDesktopServices.openUrl(QUrl.fromLocalFile(item.data(Qt.ItemDataRole.UserRole))))
        layout.addWidget(self.record_list)
        return page

    @property
    def scope_name(self):
        return ops.SCOPES[self.scope]

    @property
    def photo(self):
        return self.photos[self.index] if 0 <= self.index < len(self.photos) else None

    @property
    def path(self):
        return ops.display_path(self.photo,self.scope_name) if self.photo else None

    @property
    def options(self):
        mode = MODES[self.mode_buttons.checkedId()]
        return 'normal' if mode == 'shadow' else mode, [str(i) for i,c in enumerate(self.rule_checks,1) if c.isChecked()], self.travel.isChecked()

    def show_page(self, page):
        self.pages.setCurrentIndex(page)
        for i, tab in enumerate(self.nav):
            tab.setChecked(page == i)
        if page == 0:
            self.update_organizer()
        elif page == 1:
            self.update_viewer()
            self.scan_bursts()
        else:
            self.update_records()

    def update_sidebar(self):
        self.sidebar.setVisible(not self.immersive)
        self.sidebar.setFixedWidth(70 if self.collapsed else 220)
        direction = QBoxLayout.Direction.TopToBottom if self.collapsed else QBoxLayout.Direction.LeftToRight
        self.sidebar_header.setDirection(direction)
        self.project_tools.setDirection(direction)
        self.brand.setText('' if self.collapsed else 'ZFilter')
        self.set_glyph(self.collapse_button,'sidebar-expand' if self.collapsed else 'sidebar-collapse')
        self.brand.setStyleSheet('text-align:center;' if self.collapsed else '')
        self.projects_label.setVisible(not self.collapsed)
        for i, title in enumerate(('素材整理','沉浸选片','操作记录')):
            self.nav[i].setText('' if self.collapsed else title)
            self.nav[i].setStyleSheet('text-align:center;padding:0;' if self.collapsed else '')
            self.nav[i].setAccessibleName(title)
            self.nav[i].setToolTip(title)
        self.refresh_projects()

    def toggle_sidebar(self):
        self.collapsed = not self.collapsed
        self.settings.setValue('sidebarCollapsed',self.collapsed)
        self.update_sidebar()

    def toggle_immersive(self):
        self.immersive = not self.immersive
        self.update_sidebar()

    def exit_immersive(self):
        if self.isFullScreen():
            self.showNormal()
        elif self.immersive:
            self.toggle_immersive()

    def toggle_fullscreen(self):
        self.showNormal() if self.isFullScreen() else self.showFullScreen()

    def changeEvent(self,event):
        super().changeEvent(event)
        if event.type() == QEvent.Type.WindowStateChange and hasattr(self,'fullscreen_button'):
            self.set_glyph(self.fullscreen_button,'restore-window' if self.isFullScreen() else 'maximize')

    def set_glyph(self, widget, name):
        widget.setProperty('glyph',name)
        if hasattr(self,'dark'):
            widget.setIcon(fluent_icon(name,self.dark))

    def toggle_theme(self):
        self.theme = 'light' if self.dark else 'dark'
        self.settings.setValue('theme',self.theme)
        self.apply_theme()

    def apply_theme(self, *_):
        system = QApplication.instance().styleHints().colorScheme() == Qt.ColorScheme.Dark
        self.dark = self.theme == 'dark' or (self.theme == 'system' and system)
        a,b,c,d,e,f,g = (('#10151e','#181f2a','#222c3a','#354154','#edf2fa','#a7b7cc','#6ca9ff') if self.dark
                          else ('#edf2f8','#f9fbfe','#e9eff7','#cbd5e4','#192638','#53637c','#1859ad'))
        active_tool = '#344054' if self.dark else '#dce6f3'
        destructive = '#ff9b96' if self.dark else '#af2720'
        palette = self.palette()
        palette.setColor(QPalette.ColorRole.Text,QColor(e))
        palette.setColor(QPalette.ColorRole.WindowText,QColor(e))
        self.setPalette(palette)
        self.setStyleSheet(f'''
            QWidget {{color:{e};font-size:13px;}}
            QWidget#surface {{background:{a};}}
            QWidget#paper,QWidget#sidebar {{background:{b};border:1px solid {d};border-radius:13px;}}
            QFrame#card {{background:{c};border:1px solid {d};border-radius:12px;}}
            QLabel#title {{font-size:27px;font-weight:700;}}
            QLabel#section {{font-size:15px;font-weight:600;}}
            QLabel#metric {{font-size:28px;font-weight:600;}}
            QLabel#muted {{color:{f};font-size:11px;}}
            QLabel#summary {{color:{f};padding:5px 1px;}}
            QPushButton,QToolButton {{background:{c};border:1px solid {d};border-radius:7px;padding:6px 10px;}}
            QPushButton:hover,QToolButton:hover {{border-color:{g};}}
            QPushButton:checked,QToolButton:checked {{border-color:{g};color:{g};}}
            QPushButton:disabled,QToolButton:disabled {{color:{f};}}
            QPushButton#folderScope {{font-weight:500;text-align:left;}}
            QPushButton#folderScope:hover:enabled {{border-color:{f};background:{active_tool};}}
            QPushButton#bulkTrash:enabled {{color:{destructive};}}
            QPushButton#bulkTrash:hover:enabled {{border-color:{destructive};}}
            QPushButton#brand {{background:transparent;border-color:transparent;text-align:left;font-size:20px;font-weight:700;padding:4px;}}
            QPushButton#brand:hover {{background:{c};}}
            QPushButton#nav {{text-align:left;min-height:20px;background:transparent;border-color:transparent;}}
            QPushButton#nav:checked {{background:{c};color:{g};}}
            QPushButton#primary {{background:{g};color:{a};font-weight:700;}}
            QToolButton#tool {{padding:0;background:transparent;border:1px solid transparent;border-radius:8px;}}
            QToolButton#tool:hover {{background:{c};border-color:{d};}}
            QToolButton#tool:checked {{background:{active_tool};border-color:{d};}}
            QToolButton#tool:pressed {{background:{active_tool};}}
            QToolButton#tool:focus {{border-color:{g};}}
            QToolButton#badge {{font-size:10px;padding:1px 4px;background:{b};}}
            QDialog#folderPicker {{background:{b};}}
            QTreeWidget#folderTree {{background:transparent;border:0;outline:0;}}
            QTreeWidget#folderTree::item {{height:28px;border-radius:5px;}}
            QTreeWidget#folderTree::item:hover {{background:{c};}}
            QTreeWidget#folderTree::item:selected {{background:{active_tool};color:{e};}}
            QScrollArea,QScrollArea>QWidget>QWidget {{background:transparent;}}
            QListWidget {{background:transparent;border:0;outline:0;}}
            QListWidget::item {{min-height:43px;border-radius:7px;padding:3px;}}
            QListWidget::item:hover {{background:{c};}}
            QListWidget::item:selected {{background:transparent;color:{e};}}
            QSlider::groove:horizontal {{height:4px;background:{d};border-radius:2px;}}
            QSlider::handle:horizontal {{width:14px;background:{g};margin:-5px 0;border-radius:7px;}}
            QScrollBar:vertical {{background:transparent;width:9px;margin:2px 0;}}
            QScrollBar::handle:vertical {{background:{d};border-radius:4px;min-height:26px;}}
            QScrollBar::handle:vertical:hover {{background:{f};}}
            QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical {{height:0;}}
            QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical {{background:none;}}
            QProgressBar {{background:{c};border:0;border-radius:2px;}}
            QProgressBar::chunk {{background:{g};border-radius:2px;}}
            QMenu {{background:{b};color:{e};border:1px solid {d};}}
            QMenu::item:selected {{background:{c};}}
        ''')
        canvas = '#101319' if self.dark else '#e6eaf0'
        self.canvas.setStyleSheet(f'QStackedWidget#canvas {{background:{canvas};border-radius:9px;}}')
        self.photo_view.setBackgroundBrush(QBrush(QColor(canvas)))
        for panel in (self.filmstrip,self.inspector,self.histogram):
            panel.dark = self.dark
            panel.update()
        for widget in self.findChildren(QAbstractButton):
            if glyph := widget.property('glyph'):
                widget.setIcon(fluent_icon(glyph,self.dark))
        self.apply_chrome()
        self.refresh_projects()
        self.update_viewer(load=False)

    def apply_chrome(self):
        if sys.platform == 'win32':
            import ctypes
            from ctypes import wintypes
            color = ctypes.c_int(int(self.dark))
            ctypes.windll.dwmapi.DwmSetWindowAttribute(wintypes.HWND(int(self.winId())),20,ctypes.byref(color),ctypes.sizeof(color))

    def show_zoom(self, text):
        self.viewport_label = text
        self.show_photo_title()

    def focus_zoom(self):
        self.photo_view.focus_zoom()

    def photo_view_fit(self):
        self.photo_view.fit_window()

    def toggle_focus_box(self):
        self.photo_view.show_box = self.focus_toggle.isChecked()
        self.settings.setValue('focusBox',self.photo_view.show_box)
        self.photo_view.update_box()

    def toggle_filmstrip(self):
        self.settings.setValue('filmstrip',self.strip_toggle.isChecked())
        self.render_filmstrip()

    def toggle_inspector(self):
        self.inspector.setVisible(self.info_toggle.isChecked() and bool(self.photo))
        self.update_inspector()

    def change_histogram(self):
        self.histogram.log = not self.histogram.log
        self.settings.setValue('histogramLog',self.histogram.log)
        self.chart_mode.setText('对数' if self.histogram.log else '线性')
        self.histogram.update()

    def save_projects(self):
        self.settings.setValue('projects',json.dumps(self.projects,ensure_ascii=False))

    def remember(self, library):
        path = library['root']
        project = next((p for p in self.projects if p['path'] == path),None)
        if project is None:
            project = {'path':path}
            self.projects.append(project)
        project.update(size=library['sizes']['project'], count=library['mediaCount'])
        self.presence[path] = True
        self.save_projects()
        self.refresh_projects()

    def refresh_projects(self):
        if not hasattr(self,'project_list'):
            return
        order = self.settings.value('projectSort','added',str)
        descending = self.settings.value('projectDescending',False,bool)
        pinned = [p for p in self.projects if p.get('pinned')]
        pinned.sort(key=lambda p:p['pinned'],reverse=True)
        ordinary = [p for p in self.projects if not p.get('pinned')]
        if order == 'added':
            if descending:
                ordinary.reverse()
        else:
            key = {'name':lambda p: (Path(p['path']).name or p['path']).casefold(),
                   'date':lambda p: p.get('date',''),
                   'size':lambda p: p.get('size',-1)}.get(order)
            if key:
                ordinary.sort(key=key,reverse=descending)
        self.project_list.clear()
        for project in pinned+ordinary:
            path = project['path']
            title = Path(path).name or path
            active = self.root is not None and path == str(self.root)
            item = QListWidgetItem(('⤒  ' if project.get('pinned') else '') + title if not self.collapsed else '')
            item.setData(Qt.ItemDataRole.UserRole,path)
            item.setIcon(folder_icon(self.presence.get(path,False),active))
            online = '在线' if self.presence.get(path) else '离线'
            item.setToolTip(f'{title} · {online} · {project.get("count",0)} 个素材 · {byte_text(project.get("size"))}\n{path}')
            if project.get('pinned'):
                gradient = QLinearGradient(0,0,185,35)
                gradient.setColorAt(0,QColor(52,130,255,80))
                gradient.setColorAt(1,QColor(107,230,179,35))
                item.setBackground(QBrush(gradient))
            self.project_list.addItem(item)
            if active:
                self.project_list.setCurrentItem(item)

    def check_presence(self):
        if self.presence_busy or not self.projects:
            return
        paths = [p['path'] for p in self.projects]
        self.presence_busy = True

        def checked(result,error):
            self.presence_busy = False
            if not error and any(self.presence.get(path) != state for path,state in result.items()):
                self.presence.update(result)
                self.refresh_projects()
                self.update_viewer(load=False)

        self.tasks.submit('presence',lambda: {p:Path(p).is_dir() for p in paths},checked)

    def sort_menu(self):
        menu = QMenu(self)
        for title,key in [('添加顺序','added'),('项目日期与时间','date'),('项目大小','size'),('项目名称','name')]:
            action = menu.addAction(title)
            action.setCheckable(True)
            action.setChecked(self.settings.value('projectSort','added',str) == key)
            action.triggered.connect(partial(self.set_sort,key))
        menu.addSeparator()
        for title,descending in [('正序',False),('倒序',True)]:
            action = menu.addAction(title)
            action.setCheckable(True)
            action.setChecked(self.settings.value('projectDescending',False,bool) == descending)
            action.triggered.connect(partial(self.set_sort_direction,descending))
        menu.exec(self.cursor().pos())

    def set_sort(self, key, *_):
        self.settings.setValue('projectSort',key)
        self.refresh_projects()

    def set_sort_direction(self,value,*_):
        self.settings.setValue('projectDescending',value)
        self.refresh_projects()

    def project_menu(self, point):
        item = self.project_list.itemAt(point)
        if not item:
            return
        path = item.data(Qt.ItemDataRole.UserRole)
        project = next(p for p in self.projects if p['path'] == path)
        menu = QMenu(self)
        actions = [
            ('取消置顶' if project.get('pinned') else '置顶项目', partial(self.pin,project)),
            ('设置项目日期与时间…',partial(self.set_project_date,project)),
            ('清除项目日期',partial(self.clear_project_date,project)),
            ('刷新项目',partial(self.refresh_all,path)),
            ('在文件管理器中显示',lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(path))),
            ('删除项目（保留素材）',partial(self.remove_project,project)),
        ]
        for title, action in actions:
            menu.addAction(title,action)
        menu.exec(self.project_list.mapToGlobal(point))

    def pin(self, project):
        project['pinned'] = None if project.get('pinned') else core.now_iso()
        self.save_projects()
        self.refresh_projects()

    def set_project_date(self, project):
        dialog = QDialog(self)
        dialog.setWindowTitle('项目日期与时间')
        v = QVBoxLayout(dialog)
        field = QDateTimeEdit(QDateTime.currentDateTime())
        field.setCalendarPopup(True)
        field.setDisplayFormat('yyyy-MM-dd HH:mm')
        if project.get('date'):
            field.setDateTime(QDateTime.fromString(project['date'],Qt.DateFormat.ISODate))
        v.addWidget(field)
        actions = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        actions.accepted.connect(dialog.accept)
        actions.rejected.connect(dialog.reject)
        v.addWidget(actions)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            project['date'] = field.dateTime().toString(Qt.DateFormat.ISODate)
            self.save_projects()
            self.refresh_projects()

    def clear_project_date(self, project):
        project.pop('date',None)
        self.save_projects()
        self.refresh_projects()

    def remove_project(self, project):
        if self.busy:
            return
        self.projects.remove(project)
        self.save_projects()
        if str(self.root) == project['path']:
            self.burst_generation += 1
            self.root, self.library = None,None
            self.rebuild_album()
            self.show_page(self.pages.currentIndex())
        self.refresh_projects()

    def choose(self):
        if not self.busy:
            path = QFileDialog.getExistingDirectory(self,'选择影像项目',str(self.root or Path.home()))
            if path:
                self.open_project(path)

    def open_project(self,path):
        if self.busy:
            return
        self.root = Path(path)
        self.library = None
        self.load_error = False
        self.pool = False
        self.index = 0
        self.pool_selection.clear()
        self.selected_folders.clear()
        if self.mode_buttons.checkedId() == 3:
            self.mode_buttons.button(0).setChecked(True)
        self.burst_generation += 1
        self.burst_ids = {}
        self.bursts_scanned = self.bursts_scanning = self.fold_all = False
        self.burst_overrides.clear()
        self.representatives.clear()
        self.photo_view.fit_window()
        self.rebuild_album()
        self.rescan()

    def begin_io(self, description, work, done):
        if self.busy:
            return
        self.preview_timer.stop()
        self.busy = True
        self.project_summary.setText(description)
        self.progress.setRange(0,0)
        self.progress.show()
        self.update_organizer()
        self.update_viewer(load=False)

        def complete(result,error):
            self.busy = False
            self.progress.hide()
            done(result,error)
            self.update_organizer()
            self.update_viewer(load=False)

        self.tasks.submit('io',work,complete)

    def report(self, message):
        self.statusBar().showMessage(str(message),9000)

    def progress_update(self, filename, value):
        self.progress.setRange(0,100)
        self.progress.setValue(round(value*100))
        self.statusBar().showMessage('正在整理 · '+filename)

    def rescan(self):
        if not self.root or self.busy:
            return
        root = self.root
        mode,rules,travel = self.options
        self.load_error = False
        self.frame_cache.clear()
        self.thumb_cache.clear()
        self.loading_path = None
        self.begin_io('正在读取影像项目…',lambda: ops.scan(core.safe_resolve_dir(str(root)),mode,rules,travel),self.scan_complete)

    def scan_complete(self, result, error):
        if error:
            self.load_error = self.library is None
            self.report(error)
        else:
            self.apply_library(result)

    def apply_library(self, library, preferred=None):
        preferred = preferred or self.photo
        if self.library is None and library['shadowPool']:
            self.mode_buttons.button(3).setChecked(True)
        self.library = library
        for pool, key in [(False,'activeFolders'),(True,'poolFolders')]:
            if str(self.selected_folders.get(pool)) not in library[key]:
                self.selected_folders.pop(pool,None)
        self.root = Path(library['root'])
        self.load_error = False
        self.remember(library)
        self.rebuild_album(preferred)
        self.update_records()
        if self.pages.currentIndex() == 1:
            self.scan_bursts()

    def refresh_all(self, path=None):
        if self.busy:
            return
        targets = [p['path'] for p in self.projects if path is None or p['path'] == path]
        mode,rules,travel = self.options

        def work():
            results, failures = [], []
            for target in targets:
                try:
                    results.append(ops.scan(core.safe_resolve_dir(target),mode,rules,travel))
                except (OSError,ValueError) as error:
                    failures.append(str(error))
            return results,failures

        def finished(result,error):
            if error:
                self.report(error)
                return
            for library in result[0]:
                self.apply_library(library) if library['root'] == str(self.root) else self.remember(library)
            if result[1]:
                self.report('；'.join(result[1]))
            self.check_presence()

        if targets:
            self.begin_io('正在刷新项目统计…',work,finished)

    def change_rules(self,*_):
        self.update_organizer()
        if self.root and self.library and not self.busy:
            if self.mode_buttons.checkedId() == 3:
                self.preview_timer.stop()
                return
            self.run_button.setEnabled(False)
            self.preview_timer.start()

    def preview_project(self):
        if self.root is None or self.library is None or self.busy:
            return
        root = self.root
        mode,rules,travel = self.options

        def update(preview,error):
            if error:
                self.report(error)
            else:
                self.library['preview'] = preview

        self.begin_io('正在预检查…',lambda:core.preview_scan(root,core.resolve_effective_rules(mode,set(rules)),travel),update)

    def confirm_organize(self):
        if self.mode_buttons.checkedId() == 3:
            self.organize()
            return
        action = '演练' if self.dry.isChecked() else '整理'
        if self.root and QMessageBox.question(self,'开始'+action,f'对所选项目执行{action}？\n{self.root}') == QMessageBox.StandardButton.Yes:
            self.organize()

    def confirm_undo(self):
        if self.root and self.library and self.library['history']:
            if QMessageBox.question(self,'撤销整理','将文件恢复到上次整理前的位置？') == QMessageBox.StandardButton.Yes:
                self.organize(undo=True)

    def organize(self,undo=False):
        if self.root is None:
            return
        root = self.root
        mode,rules,travel = self.options
        dry = self.dry.isChecked()
        if self.mode_buttons.checkedId() == 3 and not undo:
            def prepare():
                ops.create_shadow(root)
                return ops.scan(root,mode,rules,travel)
            def ready(library,error):
                if error:
                    self.report(error)
                    return
                self.apply_library(library)
                self.switch_pool(False)
                self.show_page(1)
                self.report('影子目录已就绪')
            self.begin_io('正在同步影子目录…',prepare,ready)
            return

        def work():
            progress = lambda done,total,name:self.tasks.progress.emit(name,done/max(1,total))
            stats = ops.undo(root) if undo else ops.organize(root,mode,rules,travel,dry,progress)
            return ops.scan(root,mode,rules,travel),stats

        def finished(result,error):
            if error:
                self.report(error)
            else:
                self.apply_library(result[0])
                count = result[1].get('reverted' if undo else 'moved',0)
                verb = '已撤销' if undo else '演练完成 · 预计处理' if dry else '已处理'
                self.report(f'{verb} {count} 个文件')
                failures = result[1].get('errors',0)
                if failures:
                    self.report(f'{failures} 个文件操作失败，请检查目录权限及同名文件。')

        self.begin_io('正在处理素材…',work,finished)

    def update_organizer(self):
        self.project_title.setText((self.root.name or str(self.root)) if self.root else '添加影像项目')
        self.project_path.setText(str(self.root) if self.root else '')
        self.organizer_body.setVisible(bool(self.library))
        if self.library is None:
            self.project_summary.setText('正在读取影像项目…' if self.busy else '读取失败，可按 Ctrl+R 重试。' if self.load_error
                                         else '选择文件夹，读取 JPEG、RAW 与视频。')
            return
        lib = self.library
        if not self.busy:
            state = f'{lib["pending"]} 个文件待整理' if lib['pending'] else '当前无新增待整理素材'
            self.project_summary.setText(f'{state}   ·   项目 {byte_text(lib["sizes"]["project"])}   ·   待删池 {byte_text(lib["sizes"]["pool"])}')
        counts,sizes = lib['counts'], lib['sizes']
        for (name,amount),(number,unit) in zip([('jpg',counts['jpg']),('raw',counts['raw']),
                ('video',counts['video']+counts['rawvideo']),('paired',lib['paired'])],self.stats):
            number.setText(str(amount))
            unit.setText('经过验证' if name == 'paired' else byte_text(sizes.get(name,0)+(sizes['rawvideo'] if name=='video' else 0)))
        self.formats.setText('    '.join(f'{ext} {count}' for ext,count in sorted(lib['formats'].items())))
        pre = lib['preview']
        planned = sum(value for key,value in pre.items() if key.startswith('will_rule'))
        options = f'    ·    日期分组 {pre["travel_date_folders"]}' if self.travel.isChecked() else ''
        self.preview.setText(f'整理预览   待检查 {pre["total_scanned"]} · 预计处理 {planned} · 不支持 {pre["unsupported"]}{options}')
        self.run_button.setText('开始演练' if self.dry.isChecked() else '开始整理')
        self.run_button.setEnabled(not self.busy and planned>0)
        self.preview_button.setEnabled(not self.busy)
        shadow = self.mode_buttons.checkedId() == 3
        self.custom_rules.setVisible(self.mode_buttons.checkedId() == 2)
        self.travel.setVisible(not shadow)
        self.dry.setVisible(not shadow)
        self.preview_button.setVisible(not shadow)
        if shadow:
            pool = lib['shadowPool']
            self.preview.setText('在素材目录旁复制空目录结构。按 W 将照片移入对应的影子目录。'
                                 + ('\n'+pool['path'] if pool else ''))
            self.run_button.setText('同步影子目录并选片' if pool else '创建影子待删池并选片')
            self.run_button.setEnabled(not self.busy)
        for widget in [self.travel,self.dry,self.custom_rules,*self.mode_buttons.buttons()]:
            widget.setEnabled(not self.busy)

    def update_records(self):
        lib = self.library
        self.record_list.clear()
        if lib is None:
            self.records_summary.setText('打开项目后查看整理记录。')
            return
        self.records_summary.setText(f'{lib["paired"]} 对已验证 · {lib["orphanRaw"]} 个独立 RAW · {lib["ambiguous"]} 个配对歧义')
        for record in lib['history']:
            item = QListWidgetItem(f'{record["timestamp"].replace("T"," ")}\n{record["mode"]} · {record["moved"]} 个文件')
            item.setData(Qt.ItemDataRole.UserRole,record['path'])
            item.setToolTip('双击查看日志')
            self.record_list.addItem(item)

    def set_scope(self, scope):
        if not self.busy:
            previous = self.photo
            self.scope = scope
            self.settings.setValue('scope',scope)
            self.rebuild_album(previous)

    def switch_pool(self, pool):
        if not self.busy:
            self.pool_selection[self.pool] = self.photo
            self.pool = pool
            self.index = 0
            self.rebuild_album(self.pool_selection.get(pool))

    def scan_bursts(self):
        if self.bursts_scanning or self.bursts_scanned or not self.library:
            return
        paths = {photo['jpeg'] or photo['raw'] for key in ('photos','rawPhotos','poolPhotos','poolRawPhotos') for photo in self.library[key]}
        paths.update(photo['raw'] for key in ('rawPhotos','poolRawPhotos') for photo in self.library[key])
        generation = self.burst_generation
        self.bursts_scanning = True

        def done(ids,error):
            if generation != self.burst_generation:
                return
            self.bursts_scanning = False
            self.bursts_scanned = not error
            if not error:
                self.burst_ids = ids
                self.rebuild_album(self.photo)

        self.tasks.submit('metadata',lambda: {p:group for p in paths if p and (group:=media.metadata(p).burst)},done)

    def collapsed_group(self, group):
        return self.fold_all != (group in self.burst_overrides)

    def rebuild_album(self, preferred=None):
        rows = ops.scoped(self.library,self.scope_name,self.pool,self.selected_folders.get(self.pool))
        self.groups = {}
        for photo in rows:
            path = ops.display_path(photo,self.scope_name)
            group = self.burst_ids.get(path)
            if group:
                self.groups.setdefault(group,[]).append(path)
        slots = {}
        self.photos = []
        for photo in rows:
            path = ops.display_path(photo,self.scope_name)
            group = self.burst_ids.get(path)
            if group and self.collapsed_group(group):
                if group in slots:
                    saved = self.representatives.get(group)
                    if saved and ops.display_path(saved,self.scope_name) == path:
                        self.photos[slots[group]] = photo
                    continue
                slots[group] = len(self.photos)
            self.photos.append(photo)
        match = next((i for i,p in enumerate(self.photos) if preferred and
                      any(preferred.get(ext) and preferred[ext]==p.get(ext) for ext in ('jpeg','raw'))),None)
        self.index = match if match is not None else min(self.index,max(0,len(self.photos)-1))
        if self.pages.currentIndex()==1:
            self.update_viewer()

    def toggle_bursts(self):
        if self.pages.currentIndex()!=1 or self.library is None or self.bursts_scanning:
            return
        photo = self.photo
        if not self.bursts_scanned:
            self.scan_bursts()
        self.fold_all = not self.fold_all
        self.burst_overrides.clear()
        if self.fold_all and self.path in self.burst_ids:
            self.representatives[self.burst_ids[self.path]] = photo
        self.rebuild_album(photo)

    def toggle_group(self,index):
        if index is None or not 0 <= index < len(self.photos):
            return
        photo = self.photos[index]
        group = self.burst_ids.get(ops.display_path(photo,self.scope_name))
        if not group or len(self.groups[group])<2:
            return
        if not self.collapsed_group(group):
            self.representatives[group] = self.photo if self.burst_ids.get(self.path)==group else photo
        self.burst_overrides.symmetric_difference_update({group})
        self.rebuild_album(self.photo)

    def select(self,index):
        if index is not None and self.pages.currentIndex()==1 and 0 <= index < len(self.photos):
            self.index = index
            self.update_viewer()

    def step(self,delta):
        if self.photos:
            self.select(min(len(self.photos)-1,max(0,self.index+delta)))

    def show_photo_title(self):
        self.photo_title.setText(Path(self.path).name if self.path else '沉浸选片')
        offline = self.root is not None and self.presence.get(str(self.root)) == False
        self.photo_subtitle.setText('项目离线' if offline else f'{self.scope_name} · {self.viewport_label}')

    def eventFilter(self, widget, event):
        if widget is getattr(self, 'viewer_header', None) and event.type() == QEvent.Type.Resize:
            self.layout_viewer_header(event.size().width())
        return super().eventFilter(widget,event)

    def layout_viewer_header(self, width):
        layout = self.viewer_header_layout
        needed = self.viewer_scope_tools.sizeHint().width() + self.viewer_action_tools.sizeHint().width() + layout.spacing()
        direction = QBoxLayout.Direction.LeftToRight if width >= needed else QBoxLayout.Direction.TopToBottom
        if layout.direction() != direction:
            layout.setDirection(direction)

    def update_viewer(self,load=True):
        self.show_photo_title()
        folder = self.selected_folders.get(self.pool)
        text = folder.name if folder else '全部文件夹'
        self.folders_button.setText(self.folders_button.fontMetrics().elidedText(text,Qt.TextElideMode.ElideMiddle,158))
        self.folders_button.setToolTip(str(folder) if folder else '按文件夹树选片')
        self.folders_button.setEnabled(bool(self.library) and not self.busy)
        self.layout_viewer_header(self.viewer_header.width())
        for index, widget in enumerate(self.scope_buttons):
            active = index == self.scope
            widget.setChecked(active)
            color = (COLORS if self.dark else ('#117b23','#855d00','#af2720'))[index]
            widget.setStyleSheet(f'color:{color};' + (f'font-weight:700;border-color:{color};' if active else ''))
            widget.setEnabled(not self.busy)
        for index, widget in enumerate(self.pool_buttons):
            pool = bool(index)
            widget.setChecked(pool == self.pool)
            size = len(ops.scoped(self.library,self.scope_name,pool,self.selected_folders.get(pool)))
            widget.setText(f'{"待删池" if pool else "正式池"}  {size}')
            color = (POOL_COLORS if self.dark else ('#117b23','#a44900'))[index]
            widget.setStyleSheet(f'color:{color};border-color:{color};' if pool == self.pool else '')
            widget.setEnabled(not self.busy)
        self.set_glyph(self.w_button,'unstage' if self.pool else 'stage')
        stage_action = '恢复到正式池 · W' if self.pool else '移入待删池 · W'
        self.w_button.setToolTip(stage_action)
        self.w_button.setAccessibleName(stage_action)
        self.w_button.setEnabled(bool(self.photo) and not self.busy)
        self.s_button.setEnabled(bool(self.photo) and not self.busy)
        self.pool_delete_button.setVisible(self.pool)
        self.pool_delete_button.setEnabled(bool(self.pool_deletion_plan()))
        self.burst_toggle.setChecked(self.fold_all)
        self.burst_toggle.setEnabled(not self.bursts_scanning and bool(self.library))
        self.step_label.setText(f'{self.index+1 if self.photos else 0} / {len(self.photos)}')
        if not self.path:
            self.image_generation += 1
            self.loading_path,self.frame = None,None
            text = ('正在读取影像项目…' if self.busy else '无法读取影像项目 · Ctrl+R 重试' if self.load_error
                    else '打开影像项目 · Ctrl+O' if not self.root else ('当前范围没有 JPEG','当前范围没有 RAW','当前范围没有已配对的 JPEG')[self.scope])
            self.show_placeholder(text,self.busy)
        elif load:
            self.load_photo()
        self.render_filmstrip()
        self.toggle_inspector()

    def select_folder(self, folder):
        previous = self.photo
        self.selected_folders[self.pool] = folder
        self.index = 0
        self.rebuild_album(previous)

    def choose_photo_folder(self):
        if self.busy or not self.library:
            return
        dialog = QDialog(self)
        dialog.setObjectName('folderPicker')
        title = '待删池目录' if self.pool else '项目目录'
        dialog.setWindowTitle(title)
        dialog.resize(410,435)
        outer = QVBoxLayout(dialog)
        outer.setContentsMargins(8,8,8,8)
        material = Material()
        material.dark = self.dark
        if self.frame:
            material.backdrop = self.frame.blur
        outer.addWidget(material)
        layout = QVBoxLayout(material)
        layout.setContentsMargins(12,12,12,12)
        tree = QTreeWidget(material)
        tree.setObjectName('folderTree')
        tree.setHeaderHidden(True)
        layout.addWidget(tree)
        top = QTreeWidgetItem(tree,['全部文件夹'])
        nodes = {None:top}
        folders = map(Path,self.library['poolFolders' if self.pool else 'activeFolders'])
        for path in sorted(folders,key=lambda p:(len(p.parts),str(p).casefold())):
            node = QTreeWidgetItem(nodes.get(path.parent,top),[path.name])
            node.setData(0,Qt.ItemDataRole.UserRole,str(path))
            node.setToolTip(0,str(path))
            nodes[path] = node
        tree.setCurrentItem(nodes.get(self.selected_folders.get(self.pool),top))
        node = tree.currentItem()
        while node:
            node.setExpanded(True)
            node = node.parent()
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Open | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Open).setText('查看选中目录')
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText('取消')
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        tree.itemDoubleClicked.connect(dialog.accept)
        layout.addWidget(buttons)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            path = tree.currentItem().data(0,Qt.ItemDataRole.UserRole)
            self.select_folder(Path(path) if path else None)
        dialog.deleteLater()

    def show_placeholder(self,text,loading=False):
        self.placeholder.setText(text)
        self.spinner.setVisible(loading)
        self.canvas.setCurrentIndex(1)

    def load_photo(self):
        path = self.path
        if self.loading_path == path:
            return
        self.loading_path = path
        self.image_generation += 1
        token = self.image_generation
        self.frame = None
        if path in self.frame_cache:
            self.frame_cache.move_to_end(path)
            self.render_frame(self.frame_cache[path])
            return
        self.show_placeholder('正在解码照片…',True)
        photo = self.photo
        companion = photo['jpeg'] if self.scope==1 else photo['raw']
        self.tasks.pools['decode'].clear()

        def loaded(frame,error):
            if token!=self.image_generation or path!=self.path:
                return
            if error:
                self.show_placeholder(f'无法解码 {Path(path).name}',False)
                self.report(error)
            else:
                self.frame_cache[path] = frame
                self.frame_cache.move_to_end(path)
                while len(self.frame_cache) > 3:
                    self.frame_cache.popitem(last=False)
                self.render_frame(frame)

        self.tasks.submit('decode',lambda:media.load_frame(path,companion),loaded)

    def render_frame(self,frame):
        self.frame = frame
        self.canvas.setCurrentIndex(0)
        self.photo_view.set_image(frame.image,frame.metadata.focus)
        for material in (self.filmstrip,self.inspector):
            material.backdrop = frame.blur
            material.update()
        self.update_inspector()

    def render_filmstrip(self):
        visible = self.strip_toggle.isChecked() and bool(self.photos)
        self.filmstrip.setVisible(visible)
        if not visible:
            return
        color = COLORS[self.scope]
        rail = color if self.dark else ('#117b23','#a17200','#af2720')[self.scope]
        if self.scrubber.property('railColor') != rail:
            self.scrubber.setProperty('railColor', rail)
            self.scrubber.setStyleSheet(f'QSlider::handle:horizontal {{background:{rail};}}')
        for tile,index in zip(self.tiles, range(self.index-3,self.index+4)):
            if not 0 <= index < len(self.photos):
                tile.update_tile(QImage(),None,None,None)
                continue
            path = ops.display_path(self.photos[index],self.scope_name)
            group = self.burst_ids.get(path)
            members = self.groups.get(group,[])
            badge = None
            if len(members)>1:
                badge = f'×{len(members)}' if self.collapsed_group(group) else f'{members.index(path)+1}/{len(members)}'
            tile.update_tile(self.thumb_cache.get(path,QImage()),index,color if index==self.index else None,badge)
            if path not in self.thumb_cache and path not in self.thumb_pending and len(self.thumb_pending)<12:
                self.thumb_pending.add(path)
                self.tasks.submit('thumb',lambda p=path:media.thumbnail(p),partial(self.thumbnail_ready,path))
        self.scrubber.setMaximum(max(0,len(self.photos)-1))
        if not self.scrubber.isSliderDown():
            self.scrubber.setValue(self.index)
        self.scrubber.setVisible(len(self.photos)>1)
        self.scrub_label(self.scrubber.value())

    def thumbnail_ready(self,path,image,error):
        self.thumb_pending.discard(path)
        self.thumb_cache[path] = QImage() if error else image
        while len(self.thumb_cache)>180:
            self.thumb_cache.popitem(last=False)
        if self.pages.currentIndex()==1:
            self.render_filmstrip()

    def scrub_label(self,index):
        if 0 <= index < len(self.photos):
            name = Path(ops.display_path(self.photos[index],self.scope_name)).name if self.scrubber.isSliderDown() else '快速定位'
            self.strip_position.setText(f'{name}    {index+1} / {len(self.photos)}')

    def update_inspector(self):
        if not self.info_toggle.isChecked():
            return
        for section in (self.exif,self.file_details):
            while section.rowCount():
                section.removeRow(0)
        self.histogram.channels = self.frame.histogram if self.frame else None
        self.histogram.update()
        if self.frame:
            caption = 'RAW 显影' if self.scope==1 else 'JPEG'
            luma = self.frame.histogram[-1]
            sample_count = max(1,sum(luma))
            self.histogram_caption.setText(f'{caption} · sRGB   黑端 {luma[0]/sample_count:.1%} · 白端 {luma[-1]/sample_count:.1%}')
            for name,value in self.frame.metadata.rows.items():
                self.info_row(self.exif,name,value)
        else:
            self.histogram_caption.setText('')
        if photo := self.photo:
            for title, field in [('JPEG','jpeg'),('RAW','raw')]:
                size = photo.get(field+'Bytes') if photo.get(field) else None
                value = byte_text(size) if photo.get(field) else '无文件'
                text = self.info_row(self.file_details,title+' 体积',value)
                if size is not None:
                    text.setToolTip(f'{size:,} 字节')
            self.info_row(self.file_details,'配对状态',photo['status'])
            if photo['source']:
                self.info_row(self.file_details,'验证依据',photo['source'])

    @staticmethod
    def info_row(rows,name,value):
        text = label(value,wrap=True)
        text.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        rows.addRow(label(name,'muted'),text)
        return text

    def reveal_photo(self):
        if not self.path:
            return
        if sys.platform=='win32':
            import subprocess
            subprocess.Popen(['explorer.exe','/select,'+str(Path(self.path))])
        else:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(self.path).parent)))

    def cull(self,stage):
        if self.pages.currentIndex()!=1 or not self.photo or self.busy or self.root is None:
            return
        root, photo, path, index = self.root,self.photo,self.path,self.index
        paths = ops.selected_paths(photo,self.scope_name)
        pool = self.pool
        preferred = self.photos[index+1] if index+1<len(self.photos) else self.photos[index-1] if index>0 else None
        mode,rules,travel = self.options
        if self.filmstrip.isVisible() and not (pool and stage):
            tile = self.tiles[3]
            rect = QRectF(tile.rect()).adjusted(4,4,-4,-17)
            rect.translate(tile.mapTo(self.departure.parentWidget(),tile.rect().topLeft()))
            self.departure.play(tile.image,rect,not stage)

        previous = self.library
        self.library = ops.without_paths(previous,set(paths),pool)
        self.rebuild_album(preferred)

        def work():
            if not stage:
                ops.recycle(root,paths,self.journal)
            elif pool:
                ops.restore_pool(root,paths)
            else:
                ops.stage(root,photo,paths)
            return ops.scan(root,mode,rules,travel)

        def done(library,error):
            if error:
                self.library = previous
                self.rebuild_album(photo)
                self.report(error)
                self.rescan()
                return
            self.bursts_scanned = False
            self.apply_library(library,self.photo or preferred)
            self.report('已移入 Windows 系统回收站 · Ctrl+Z 可撤回' if not stage else '已恢复到正式池' if pool else '已移入待删池')

        self.begin_io('正在处理照片…',work,done)

    def pool_deletion_plan(self):
        if (self.pages.currentIndex() != 1 or not self.pool or self.busy or not self.root
                or not self.library or self.presence.get(str(self.root)) is False):
            return None
        directories = tuple(self.library['poolDirectories'])
        return (self.root,directories) if directories else None

    def confirm_remove_pool(self):
        if not (plan := self.pool_deletion_plan()):
            return
        root,directories = plan
        dialog = QMessageBox(self)
        dialog.setWindowTitle('删除整个待删池？')
        dialog.setIcon(QMessageBox.Icon.Warning)
        dialog.setTextFormat(Qt.TextFormat.PlainText)
        dialog.setText(f'将 {len(directories)} 个待删池文件夹及其中全部内容移入 Windows 系统回收站？')
        dialog.setInformativeText(f'当前项目：{root}\n可以按 Ctrl+Z 撤回。')
        dialog.setDetailedText('\n'.join(str(Path(path).relative_to(root)) if Path(path).is_relative_to(root) else path
                                         for path in directories))
        cancel = dialog.addButton(QMessageBox.StandardButton.Cancel)
        cancel.setText('取消')
        move = dialog.addButton('移入 Windows 系统回收站',QMessageBox.ButtonRole.DestructiveRole)
        dialog.setDefaultButton(cancel)
        dialog.setEscapeButton(cancel)
        dialog.exec()
        confirmed = dialog.clickedButton() is move
        dialog.deleteLater()
        if not confirmed:
            return
        if self.pool_deletion_plan() != plan:
            self.report('待删池已经变化，请重新确认。')
            return
        self.mutate_and_scan(lambda current:ops.recycle(current,directories,self.journal,directories=True),
                             f'已将 {len(directories)} 个待删池文件夹移入系统回收站 · Ctrl+Z 可撤回',
                             description='正在删除待删池…',rescan_on_error=True)

    def restore_all_pool(self):
        if self.root and self.library and self.library['poolBatches']:
            self.mutate_and_scan(lambda root:ops.restore_pool(root,all_batches=True),'已恢复待删文件')

    def restore_delete(self):
        if self.journal.exists():
            self.mutate_and_scan(lambda root:ops.restore_recycle(self.journal),'已撤回删除')

    def mutate_and_scan(self,mutation,summary,description='正在恢复文件…',rescan_on_error=False):
        root = self.root
        mode,rules,travel = self.options

        def work():
            changed = mutation(root)
            current = ops.scan(root,mode,rules,travel) if root and root.is_dir() else None
            return current,changed

        def done(result,error):
            if error:
                self.report(error)
                if rescan_on_error:
                    self.rescan()
            else:
                if result[0]:
                    self.bursts_scanned = False
                    self.apply_library(result[0])
                self.report(summary)

        self.begin_io(description,work,done)

    def closeEvent(self, event):
        if self.busy:
            self.report('请等待当前文件操作完成。')
            event.ignore()
            return
        self.preview_timer.stop()
        self.presence_timer.stop()
        self.tasks.stopping = True
        for pool in self.tasks.pools.values():
            pool.clear()
        super().closeEvent(event)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='ZFilter')
    parser.add_argument('--project', type=Path)
    parser.add_argument('--viewer', action='store_true')
    parser.add_argument('--info', action='store_true')
    parser.add_argument('--package-smoke-test', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    app = QApplication([sys.argv[0]])
    app.setApplicationName('ZFilter')
    app.setOrganizationName('ZFilter')
    app.setStyle('Fusion')
    app.setFont(QFont('Microsoft YaHei UI' if sys.platform=='win32' else 'PingFang SC',10))
    ui = Window(QSettings(QSettings.Format.IniFormat, QSettings.Scope.UserScope,'ZFilter','PackageSmoke') if args.package_smoke_test else None)
    ui.show()
    if args.viewer or args.package_smoke_test:
        ui.show_page(1)
    if args.package_smoke_test:
        ui.set_scope(1)
    if args.info:
        ui.info_toggle.setChecked(True)
    if args.project:
        ui.open_project(args.project)
    if args.package_smoke_test:
        def check():
            if ui.frame and ui.scope == 1 and ui.frame.image.width() > 2000:
                app.exit(0)
        timer = QTimer(ui, interval=100)
        timer.timeout.connect(check)
        timer.start()
        QTimer.singleShot(25000, lambda: app.exit(1))
    return app.exec()
