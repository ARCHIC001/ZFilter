"""Full RAW decode and the Nikon metadata used by the viewer."""
from dataclasses import dataclass
from functools import lru_cache
from io import BytesIO
from math import isfinite
from pathlib import Path
import os
import re
import shutil
import struct
import subprocess
from tempfile import TemporaryDirectory

import numpy as np
from PIL import Image, ImageFilter, ImageOps
from PySide6.QtGui import QImage

from nikonfilter import JPEG_EXT

AREA_MODES = {192: '精确', 193: '单点', 195: '宽区域（小）', 196: '宽区域（大）', 197: '自动区域',
              204: '动态区域（小）', 205: '动态区域（中）', 206: '动态区域（大）', 207: '3D 跟踪', 208: '宽区域（自定义）'}
METERING = {0: '未知', 1: '平均测光', 2: '中央重点平均', 3: '点测光', 4: '多点测光',
            5: '矩阵／评价测光', 6: '局部测光', 255: '其他'}


def tiff_data(header):
    if not header.startswith(b'\xff\xd8'):
        return header
    offset = 2
    while offset + 4 <= len(header) and header[offset] == 255:
        marker = header[offset+1]
        if marker == 255:
            offset += 1
            continue
        if marker in (0xDA, 0xD9):
            break
        size = int.from_bytes(header[offset+2:offset+4], 'big')
        end = offset+2+size
        if size < 2 or end > len(header):
            break
        payload = header[offset+4:end]
        if marker == 0xE1 and payload.startswith(b'Exif\0\0'):
            return payload[6:]
        offset = end
    return b''


class TIFF:
    widths = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8}

    def __init__(self, image):
        self.image = image
        self.order = {b'II': '<', b'MM': '>'}.get(image[:2])
        self.first = self.unpack('I', image, 4)[0] if self.unpack('H', image, 2) == (42,) and len(image) >= 8 else 0

    def unpack(self, kind, data, offset=0):
        if not self.order or offset < 0 or offset + struct.calcsize('<'+kind) > len(data):
            return ()
        return struct.unpack_from(self.order+kind, data, offset)

    def tags(self, offset):
        tags = {}
        count = self.unpack('H', self.image, offset)
        if not offset or not count or count[0] > 4096 or offset+2+12*count[0] > len(self.image):
            return tags
        for i in range(count[0]):
            pos = offset+2+12*i
            tag, kind, n, pointer = self.unpack('HHII', self.image, pos)
            length = n*self.widths.get(kind, 0)
            start = pos+8 if length <= 4 else pointer
            if 0 < length <= 524288 and start+length <= len(self.image):
                tags[tag] = (kind, self.image[start:start+length])
        return tags

    def field(self, tags, tag):
        kind, data = tags.get(tag, (0, b''))
        if kind in (2, 7):
            return text(data) if kind == 2 else data
        if kind in (5, 10):
            pair = self.unpack('II' if kind == 5 else 'ii', data)
            return pair[0]/pair[1] if pair and pair[1] else None
        code = {1: 'B', 3: 'H', 4: 'I', 9: 'i'}.get(kind)
        values = self.unpack(code, data) if code else ()
        return values[0] if values else None


def text(data):
    data = data.split(b'\0', 1)[0].strip()
    for charset in ('utf-8', 'shift_jis'):
        try:
            return data.decode(charset) or None
        except UnicodeDecodeError:
            pass
    return None


@dataclass
class Metadata:
    rows: dict
    focus: tuple | None = None
    burst: tuple | None = None


