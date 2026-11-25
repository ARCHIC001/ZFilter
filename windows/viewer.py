"""Qt photo canvas, Gaussian material, histogram and filmstrip controls."""
from math import log1p
import random
import sys

from PySide6.QtCore import QElapsedTimer, QPoint, QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QImage, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (
    QFrame, QGraphicsPixmapItem, QGraphicsRectItem, QGraphicsScene, QGraphicsView,
    QLabel, QSlider, QToolButton, QVBoxLayout, QWidget,
)


class PhotoView(QGraphicsView):
    viewport_changed = Signal(str)
    tracking_changed = Signal(bool)

    def __init__(self):
        super().__init__()
        self.setScene(QGraphicsScene(self))
        self.photo = QGraphicsPixmapItem()
        self.photo.setTransformationMode(Qt.TransformationMode.SmoothTransformation)
        self.scene().addItem(self.photo)
        self.focus_box = QGraphicsRectItem()
        pen = QPen(QColor('#1dcd3a'), 2)
        pen.setCosmetic(True)
        self.focus_box.setPen(pen)
        self.scene().addItem(self.focus_box)
        self.focus_box.hide()
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.NoAnchor)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        self.fit = True
        self.tracking = False
        self.show_box = False
        self.point = None
        self.press = None
        self.dragged = False

    def set_image(self, image, point):
        self.photo.setPixmap(QPixmap.fromImage(image))
        self.point = point
        self.setSceneRect(self.photo.boundingRect())
        self.update_box()
        if self.tracking:
            self.focus_zoom()
        else:
            self.fit_window()

    def update_box(self):
        width, height = self.photo.pixmap().width(), self.photo.pixmap().height()
        if self.show_box and self.point and width and height:
            x, y, w, h, _ = self.point
            w, h = max(w*width, 14), max(h*height, 14)
            self.focus_box.setRect(x*width-w/2, y*height-h/2, w, h)
            self.focus_box.show()
        else:
            self.focus_box.hide()

    def set_zoom(self, scale, center):
        self.fit = False
        self.resetTransform()
        self.scale(scale, scale)
        self.centerOn(center)
        self.viewport_changed.emit(f'{scale*self.devicePixelRatioF():.0%}')

    def set_tracking(self, enabled):
        if self.tracking != enabled:
            self.tracking = enabled
            self.tracking_changed.emit(enabled)

    def focus_zoom(self):
        self.set_tracking(True)
        if self.photo.pixmap().isNull():
            return
        width, height = self.photo.pixmap().width(), self.photo.pixmap().height()
        x, y = self.point[:2] if self.point else (0.5, 0.5)
        self.set_zoom(1/self.devicePixelRatioF(), QPointF(x*width, y*height))
        self.viewport_changed.emit('100% · 对焦点' if self.point else '100% · 画面中心')

    def fit_window(self):
        self.set_tracking(False)
        self.fit = True
        self.resize_image()
        self.viewport_changed.emit('适应窗口')

    def resize_image(self):
        if self.fit and not self.photo.pixmap().isNull() and self.viewport().width() > 12 and self.viewport().height() > 12:
            self.fitInView(self.photo.boundingRect(), Qt.AspectRatioMode.KeepAspectRatio)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.resize_image()

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.press = event.position().toPoint()
            self.anchor = (self.horizontalScrollBar().value(), self.verticalScrollBar().value())
            self.dragged = False
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self.press is not None:
            delta = event.position().toPoint() - self.press
            if self.dragged or delta.manhattanLength() >= 5:
                self.dragged = True
                self.horizontalScrollBar().setValue(self.anchor[0]-delta.x())
                self.verticalScrollBar().setValue(self.anchor[1]-delta.y())
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if self.press is not None and event.button() == Qt.MouseButton.LeftButton:
            self.press = None
            if not self.dragged and not self.photo.pixmap().isNull():
                if self.fit:
                    self.set_zoom(1/self.devicePixelRatioF(), self.mapToScene(event.position().toPoint()))
                else:
                    self.fit_window()
            event.accept()
        else:
            super().mouseReleaseEvent(event)

    def wheelEvent(self, event):
        if self.photo.pixmap().isNull():
            return
        if event.modifiers() & Qt.KeyboardModifier.ControlModifier or self.fit:
            current = self.transform().m11()
            scale = min(8, max(0.025, current*1.15**(event.angleDelta().y()/120)))
            self.set_tracking(False)
            self.set_zoom(scale, self.mapToScene(event.position().toPoint()))
            event.accept()
        else:
            super().wheelEvent(event)


