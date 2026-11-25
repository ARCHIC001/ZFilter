"""Fluent system icons with consistent 18 px geometry at 100–300% DPI."""
from functools import lru_cache
from pathlib import Path

from PySide6.QtCore import QSize, Qt
from PySide6.QtGui import QColor, QIcon, QPainter, QPixmap
from PySide6.QtSvg import QSvgRenderer

SIZE = QSize(18, 18)
ASSETS = Path(__file__).with_name('icons')


@lru_cache(maxsize=128)
def fluent_icon(name, dark):
    vector = QSvgRenderer(str(ASSETS / (name+'.svg')))
    if not vector.isValid():
        raise FileNotFoundError(f'Invalid or missing Fluent icon: {name}')
    icon = QIcon()
    foreground, disabled = ('#d9e2ef','#657187') if dark else ('#35445b','#8591a2')
    for mode, color in ((QIcon.Mode.Normal,foreground), (QIcon.Mode.Disabled,disabled)):
        for scale in (1,2,3):
            image = QPixmap(SIZE*scale)
            image.fill(Qt.GlobalColor.transparent)
            painter = QPainter(image)
            painter.setRenderHint(QPainter.RenderHint.Antialiasing)
            vector.render(painter)
            painter.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
            painter.fillRect(image.rect(),QColor(color))
            painter.end()
            image.setDevicePixelRatio(scale)
            icon.addPixmap(image,mode)
    return icon