def read_metadata(path):
    try:
        with open(path, 'rb') as image:
            header = image.read(1024*1024)
    except OSError:
        return Metadata({})
    tiff = TIFF(tiff_data(header))
    tags = tiff.tags(tiff.first)
    exif = tiff.tags(tiff.field(tags, 0x8769) or 0)

    def value(tag):
        return tiff.field(exif, tag)

    rows = {}
    for label, data in [('相机', tiff.field(tags, 0x0110)), ('镜头', value(0xA434))]:
        if data:
            rows[label] = data
    timestamp = value(0x9003)
    if isinstance(timestamp, str):
        rows['拍摄时间'] = re.sub(r'^\d{4}:\d{2}:\d{2}(?=[ T]|$)', lambda m: m[0].replace(':', '-'), timestamp)
    aperture, exposure, iso, bias, focal = (value(tag) for tag in (0x829D, 0x829A, 0x8827, 0x9204, 0x920A))
    if aperture:
        rows['光圈'] = f'ƒ/{aperture:g}'
    if exposure and exposure > 0:
        rows['快门'] = f'1/{round(1/exposure)} s' if exposure < 1 else f'{exposure:g} s'
    if iso:
        rows['ISO'] = str(iso)
    if bias is not None and isfinite(bias):
        rows['曝光补偿'] = f'{bias:+.1f} EV' if bias else '0 EV'
    metering = value(0x9207)
    if metering is not None:
        rows['测光模式'] = METERING.get(metering, f'未知（{metering}）')
    flash = value(0x9209)
    if isinstance(flash, int) and 0 <= flash < 128:
        rows['闪光灯'] = '已闪光' if flash & 1 else '无闪光功能' if flash & 32 else '未闪光'
    if focal:
        rows['焦距'] = f'{focal:g} mm'
    distance = value(0x9206)
    if isinstance(distance, (int, float)) and distance > 0:
        rows['对焦距离'] = '∞（无穷远）' if distance >= 4294967295 else f'约 {distance:.2f} m'
    result = Metadata(rows)
    maker = value(0x927C)
    if isinstance(maker, bytes) and maker.startswith(b'Nikon\0') and len(maker) >= 18:
        read_nikon(result, TIFF(maker[10:]), tiff.field(tags, 0x0112) or 1)
    return result


def read_nikon(result, tiff, orientation):
    tags = tiff.tags(tiff.first)

    def value(tag):
        return tiff.field(tags, tag)

    rows = result.rows
    mode, preset, af = value(0x0007), value(0x0023), value(0x00B7)
    if mode:
        rows['对焦模式'] = mode
    if isinstance(preset, bytes) and preset[:2] in (b'01', b'02', b'03'):
        offset = 8 if preset[:2] == b'03' else 4
        if len(preset) >= offset+40:
            name = text(preset[offset:offset+20])
            base = text(preset[offset+20:offset+40])
            if name:
                rows['色彩预设'] = name
                if base and base.casefold() != name.casefold():
                    rows['基础预设'] = base
    if isinstance(af, bytes):
        fields = {b'0300': 42, b'0301': 42, b'0400': 62, b'0401': 62, b'0402': 62}
        offset = fields.get(af[:4])
        if offset and len(af) > 74 and offset == 62:
            if area := AREA_MODES.get(af[5]):
                rows['对焦区域'] = area
            if af[74] in (0, 1):
                rows['合焦记录'] = '已合焦' if af[74] else '未合焦'
        if offset and len(af) >= 8 and af[7] == 1 and (coords := tiff.unpack('6H', af, offset)):
            result.focus = orient_focus(coords, orientation)
    info, serial, shutter, lens = (value(tag) for tag in (0x0056, 0x001D, 0x00A7, 0x0098))
    if serial and isinstance(shutter, int):
        if isinstance(info, bytes) and (burst := tiff.unpack('2I', info, 4)):
            start, frame = burst
            if start & 0x0007FFE0 and 0 < frame <= shutter:
                result.burst = (serial, start, shutter-frame)
        if isinstance(lens, bytes) and isinstance(serial, str) and serial.isascii() and serial.isdigit():
            distance = lens_distance(lens, int(serial), shutter)
            if distance is not None:
                rows['对焦距离'] = '∞（无穷远）' if not isfinite(distance) else f'约 {distance:.2f} m'


def orient_focus(coords, orientation):
    w, h, x, y, aw, ah = coords
    if not (w and h and (x or y) and x <= w and y <= h and 1 <= orientation <= 8):
        return None
    u, v = x/w, y/h
    x, y = ((u,v), (1-u,v), (1-u,1-v), (u,1-v), (v,u), (1-v,u), (1-v,1-u), (v,1-u))[orientation-1]
    box = (aw/w, ah/h) if 0 < aw <= w and 0 < ah <= h else (0, 0)
    return (x, y, *box[::-1], h/w) if orientation >= 5 else (x, y, *box, w/h)