class Material(QFrame):
    """The backdrop is blurred once per image, so drawing never blurs live controls."""
    def __init__(self):
        super().__init__()
        self.backdrop = QImage()
        self.dark = True

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        shape = QPainterPath()
        shape.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5), 12, 12)
        p.setClipPath(shape)
        if not self.backdrop.isNull():
            p.drawImage(self.rect(), self.backdrop)
        p.fillPath(shape, QColor(26, 30, 39, 219) if self.dark else QColor(250, 252, 255, 225))
        p.setPen(QPen(QColor(255,255,255,31) if self.dark else QColor(31,55,82,30)))
        p.drawPath(shape)


class Histogram(QWidget):
    def __init__(self):
        super().__init__()
        self.setMinimumHeight(95)
        self.setMaximumHeight(100)
        self.channels = None
        self.log = True
        self.dark = True

    @staticmethod
    def curves(channels, logarithmic):
        smooth = [[(bins[max(0,i-1)]+2*bins[i]+bins[min(255,i+1)])/4 for i in range(256)] for bins in channels]
        values = [[log1p(count) for count in row] for row in smooth] if logarithmic else smooth
        peak = max(1, max(map(max, values)))
        return [[count/peak for count in row] for row in values]

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        plot = QRectF(self.rect()).adjusted(5, 5, -5, -5)
        p.setBrush(QColor('#252932' if self.dark else '#f1f4f8'))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawRoundedRect(QRectF(self.rect()), 6, 6)
        p.setPen(QColor('#434851' if self.dark else '#d1d7e0'))
        for fraction in (.25,.5,.75):
            x = plot.left()+plot.width()*fraction
            p.drawLine(QPointF(x,plot.top()),QPointF(x,plot.bottom()))
        p.drawLine(QPointF(plot.left(),plot.center().y()),QPointF(plot.right(),plot.center().y()))
        if not self.channels:
            return
        colors = ('#ff736d','#53e272','#71a8ff','#e9edf3') if self.dark else ('#a92624','#117b23','#245caf','#29313d')
        curves = self.curves(self.channels, self.log)
        for i in (3,0,1,2):
            line = QPainterPath()
            line.moveTo(plot.left(), plot.bottom()-curves[i][0]*plot.height())
            for x, value in enumerate(curves[i][1:], 1):
                line.lineTo(plot.left()+plot.width()*x/255, plot.bottom()-plot.height()*value)
            fill = QPainterPath(line)
            fill.lineTo(plot.bottomRight())
            fill.lineTo(plot.bottomLeft())
            fill.closeSubpath()
            color = QColor(colors[i])
            color.setAlpha(33)
            p.fillPath(fill, color)
            p.setPen(QPen(QColor(colors[i]), 1))
            p.drawPath(line)


class Scrubber(QSlider):
    seek = Signal(int)

    def seek_to(self, x):
        fraction = max(0.0, min(1.0, (x-8)/max(1, self.width()-16)))
        self.setValue(round(self.maximum()*fraction))

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.setSliderDown(True)
            self.seek_to(event.position().x())
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self.isSliderDown():
            self.seek_to(event.position().x())

    def mouseReleaseEvent(self, event):
        if self.isSliderDown():
            self.seek_to(event.position().x())
            self.setSliderDown(False)
            self.seek.emit(self.value())
        else:
            super().mouseReleaseEvent(event)

    def keyPressEvent(self, event):
        previous = self.value()
        super().keyPressEvent(event)
        if self.value() != previous:
            self.seek.emit(self.value())


class Tile(QFrame):
    selected = Signal()
    burst_toggled = Signal()
    dragged = Signal(int)

    def __init__(self):
        super().__init__()
        self.setObjectName('tile')
        self.setFixedHeight(84)
        self.setMinimumWidth(35)
        self.image = QImage()
        self.index = None
        self.accent = None
        self.origin = None
        self.moved = 0
        self.badge = QToolButton(self)
        self.badge.setObjectName('badge')
        self.badge.hide()
        self.badge.clicked.connect(self.burst_toggled)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def update_tile(self, image, index, accent, badge):
        self.image, self.index, self.accent = image, index, accent
        if badge:
            self.badge.setText(badge)
            self.badge.adjustSize()
            self.badge.move(self.width()-self.badge.width()-5, 5)
            self.badge.setToolTip('点击展开或折叠本组连拍')
        self.badge.setVisible(bool(badge))
        self.update()

    def resizeEvent(self, event):
        self.badge.move(self.width()-self.badge.width()-5, 5)
        super().resizeEvent(event)

    def paintEvent(self, event):
        if self.index is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        target = QRectF(self.rect()).adjusted(4, 4, -4, -17)
        path = QPainterPath()
        path.addRoundedRect(target, 7, 7)
        p.fillPath(path, QColor(128, 139, 155, 65))
        if not self.image.isNull():
            p.save()
            p.setClipPath(path)
            widths = target.width()/self.image.width(), target.height()/self.image.height()
            scale = max(widths)
            w, h = self.image.width()*scale, self.image.height()*scale
            p.drawImage(QRectF(target.center().x()-w/2, target.center().y()-h/2, w, h), self.image)
            p.restore()
        if self.accent:
            glow = QColor(self.accent)
            glow.setAlpha(85)
            p.setPen(QPen(glow, 4))
            p.drawPath(path)
            p.setPen(QPen(QColor(self.accent), 1))
            p.drawPath(path)
        p.setPen(QColor(self.accent) if self.accent else self.palette().text().color())
        p.drawText(QRectF(0, self.height()-16, self.width(), 15), Qt.AlignmentFlag.AlignCenter, str(self.index+1))

    def mousePressEvent(self, event):
        if self.index is not None and event.button() == Qt.MouseButton.LeftButton:
            self.origin = event.globalPosition()
            self.moved = 0

    def mouseMoveEvent(self, event):
        if self.origin is not None:
            delta = event.globalPosition().x()-self.origin.x()
            frames = round(-delta/max(24, self.width()+6))
            if frames != self.moved:
                self.dragged.emit(frames-self.moved)
                self.moved = frames

    def mouseReleaseEvent(self, event):
        if self.origin is not None:
            if not self.moved and abs(event.globalPosition().x()-self.origin.x()) < 5:
                self.selected.emit()
            self.origin = None


def motion_enabled():
    if sys.platform == 'win32':
        import ctypes
        enabled = ctypes.c_int(1)
        if ctypes.windll.user32.SystemParametersInfoW(0x1042, 0, ctypes.byref(enabled), 0):
            return bool(enabled.value)
    return True


class Departure(QWidget):
    def __init__(self, parent):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.hide()
        self.clock = QElapsedTimer()
        self.refresh = QTimer(self, interval=16)
        self.refresh.timeout.connect(self.tick)

    def play(self, image, rect, shattered):
        if image.isNull() or not motion_enabled():
            return
        self.image, self.rect, self.shattered = image, rect, shattered
        self.duration = 390 if shattered else 240
        rng = random.Random(42)
        self.shards = [(rng.uniform(-155,155), rng.uniform(-110,65)) for _ in range(48)]
        self.setGeometry(self.parentWidget().rect())
        self.raise_()
        self.show()
        self.clock.start()
        self.refresh.start()

    def tick(self):
        if self.clock.elapsed() >= self.duration:
            self.refresh.stop()
            self.hide()
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        t = min(1, self.clock.elapsed()/self.duration)
        p.setOpacity((1-t)**1.35)
        if not self.shattered:
            p.drawImage(self.rect.translated(0, -125*t), self.image)
        else:
            for i, (dx,dy) in enumerate(self.shards):
                x, y = i%8, i//8
                w, h = self.rect.width()/8, self.rect.height()/6
                sx, sy = self.image.width()/8, self.image.height()/6
                source = QRectF(x*sx,y*sy,sx,sy)
                target = QRectF(self.rect.x()+x*w+dx*t,self.rect.y()+y*h+dy*t+55*t*t,w*(1-t*.7),h*(1-t*.7))
                p.drawImage(target, self.image, source)