def lens_distance(lens, serial, shutter):
    if len(lens) < 0x50 or lens[:4] not in (b'0800', b'0801', b'0802'):
        return None
    data = bytearray(lens[:0x59])
    key = (shutter ^ (shutter >> 8) ^ (shutter >> 16) ^ (shutter >> 24)) & 255
    multiplier = LENS_TABLE[serial & 255]
    stream = LENS_TABLE[256+key]
    for offset in range(4, len(data)):
        stream = (stream+multiplier*(0x60+offset-4)) & 255
        data[offset] ^= stream
    lens_id = int.from_bytes(data[0x30:0x32], 'little')
    code = int.from_bytes(data[0x4e:0x50], 'little')
    if lens_id and code:
        if len(data) > 0x58 and not data[0x58]:
            return float('inf')
        return 2**((code/256-80)/12)
    return None


@lru_cache(maxsize=4096)
def cached_metadata(path, modified, size):
    return read_metadata(path)


def metadata(path):
    try:
        stat = Path(path).stat()
    except OSError:
        return Metadata({})
    return cached_metadata(path, stat.st_mtime_ns, stat.st_size)


def is_raw(path):
    return Path(path).suffix.lower() not in JPEG_EXT


def to_qimage(image):
    image = image.convert('RGB')
    return QImage(image.tobytes(), image.width, image.height, image.width*3, QImage.Format.Format_RGB888).copy()


def decode_nikon_he(path, thumbnail=False):
    """Render the original NEF data using the optional HE-capable LibRaw helper."""
    default = Path(__file__).resolve().parents[1] / 'rawcodec' / 'zfilter-raw.exe'
    helper = Path(os.environ.get('ZFILTER_RAW_CODEC', default)).resolve()
    if not helper.is_file():
        raise RuntimeError('此 NEF 编码需要 ZFilter 的 HE 解码组件。')
    with TemporaryDirectory(prefix='zfilter-raw-') as directory:
        folder = Path(directory)
        # Pass ASCII basenames to the decoder even when the user path is Unicode.
        shutil.copyfile(path, folder/'source.NEF')
        argv = [str(helper),'source.NEF','decoded.tiff']
        if thumbnail:
            argv.append('half')
        result = subprocess.run(argv,cwd=folder,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                timeout=90,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        decoded = folder/'decoded.tiff'
        if result.returncode or not decoded.is_file():
            message = result.stderr.decode('utf-8',errors='replace').strip() or f'解码器退出码 0x{result.returncode & 0xffffffff:08x}'
            raise RuntimeError('无法显影此 NEF。'+(f' {message[-280:]}' if message else ''))
        with Image.open(decoded) as image:
            return image.convert('RGB')


def load_pixels(path, thumbnail=False):
    if is_raw(path):
        import rawpy
        try:
            # Opening a Python stream preserves Unicode Windows paths with all LibRaw builds.
            with open(path, 'rb') as stream, rawpy.imread(stream) as raw:
                if thumbnail:
                    try:
                        preview = raw.extract_thumb()
                        if preview.format == rawpy.ThumbFormat.JPEG:
                            return ImageOps.exif_transpose(Image.open(BytesIO(preview.data))).convert('RGB')
                        return Image.fromarray(preview.data).convert('RGB')
                    except (rawpy.LibRawError, OSError):
                        pass
                return Image.fromarray(raw.postprocess(use_camera_wb=True, half_size=thumbnail,
                                                       output_color=rawpy.ColorSpace.sRGB, output_bps=8))
        except (rawpy.LibRawFileUnsupportedError, rawpy.LibRawNotImplementedError):
            if Path(path).suffix.casefold() != '.nef':
                raise
            return decode_nikon_he(path,thumbnail)
    with Image.open(path) as jpeg:
        if thumbnail:
            jpeg.draft('RGB', (320, 320))
        image = ImageOps.exif_transpose(jpeg)
        icc = image.info.get('icc_profile')
        if icc:
            from PIL import ImageCms
            try:
                return ImageCms.profileToProfile(image, BytesIO(icc), ImageCms.createProfile('sRGB'), outputMode='RGB')
            except (ImageCms.PyCMSError, OSError, ValueError):
                pass
        return image.convert('RGB')


def thumbnail(path):
    image = load_pixels(path, thumbnail=True)
    image.thumbnail((320, 220), Image.Resampling.BILINEAR)
    return to_qimage(image)


@dataclass
class Frame:
    image: QImage
    blur: QImage
    histogram: list
    metadata: Metadata


def load_frame(path, companion=None):
    image = load_pixels(path)
    sample = image.copy()
    sample.thumbnail((512, 512), Image.Resampling.BILINEAR)
    rgb = np.asarray(sample)
    luma = (rgb.astype('uint32') @ np.array([2126, 7152, 722], dtype='uint32')+5000)//10000
    histogram = [np.bincount(rgb[:,:,i].ravel(), minlength=256).tolist() for i in range(3)]
    histogram.append(np.bincount(luma.ravel(), minlength=256).tolist())
    sample.thumbnail((140, 140), Image.Resampling.BILINEAR)
    blur = to_qimage(sample.filter(ImageFilter.GaussianBlur(12)))
    info = metadata(path)
    rows, point = dict(info.rows), info.focus
    if companion:
        fallback = metadata(companion)
        for key in ('对焦距离','对焦模式','对焦区域','合焦记录','色彩预设','基础预设'):
            if key not in rows and key in fallback.rows:
                rows[key] = fallback.rows[key]
        if point is None and fallback.focus and abs(fallback.focus[-1] - image.width/image.height) < 0.025:
            point = fallback.focus
    rows['分辨率'] = f'{image.width} × {image.height}'
    return Frame(to_qimage(image), blur, histogram, Metadata(rows, point, info.burst))


# Nikon LensData lookup bytes, as used in GUI/NikonLensDistance.swift.
LENS_TABLE = bytes.fromhex("""
c1 bf 6d 0d 59 c5 13 9d 83 61 6b 4f c7 7f 3d 3d 53 59 e3 c7 e9 2f 95 a7 95 1f df 7f 2b 29 c7 0d
df 07 ef 71 89 3d 13 3d 3b 13 fb 0d 89 c1 65 1f b3 0d 6b 29 e3 fb ef a3 6b 47 7f 95 35 a7 47 4f
c7 f1 59 95 35 11 29 61 f1 3d b3 2b 0d 43 89 c1 9d 9d 89 65 f1 e9 df bf 3d 7f 53 97 e5 e9 95 17
1d 3d 8b fb c7 e3 67 a7 07 f1 71 a7 53 b5 29 89 e5 2b a7 17 29 e9 4f c5 65 6d 6b ef 0d 89 49 2f
b3 43 53 65 1d 49 a3 13 89 59 ef 6b ef 65 1d 0b 59 13 e3 4f 9d b3 29 43 2b 07 1d 95 59 59 47 fb
e5 e9 61 47 2f 35 7f 17 7f ef 7f 95 95 71 d3 a3 0b 71 a3 ad 0b 3b b5 fb a3 bf 4f 83 1d ad e9 2f
71 65 a3 e5 07 35 3d 0d b5 e9 e5 47 3b 9d ef 35 a3 bf b3 df 53 d3 97 53 49 71 07 35 61 71 2f 43
2f 11 df 17 97 fb 95 3b 7f 6b d3 25 bf ad c7 c5 c5 b5 8b ef 2f d3 07 6b 25 49 95 25 49 6d 71 c7
a7 bc c9 ad 91 df 85 e5 d4 78 d5 17 46 7c 29 4c 4d 03 e9 25 68 11 86 b3 bd f7 6f 61 22 a2 26 34
2a be 1e 46 14 68 9d 44 18 c2 40 f4 7e 5f 1b ad 0b 94 b6 67 b4 0b e1 ea 95 9c 66 dc e7 5d 6c 05
da d5 df 7a ef f6 db 1f 82 4c c0 68 47 a1 bd ee 39 50 56 4a dd df a5 f8 c6 da ca 90 ca 01 42 9d
8b 0c 73 43 75 05 94 de 24 b3 80 34 e5 2c dc 9b 3f ca 33 45 d0 db 5f f5 52 c3 21 da e2 22 72 6b
3e d0 5b a8 87 8c 06 5d 0f dd 09 19 93 d0 b9 fc 8b 0f 84 60 33 1c 9b 45 f1 f0 a3 94 3a 12 77 33
4d 44 78 28 3c 9e fd 65 57 16 94 6b fb 59 d0 c8 22 36 db d2 63 98 43 a1 04 87 86 f7 a6 26 bb d6
59 4d bf 6a 2e aa 2b ef e6 78 b6 4e e0 2f dc 7c be 57 19 32 7e 2a d0 b8 ba 29 00 3c 52 7d a8 49
3b 2d eb 25 49 fa a3 aa 39 a7 c5 a7 50 11 36 fb c6 67 4a f5 a5 12 65 7e b0 df af 4e b3 61 7f 2f
""")
