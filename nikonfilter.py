#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
NIKONFILTER - 纯 CLI 版（交互向导 + 预检查确认 + 进度条 + JSON 日志 + 撤销）

核心能力：
1) 模式
   - normal = 1+2+3+4
   - red    = 1+2+3+5（RAW 视频 .nev 直接进 G10RED/r3d 并改为 .r3d，不落 NRAW）
   - travel = 二级选项，JPG/RAW 照片按 EXIF 日期进入日期子文件夹
2) 执行前预检查（统计并确认）
3) CLI 进度条
4) 每次正式执行写 JSON 日志
5) 撤销上次执行（基于日志倒序回滚）

使用示例：
  nikonfilter
  nikonfilter run --folder /path/to/A001 --mode red --travel --confirm
  nikonfilter run --folder /path/to/A001 --mode custom --rules 1,2,3,5
  nikonfilter preview --folder /path/to/A001 --mode normal
  nikonfilter undo --folder /path/to/A001
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

try:
    import termios
    import tty
except ImportError:
    termios = None
    tty = None

# -----------------------------
# 扩展名定义（可按需扩展）
# -----------------------------
JPEG_EXT: Set[str] = {".jpg", ".jpeg"}
RAW_PHOTO_EXT: Set[str] = {
    ".nef",
    ".nrw",
    ".raw",
    ".dng",
    ".arw",
    ".cr2",
    ".cr3",
    ".raf",
    ".orf",
    ".rw2",
}
VIDEO_CONTAINER_EXT: Set[str] = {
    ".mov",
    ".mp4",
    ".m4v",
    ".avi",
    ".mkv",
    ".mts",
    ".m2ts",
}
RAW_VIDEO_EXT: Set[str] = {".nev"}
PROXY_VIDEO_EXT: Set[str] = {".mp4"}

RED_SUFFIX = ".r3d"

MODE_NORMAL = "normal"
MODE_RED = "red"
MODE_CUSTOM = "custom"
MODES = {MODE_NORMAL, MODE_RED, MODE_CUSTOM}

MODE_LABELS = {
    MODE_NORMAL: "普通模式（1+2+3+4）",
    MODE_RED: "RED模式（1+2+3+5，RAW视频直达G10RED/r3d）",
    MODE_CUSTOM: "分条规则（自定义）",
}

ALL_RULES = {"1", "2", "3", "4", "5"}

LOG_DIR_NAME = ".nikonfilter_logs"
LAST_LOG_POINTER = "latest.json"

NIKON_WORD_ART = (
    "     ███╗   ██╗██╗██╗  ██╗ ██████╗ ███╗   ██╗",
    "    ████╗  ██║██║██║ ██╔╝██╔═══██╗████╗  ██║",
    "   ██╔██╗ ██║██║█████╔╝ ██║   ██║██╔██╗ ██║",
    "  ██║╚██╗██║██║██╔═██╗ ██║   ██║██║╚██╗██║",
    " ██║ ╚████║██║██║  ██╗╚██████╔╝██║ ╚████║",
    "╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝",
)
NIKON_Z_MARK = (
    "████████████",
    "        ███ ",
    "      ███   ",
    "    ███     ",
    "  ███       ",
    "████████████",
)
NIKON_LOGO_GAP = "   "
NIKON_WORD_COLOR = "1;3;30"
NIKON_YELLOW = "38;5;220"
NIKON_Z_TAGLINE = "Nikon Z workflow"


# -----------------------------
# 数据结构
# -----------------------------
@dataclass
class ActionResult:
    moved: int = 0
    skipped: int = 0
    errors: int = 0


@dataclass
class UndoResult:
    reverted: int = 0
    skipped: int = 0
    errors: int = 0


class UserExit(Exception):
    pass


@dataclass
class LogEntry:
    action: str  # "move"
    src_before: str  # 原始路径（执行前）
    dst_after: str  # 目标路径（执行后）
    reverted: bool = False
    revert_time: Optional[str] = None
    note: str = ""


@dataclass
class ExecutionLog:
    version: int
    run_id: str
    timestamp: str
    root: str
    mode: str
    mode_label: str
    travel_mode: bool
    rules: List[str]
    dry_run: bool
    preview: Dict[str, int]
    stats: Dict[str, int]
    entries: List[LogEntry] = field(default_factory=list)


# -----------------------------
# 基础工具
# -----------------------------
def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def normalize_ext(path: Path) -> str:
    return path.suffix.lower()


def parse_exif_datetime_value(raw: bytes) -> Optional[str]:
    text = raw.split(b"\x00", 1)[0].decode("ascii", errors="ignore").strip()
    if len(text) < 10:
        return None

    date_part = text[:10]
    if (
        len(date_part) == 10
        and date_part[4] == ":"
        and date_part[7] == ":"
        and date_part[:4].isdigit()
        and date_part[5:7].isdigit()
        and date_part[8:10].isdigit()
    ):
        return f"{date_part[:4]}{date_part[5:7]}{date_part[8:10]}"
    return None


def read_tiff_ascii_tag(
    data: bytes,
    tiff_start: int,
    ifd_offset: int,
    tag_id: int,
    endian: str,
    visited: Optional[Set[int]] = None,
) -> Optional[str]:
    visited = visited or set()
    if ifd_offset in visited:
        return None
    visited.add(ifd_offset)

    ifd_pos = tiff_start + ifd_offset
    if ifd_pos < 0 or ifd_pos + 2 > len(data):
        return None

    try:
        entry_count = struct.unpack_from(f"{endian}H", data, ifd_pos)[0]
    except struct.error:
        return None

    entries_start = ifd_pos + 2
    for idx in range(entry_count):
        pos = entries_start + idx * 12
        if pos + 12 > len(data):
            return None

        try:
            tag, value_type, count = struct.unpack_from(f"{endian}HHI", data, pos)
        except struct.error:
            return None

        value_field = data[pos + 8 : pos + 12]
        if tag == tag_id and value_type == 2 and count > 0:
            if count <= 4:
                raw_value = value_field[:count]
            else:
                try:
                    value_offset = struct.unpack_from(f"{endian}I", data, pos + 8)[0]
                except struct.error:
                    return None
                value_pos = tiff_start + value_offset
                if value_pos < 0 or value_pos + count > len(data):
                    return None
                raw_value = data[value_pos : value_pos + count]
            return parse_exif_datetime_value(raw_value)

    return None


def read_tiff_ifd_pointer(
    data: bytes, tiff_start: int, ifd_offset: int, tag_id: int, endian: str
) -> Optional[int]:
    ifd_pos = tiff_start + ifd_offset
    if ifd_pos < 0 or ifd_pos + 2 > len(data):
        return None

    try:
        entry_count = struct.unpack_from(f"{endian}H", data, ifd_pos)[0]
    except struct.error:
        return None

    entries_start = ifd_pos + 2
    for idx in range(entry_count):
        pos = entries_start + idx * 12
        if pos + 12 > len(data):
            return None

        try:
            tag, value_type, count, value = struct.unpack_from(f"{endian}HHII", data, pos)
        except struct.error:
            return None

        if tag == tag_id and value_type == 4 and count == 1:
            return value
    return None


def parse_tiff_datetime(data: bytes, tiff_start: int = 0) -> Optional[str]:
    if tiff_start < 0 or tiff_start + 8 > len(data):
        return None

    byte_order = data[tiff_start : tiff_start + 2]
    if byte_order == b"II":
        endian = "<"
    elif byte_order == b"MM":
        endian = ">"
    else:
        return None

    try:
        magic = struct.unpack_from(f"{endian}H", data, tiff_start + 2)[0]
        ifd0_offset = struct.unpack_from(f"{endian}I", data, tiff_start + 4)[0]
    except struct.error:
        return None

    if magic != 42:
        return None

    exif_ifd = read_tiff_ifd_pointer(data, tiff_start, ifd0_offset, 0x8769, endian)
    if exif_ifd is not None:
        for tag_id in (0x9003, 0x9004):
            value = read_tiff_ascii_tag(data, tiff_start, exif_ifd, tag_id, endian)
            if value:
                return value

    return read_tiff_ascii_tag(data, tiff_start, ifd0_offset, 0x0132, endian)


def parse_jpeg_exif_datetime(data: bytes) -> Optional[str]:
    if not data.startswith(b"\xff\xd8"):
        return None

    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            pos += 1
            continue

        marker = data[pos + 1]
        pos += 2
        if marker in {0xD8, 0xD9}:
            continue
        if marker == 0xDA:
            break
        if pos + 2 > len(data):
            return None

        segment_len = int.from_bytes(data[pos : pos + 2], "big")
        segment_start = pos + 2
        segment_end = pos + segment_len
        if segment_len < 2 or segment_end > len(data):
            return None

        segment = data[segment_start:segment_end]
        if marker == 0xE1 and segment.startswith(b"Exif\x00\x00"):
            return parse_tiff_datetime(segment, 6)
        pos = segment_end

    return None


def extract_photo_date(path: Path) -> Optional[str]:
    def decode(data: bytes) -> Optional[str]:
        if normalize_ext(path) in JPEG_EXT:
            value = parse_jpeg_exif_datetime(data)
            if value:
                return value
        return parse_tiff_datetime(data)

    try:
        with path.open("rb") as f:
            # Most EXIF is in the first 64 KiB; retain the 1 MiB fallback for large IFDs.
            data = f.read(64 * 1024)
            value = decode(data)
            if value:
                return value
            return decode(data + f.read(1024 * 1024 - len(data)))
    except Exception:
        return None


def is_hidden(path: Path) -> bool:
    return path.name.startswith(".")


def safe_resolve_dir(path_str: str) -> Path:
    p = Path(path_str).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"目录不存在：{p}")
    if not p.is_dir():
        raise NotADirectoryError(f"不是目录：{p}")
    return p


def build_target_dirs(root: Path) -> Dict[str, Path]:
    base = root.name
    return {
        "JPG": root / f"Jpg{base}",
        "RAW": root / f"Raw{base}",
        "NLOG": root / f"NLOG{base}",
        "NRAW": root / f"NRAW{base}",
        "NRAW_NEV": root / f"NRAW{base}" / f"nev{base}",
        "NRAW_AGENT": root / f"NRAW{base}" / f"agent{base}",
        "G10RED": root / f"G10RED{base}",
        "G10RED_R3D": root / f"G10RED{base}" / f"r3d{base}",
        "G10RED_AGENT": root / f"G10RED{base}" / f"agent{base}",
        "G10RED_RED265": root / f"G10RED{base}" / f"red265{base}",
    }


def ensure_dir(path: Path, dry_run: bool = False) -> None:
    if not dry_run:
        path.mkdir(parents=True, exist_ok=True)


def unique_destination(dest_dir: Path, filename: str) -> Path:
    candidate = dest_dir / filename
    if not candidate.exists():
        return candidate

    stem = candidate.stem
    suffix = candidate.suffix
    idx = 1
    while True:
        nxt = dest_dir / f"{stem}_{idx}{suffix}"
        if not nxt.exists():
            return nxt
        idx += 1


def classify_file(path: Path) -> str:
    ext = normalize_ext(path)
    if ext in JPEG_EXT:
        return "J"
    if ext in RAW_PHOTO_EXT:
        return "R"
    if ext in VIDEO_CONTAINER_EXT:
        return "NLOG"
    if ext in RAW_VIDEO_EXT:
        return "NRAW"
    return "OTHER"


def is_shadow_directory(path: Path) -> bool:
    # These are the generated D-prefixed category names, not arbitrary words
    # such as Drawings that happen to start with the same lowercase letters.
    return path.name.startswith(("DJpg", "DRaw", "DJpeg", "DJPEG"))


def iter_files_recursive(root: Path, excluded_dirs: Set[Path], include_shadow: bool = True) -> Iterable[Path]:
    def scan_error(error):
        raise error

    for current_root, dirs, files in os.walk(root, onerror=scan_error):
        cur = Path(current_root)

        pruned: List[str] = []
        for d in dirs:
            dpath = cur / d
            if not include_shadow and is_shadow_directory(dpath):
                continue
            if is_hidden(dpath):
                continue
            if any(dpath == ex or ex in dpath.parents for ex in excluded_dirs):
                continue
            pruned.append(d)
        dirs[:] = pruned

        for f in files:
            fp = cur / f
            if is_hidden(fp) or fp.is_symlink():
                continue
            yield fp


def collect_candidates(root: Path) -> List[Path]:
    targets = build_target_dirs(root)

    def photo_location(parent: Path, category: Path) -> bool:
        if parent == category:
            return True
        return (parent.parent == category and len(parent.name) == 8 + len(category.name)
                and parent.name[:8].isdigit() and parent.name[8:] == category.name)

    def already_placed(path: Path) -> bool:
        kind = classify_file(path)
        if kind == "J":
            return photo_location(path.parent, targets["JPG"]) or path.parent == root / ("J" + root.name)
        if kind == "R":
            return photo_location(path.parent, targets["RAW"]) or path.parent == root / ("R" + root.name)
        if kind == "NLOG":
            return path.parent == targets["NLOG"] or (path.suffix.lower() == ".mp4" and path.parent in {targets["NRAW_AGENT"], targets["G10RED_AGENT"]})
        if kind == "NRAW":
            return path.parent == targets["NRAW_NEV"]
        return path.suffix.lower() == RED_SUFFIX and path.parent == targets["G10RED_R3D"]

    # Scan every depth. A category folder name alone cannot prove that everything
    # below it is correctly organized (e.g. RAW accidentally inside a JPG folder).
    return [path for path in iter_files_recursive(root, set(), include_shadow=False)
            if not already_placed(path)]


def collect_raw_video_stems(files: Iterable[Path]) -> Set[str]:
    return {f.stem for f in files if normalize_ext(f) in RAW_VIDEO_EXT}


def is_raw_video_proxy(path: Path, raw_video_stems: Set[str]) -> bool:
    return normalize_ext(path) in PROXY_VIDEO_EXT and path.stem in raw_video_stems


def build_photo_date_map(files: Iterable[Path], travel_mode: bool) -> Dict[Path, str]:
    if not travel_mode:
        return {}

    dates: Dict[Path, str] = {}
    for f in files:
        if classify_file(f) in {"J", "R"}:
            date_value = extract_photo_date(f)
            if date_value:
                dates[f] = date_value
    return dates


def dated_photo_dir(base_dir: Path, date_value: str) -> Path:
    return base_dir / f"{date_value}{base_dir.name}"


def resolve_effective_rules(mode: str, selected_rules: Set[str]) -> Set[str]:
    if mode == MODE_NORMAL:
        return {"1", "2", "3", "4"}
    if mode == MODE_RED:
        return {"1", "2", "3", "5"}
    return set(selected_rules)


# -----------------------------
# 预检查
# -----------------------------
def preview_scan(root: Path, rules: Set[str], travel_mode: bool = False) -> Dict[str, int]:
    files = collect_candidates(root)
    raw_video_stems = collect_raw_video_stems(files)
    photo_dates = build_photo_date_map(files, travel_mode)
    counts = {
        "total_scanned": len(files),
        "jpg": 0,
        "nef": 0,
        "raw_photos": 0,
        "video_total": 0,
        "mov_mp4": 0,
        "nev": 0,
        "proxy_mp4": 0,
        "travel_jpg_dated": 0,
        "travel_jpg_undated": 0,
        "travel_raw_dated": 0,
        "travel_raw_undated": 0,
        "travel_date_folders": 0,
        "unsupported": 0,
        "will_rule1_jpg": 0,
        "will_rule2_raw": 0,
        "will_rule3_nlog": 0,
        "will_rule4_nev": 0,
        "will_rule4_agent": 0,
        "will_rule5_r3d": 0,
        "will_rule5_agent": 0,
        "will_skip_by_rule": 0,
    }

    for f in files:
        ext = normalize_ext(f)
        kind = classify_file(f)
        is_proxy = is_raw_video_proxy(f, raw_video_stems)
        if kind == "R":
            counts["raw_photos"] += 1
        if kind == "NLOG":
            counts["video_total"] += 1

        if ext in {".jpg", ".jpeg"}:
            counts["jpg"] += 1
        elif ext == ".nef":
            counts["nef"] += 1
        elif ext in {".mov", ".mp4"}:
            counts["mov_mp4"] += 1
        elif ext == ".nev":
            counts["nev"] += 1

        if is_proxy:
            counts["proxy_mp4"] += 1

        if kind == "OTHER":
            counts["unsupported"] += 1
            continue

        if kind == "J":
            counts["will_rule1_jpg"] += 1 if "1" in rules else 0
            counts["will_skip_by_rule"] += 0 if "1" in rules else 1
            if travel_mode and "1" in rules:
                if f in photo_dates:
                    counts["travel_jpg_dated"] += 1
                else:
                    counts["travel_jpg_undated"] += 1
            continue

        if kind == "R":
            counts["will_rule2_raw"] += 1 if "2" in rules else 0
            counts["will_skip_by_rule"] += 0 if "2" in rules else 1
            if travel_mode and "2" in rules:
                if f in photo_dates:
                    counts["travel_raw_dated"] += 1
                else:
                    counts["travel_raw_undated"] += 1
            continue

        if kind == "NLOG":
            if is_proxy:
                if "5" in rules:
                    counts["will_rule5_agent"] += 1
                elif "4" in rules:
                    counts["will_rule4_agent"] += 1
                elif "3" in rules:
                    counts["will_rule3_nlog"] += 1
                else:
                    counts["will_skip_by_rule"] += 1
                continue

            counts["will_rule3_nlog"] += 1 if "3" in rules else 0
            counts["will_skip_by_rule"] += 0 if "3" in rules else 1
            continue

        if kind == "NRAW":
            if "5" in rules:
                counts["will_rule5_r3d"] += 1
            elif "4" in rules:
                counts["will_rule4_nev"] += 1
            else:
                counts["will_skip_by_rule"] += 1
            continue

    if travel_mode:
        counts["travel_date_folders"] = len(set(photo_dates.values()))

    return counts


# -----------------------------
# 日志管理
# -----------------------------
def get_log_dir(root: Path) -> Path:
    return root / LOG_DIR_NAME


def save_execution_log(root: Path, log: ExecutionLog) -> Path:
    log_dir = get_log_dir(root)
    log_dir.mkdir(parents=True, exist_ok=True)

    log_path = log_dir / f"{log.run_id}.json"
    with log_path.open("w", encoding="utf-8") as f:
        json.dump(asdict(log), f, ensure_ascii=False, indent=2)

    pointer = log_dir / LAST_LOG_POINTER
    if not log.entries and pointer.exists():
        return log_path
    with pointer.open("w", encoding="utf-8") as f:
        json.dump(
            {"latest": log_path.name, "updated_at": now_iso()},
            f,
            ensure_ascii=False,
            indent=2,
        )
    return log_path


def load_last_log(root: Path) -> Optional[Tuple[Path, ExecutionLog]]:
    pointer = get_log_dir(root) / LAST_LOG_POINTER
    if not pointer.exists():
        return None

    try:
        with pointer.open("r", encoding="utf-8") as f:
            p = json.load(f)
        name = p.get("latest")
        if not name:
            return None

        log_path = get_log_dir(root) / name
        if not log_path.exists():
            return None

        with log_path.open("r", encoding="utf-8") as f:
            raw = json.load(f)

        entries = [LogEntry(**e) for e in raw.get("entries", [])]
        log = ExecutionLog(
            version=raw.get("version", 1),
            run_id=raw.get("run_id", ""),
            timestamp=raw.get("timestamp", ""),
            root=raw.get("root", ""),
            mode=raw.get("mode", ""),
            mode_label=raw.get("mode_label", ""),
            travel_mode=raw.get("travel_mode", False),
            rules=raw.get("rules", []),
            dry_run=raw.get("dry_run", False),
            preview=raw.get("preview", {}),
            stats=raw.get("stats", {}),
            entries=entries,
        )
        return log_path, log
    except Exception:
        return None


def update_log_file(path: Path, log: ExecutionLog) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(asdict(log), f, ensure_ascii=False, indent=2)


# -----------------------------
# 终端交互工具
# -----------------------------
def supports_ansi() -> bool:
    return sys.stdout.isatty()


def c(text: str, code: str) -> str:
    if not supports_ansi():
        return text
    return f"\033[{code}m{text}\033[0m"


def animation_disabled() -> bool:
    value = os.environ.get("NIKONFILTER_NO_ANIMATION", "").strip().lower()
    return value in {"1", "true", "yes", "on"}


def nikon_z_logo_width() -> int:
    return (
        max(len(line) for line in NIKON_WORD_ART)
        + len(NIKON_LOGO_GAP)
        + max(len(line) for line in NIKON_Z_MARK)
    )


def print_nikon_z_frame(word_step: int, z_step: int) -> None:
    word_width = max(len(line) for line in NIKON_WORD_ART)
    z_width = max(len(line) for line in NIKON_Z_MARK)
    z_color = f"1;{NIKON_YELLOW}"

    for word_line, z_line in zip(NIKON_WORD_ART, NIKON_Z_MARK):
        word_visible = word_line[:word_step].ljust(word_width)
        z_visible = z_line[:z_step].ljust(z_width)
        sys.stdout.write(
            c(word_visible, NIKON_WORD_COLOR)
            + NIKON_LOGO_GAP
            + c(z_visible, z_color)
            + "\n"
        )


def print_nikon_z_static() -> None:
    columns = shutil.get_terminal_size((80, 24)).columns
    logo_width = nikon_z_logo_width()
    if columns < logo_width:
        print(c("Nikon ", NIKON_WORD_COLOR) + c("Z", f"1;{NIKON_YELLOW}"))
        return

    print_nikon_z_frame(
        max(len(line) for line in NIKON_WORD_ART),
        max(len(line) for line in NIKON_Z_MARK),
    )
    print(c(f"  {NIKON_Z_TAGLINE}", "2;37"))


def print_nikon_z_animation() -> None:
    if not supports_ansi():
        return
    if animation_disabled():
        print_nikon_z_static()
        return

    columns = shutil.get_terminal_size((80, 24)).columns
    logo_width = nikon_z_logo_width()
    if columns < logo_width:
        print_nikon_z_static()
        return

    rows = len(NIKON_WORD_ART)
    word_width = max(len(line) for line in NIKON_WORD_ART)
    z_width = max(len(line) for line in NIKON_Z_MARK)
    total_frames = (word_width + z_width + 5) // 5

    for frame in range(total_frames + 1):
        word_step = min(frame * 5, word_width)
        z_step = max(0, min((frame * 5) - word_width, z_width))
        print_nikon_z_frame(word_step, z_step)
        sys.stdout.flush()

        if frame < total_frames:
            time.sleep(0.02)
            sys.stdout.write(f"\033[{rows}F")

    print(c(f"  {NIKON_Z_TAGLINE}", "2;37"))


def prompt_input(prompt: str) -> str:
    if not sys.stdin.isatty() or termios is None or tty is None:
        return input(prompt)

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    chars: List[str] = []

    sys.stdout.write(prompt)
    sys.stdout.flush()
    try:
        tty.setraw(fd)
        while True:
            ch = sys.stdin.read(1)
            if ch == "\x1b":
                raise UserExit
            if ch in {"\r", "\n"}:
                sys.stdout.write("\n")
                sys.stdout.flush()
                return "".join(chars)
            if ch == "\x03":
                raise KeyboardInterrupt
            if ch in {"\x7f", "\b"}:
                if chars:
                    chars.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
                continue
            if ch == "\x15":
                while chars:
                    chars.pop()
                    sys.stdout.write("\b \b")
                sys.stdout.flush()
                continue
            if ch.isprintable():
                chars.append(ch)
                sys.stdout.write(ch)
                sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def banner() -> None:
    print(c("NIKONFILTER", "1;36"))
    print_nikon_z_animation()
    print("纯 CLI 相册整理工具")
    print("-" * 72)


def print_kv(key: str, value: str) -> None:
    print(f"{key:<16}: {value}")


def print_preview(
    pre: Dict[str, int],
    rules: Set[str],
    mode: str,
    root: Path,
    dry_run: bool,
    travel_mode: bool = False,
) -> None:
    print(c("\n[执行前预检查]", "1;33"))
    print_kv("目录", str(root))
    print_kv("模式", MODE_LABELS.get(mode, mode))
    print_kv("旅行模式", "开启" if travel_mode else "关闭")
    print_kv("规则", str(sorted(rules)))
    print_kv("演练模式", str(dry_run))
    print("-" * 72)
    print_kv("扫描总数", str(pre["total_scanned"]))
    print_kv("JPG/JPEG", str(pre["jpg"]))
    print_kv("NEF", str(pre["nef"]))
    print_kv("MOV/MP4", str(pre["mov_mp4"]))
    print_kv("NEV", str(pre["nev"]))
    print_kv("代理MP4", str(pre["proxy_mp4"]))
    print_kv("不支持文件", str(pre["unsupported"]))
    print("-" * 72)
    print_kv("规则1(Jpg)", str(pre["will_rule1_jpg"]))
    print_kv("规则2(Raw)", str(pre["will_rule2_raw"]))
    print_kv("规则3(NLOG)", str(pre["will_rule3_nlog"]))
    print_kv("规则4(nev)", str(pre["will_rule4_nev"]))
    print_kv("规则4(agent)", str(pre["will_rule4_agent"]))
    print_kv("规则5(r3d)", str(pre["will_rule5_r3d"]))
    print_kv("规则5(agent)", str(pre["will_rule5_agent"]))
    print_kv("规则跳过", str(pre["will_skip_by_rule"]))
    if travel_mode:
        print("-" * 72)
        print_kv("日期文件夹", str(pre["travel_date_folders"]))
        print_kv("JPG有日期", str(pre["travel_jpg_dated"]))
        print_kv("JPG无日期", str(pre["travel_jpg_undated"]))
        print_kv("RAW有日期", str(pre["travel_raw_dated"]))
        print_kv("RAW无日期", str(pre["travel_raw_undated"]))
    print("-" * 72)


def print_scan_summary(root: Path, pre: Dict[str, int]) -> None:
    print(c("\n[文件扫描结果]", "1;33"))
    print_kv("目录", str(root))
    print("-" * 72)
    print_kv("扫描总数", str(pre["total_scanned"]))
    print_kv("JPG/JPEG", str(pre["jpg"]))
    print_kv("NEF", str(pre["nef"]))
    print_kv("MOV/MP4", str(pre["mov_mp4"]))
    print_kv("NEV", str(pre["nev"]))
    print_kv("代理MP4", str(pre["proxy_mp4"]))
    print_kv("不支持文件", str(pre["unsupported"]))
    print("-" * 72)


def confirm(prompt: str, default_no: bool = True) -> bool:
    hint = "[y/N]" if default_no else "[Y/n]"
    while True:
        s = prompt_input(f"{prompt} {hint} ").strip().lower()
        if not s:
            return not default_no
        if s in {"y", "yes"}:
            return True
        if s in {"n", "no"}:
            return False
        print("请输入 y 或 n。")


def progress_line(current: int, total: int, text: str = "") -> None:
    total_safe = max(total, 1)
    percent = int(current * 100 / total_safe)
    width = 32
    done = int(width * percent / 100)
    bar = "█" * done + "░" * (width - done)
    msg = f"\r[{bar}] {percent:3d}% ({current}/{total}) {text[:40]}"
    sys.stdout.write(msg)
    sys.stdout.flush()
    if current >= total:
        sys.stdout.write("\n")
        sys.stdout.flush()


# -----------------------------
# 执行与回滚
# -----------------------------
def move_file_and_record(
    src: Path,
    dest_dir: Path,
    dry_run: bool,
    entries: List[LogEntry],
    new_name: Optional[str] = None,
) -> Tuple[bool, str]:
    try:
        ensure_dir(dest_dir, dry_run=dry_run)
        final_name = new_name if new_name else src.name
        dest = unique_destination(dest_dir, final_name)

        if dry_run:
            return True, f"[DRY-RUN] MOVE {src} -> {dest}"

        shutil.move(str(src), str(dest))
        entries.append(
            LogEntry(
                action="move",
                src_before=str(src),
                dst_after=str(dest),
                note="",
            )
        )
        return True, f"MOVE {src} -> {dest}"
    except Exception as e:
        return False, f"ERROR moving {src}: {e}"


def ensure_red_reserved_dirs(
    targets: Dict[str, Path],
    rules: Set[str],
    candidates: Iterable[Path],
    dry_run: bool,
) -> None:
    has_raw_video = any(classify_file(f) == "NRAW" for f in candidates)
    if "5" in rules and has_raw_video:
        for key in ("G10RED_R3D", "G10RED_AGENT", "G10RED_RED265"):
            ensure_dir(targets[key], dry_run=dry_run)


def organize_folder(
    root: Path,
    mode: str,
    selected_rules: Set[str],
    dry_run: bool = False,
    verbose: bool = True,
    travel_mode: bool = False,
    progress_callback=None,
) -> Tuple[ActionResult, Dict[str, int], Optional[Path]]:
    result = ActionResult()
    targets = build_target_dirs(root)
    rules = resolve_effective_rules(mode, selected_rules)
    candidates = collect_candidates(root)
    raw_video_stems = collect_raw_video_stems(candidates)
    photo_dates = build_photo_date_map(candidates, travel_mode)
    total = len(candidates)

    pre = preview_scan(root, rules, travel_mode=travel_mode)
    entries: List[LogEntry] = []

    run_id = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    log_obj = ExecutionLog(
        version=1,
        run_id=run_id,
        timestamp=now_iso(),
        root=str(root),
        mode=mode,
        mode_label=MODE_LABELS.get(mode, mode),
        travel_mode=travel_mode,
        rules=sorted(rules),
        dry_run=dry_run,
        preview=pre,
        stats={},
        entries=entries,
    )

    if verbose:
        progress_line(0, total, "开始...")

    ensure_red_reserved_dirs(targets, rules, candidates, dry_run)

    for idx, f in enumerate(candidates, start=1):
        if progress_callback:
            progress_callback(idx, total, f.name)
        kind = classify_file(f)
        is_proxy = is_raw_video_proxy(f, raw_video_stems)

        if kind == "OTHER":
            result.skipped += 1
            if verbose:
                progress_line(idx, total, f"跳过 {f.name}")
            continue

        if kind == "J":
            if "1" in rules:
                dest_dir = targets["JPG"]
                if travel_mode and f in photo_dates:
                    dest_dir = dated_photo_dir(dest_dir, photo_dates[f])
                ok, _ = move_file_and_record(f, dest_dir, dry_run, entries)
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            else:
                result.skipped += 1
            if verbose:
                progress_line(idx, total, f"J {f.name}")
            continue

        if kind == "R":
            if "2" in rules:
                dest_dir = targets["RAW"]
                if travel_mode and f in photo_dates:
                    dest_dir = dated_photo_dir(dest_dir, photo_dates[f])
                ok, _ = move_file_and_record(f, dest_dir, dry_run, entries)
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            else:
                result.skipped += 1
            if verbose:
                progress_line(idx, total, f"R {f.name}")
            continue

        if kind == "NLOG":
            if is_proxy and "5" in rules:
                ok, _ = move_file_and_record(
                    f, targets["G10RED_AGENT"], dry_run, entries
                )
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            elif is_proxy and "4" in rules:
                ok, _ = move_file_and_record(
                    f, targets["NRAW_AGENT"], dry_run, entries
                )
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            elif "3" in rules:
                ok, _ = move_file_and_record(f, targets["NLOG"], dry_run, entries)
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            else:
                result.skipped += 1
            if verbose:
                progress_line(idx, total, f"NLOG {f.name}")
            continue

        if kind == "NRAW":
            if "5" in rules:
                new_name = f"{f.stem}{RED_SUFFIX}"
                ok, _ = move_file_and_record(
                    f, targets["G10RED_R3D"], dry_run, entries, new_name=new_name
                )
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            elif "4" in rules:
                ok, _ = move_file_and_record(f, targets["NRAW_NEV"], dry_run, entries)
                if ok:
                    result.moved += 1
                else:
                    result.errors += 1
            else:
                result.skipped += 1

            if verbose:
                progress_line(idx, total, f"NRAW {f.name}")
            continue

    if verbose and total == 0:
        progress_line(0, 0, "无可处理文件")

    log_obj.stats = {
        "moved": result.moved,
        "skipped": result.skipped,
        "errors": result.errors,
    }

    log_path: Optional[Path] = None
    if not dry_run:
        log_path = save_execution_log(root, log_obj)

    return result, pre, log_path


def undo_last_execution(root: Path, verbose: bool = True) -> UndoResult:
    loaded = load_last_log(root)
    if not loaded:
        raise FileNotFoundError("未找到上次执行日志，无法撤销。")

    log_path, log_obj = loaded
    entries = log_obj.entries
    total = len(entries)
    result = UndoResult()

    if total == 0:
        return result

    if verbose:
        progress_line(0, total, "开始撤销...")

    for idx, e in enumerate(reversed(entries), start=1):
        if e.reverted:
            result.skipped += 1
            if verbose:
                progress_line(idx, total, f"已撤销过 {Path(e.dst_after).name}")
            continue

        src_now = Path(e.dst_after)
        dst_old = Path(e.src_before)

        if not src_now.exists():
            result.skipped += 1
            if verbose:
                progress_line(idx, total, f"不存在 {src_now.name}")
            continue

        try:
            dst_old.parent.mkdir(parents=True, exist_ok=True)
            restore_target = unique_destination(dst_old.parent, dst_old.name)
            shutil.move(str(src_now), str(restore_target))
            result.reverted += 1

            e.reverted = True
            e.revert_time = now_iso()
            e.note = f"restored_to={restore_target}"

            if verbose:
                progress_line(idx, total, f"撤销 {src_now.name}")
        except Exception:
            result.errors += 1
            if verbose:
                progress_line(idx, total, f"失败 {src_now.name}")

    update_log_file(log_path, log_obj)
    return result


# -----------------------------
# 参数与交互向导
# -----------------------------
def parse_rules_csv(text: str) -> Set[str]:
    s = {x.strip() for x in text.split(",") if x.strip()}
    bad = s - ALL_RULES
    if bad:
        raise ValueError(f"存在非法规则：{sorted(bad)}，仅支持 1~5")
    return s


def ask_mode_interactive() -> str:
    print("\n请选择模式：")
    print("  1：普通模式")
    print("  2：red 模式")
    while True:
        s = prompt_input("输入 1/2（默认 1）: ").strip()
        if s in {"", "1"}:
            return MODE_NORMAL
        if s == "2":
            return MODE_RED
        print("输入无效，请重试。")


def print_mode_brief() -> None:
    print(c("\n[模式说明]", "1;36"))
    print("常规模式")
    print("  1. JPG/JPEG 进入 Jpg 目录")
    print("  2. RAW 照片进入 Raw 目录")
    print("  3. 普通视频进入 NLOG 目录")
    print("  4. NEV 视频进入 NRAW/nev，代理 MP4 进入 NRAW/agent")
    print("")
    print("red 模式")
    print("  1. JPG/JPEG 进入 Jpg 目录")
    print("  2. RAW 照片进入 Raw 目录")
    print("  3. 普通视频进入 NLOG 目录")
    print("  4. NEV 视频改为 R3D 进入 G10RED/r3d，代理 MP4 进入 G10RED/agent")
    print("")
    print("旅行模式")
    print("  在已选定的基础上，按 EXIF 日期把 JPG 和 RAW 分进日期子文件夹。")


def ask_rules_interactive() -> Set[str]:
    print("\n请输入自定义规则（逗号分隔），可选 1,2,3,4,5")
    print("示例：1,2,3,5")
    while True:
        s = prompt_input("规则（默认 1,2,3,4）: ").strip()
        if not s:
            return {"1", "2", "3", "4"}
        try:
            rs = parse_rules_csv(s)
            if not rs:
                print("至少选择一条规则。")
                continue
            return rs
        except Exception as e:
            print(f"规则输入错误：{e}")


def interactive_wizard() -> int:
    banner()
    print(c("交互向导", "1;32"))
    try:
        folder = prompt_input("请输入待整理父目录路径: ").strip()
        if not folder:
            print("未输入目录，退出。")
            return 2

        root = safe_resolve_dir(folder)
        scan_preview = preview_scan(root, resolve_effective_rules(MODE_NORMAL, set()))
        print_scan_summary(root, scan_preview)
        print_mode_brief()
        mode = ask_mode_interactive()
        travel_mode = confirm("是否旅行模式？", default_no=True)
        rules_selected: Set[str] = set()

        effective_rules = resolve_effective_rules(mode, rules_selected)

        dry_run = False
        preview = preview_scan(root, effective_rules, travel_mode=travel_mode)
        print_preview(preview, effective_rules, mode, root, dry_run, travel_mode)

        if not confirm("确认开始执行？", default_no=False):
            print("已取消。")
            return 0

        started = time.time()
        result, _, log_path = organize_folder(
            root=root,
            mode=mode,
            selected_rules=rules_selected,
            dry_run=dry_run,
            verbose=True,
            travel_mode=travel_mode,
        )
        elapsed = time.time() - started

        print(c("\n[执行完成]", "1;32"))
        print_kv("模式", MODE_LABELS.get(mode, mode))
        print_kv("旅行模式", "开启" if travel_mode else "关闭")
        print_kv("规则", str(sorted(effective_rules)))
        print_kv("演练模式", str(dry_run))
        print_kv("已移动/转换", str(result.moved))
        print_kv("跳过", str(result.skipped))
        print_kv("错误", str(result.errors))
        print_kv("耗时(秒)", f"{elapsed:.2f}")
        print_kv("日志", str(log_path) if log_path else "（演练模式未生成）")
        return 0 if result.errors == 0 else 1

    except UserExit:
        print("\n已退出。")
        return 130
    except KeyboardInterrupt:
        print("\n已取消。")
        return 130
    except Exception as e:
        print(f"执行失败：{e}", file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    prog_name = os.environ.get("NIKONFILTER_COMMAND_NAME", "nikonfilter")
    parser = argparse.ArgumentParser(
        prog=prog_name,
        description="NIKONFILTER 纯 CLI 相册整理工具",
    )
    sub = parser.add_subparsers(dest="cmd")

    # run
    p_run = sub.add_parser("run", help="执行整理")
    p_run.add_argument("--folder", required=True, help="待整理父目录")
    p_run.add_argument(
        "--mode", choices=sorted(MODES), default=MODE_NORMAL, help="执行模式"
    )
    p_run.add_argument(
        "--rules", default="", help="自定义规则（仅 custom 有效），如 1,2,3,5"
    )
    p_run.add_argument(
        "--travel",
        action="store_true",
        help="旅行模式：JPG/RAW按EXIF日期进入日期子文件夹",
    )
    p_run.add_argument("--dry-run", action="store_true", help="演练模式（不实际移动）")
    p_run.add_argument("--confirm", action="store_true", help="跳过交互确认，直接执行")
    p_run.add_argument("--quiet", action="store_true", help="减少输出（仍显示摘要）")

    # preview
    p_pre = sub.add_parser("preview", help="仅做预检查统计")
    p_pre.add_argument("--folder", required=True, help="待整理父目录")
    p_pre.add_argument(
        "--mode", choices=sorted(MODES), default=MODE_NORMAL, help="执行模式"
    )
    p_pre.add_argument(
        "--rules", default="", help="自定义规则（仅 custom 有效），如 1,2,3,5"
    )
    p_pre.add_argument(
        "--travel",
        action="store_true",
        help="旅行模式：JPG/RAW按EXIF日期进入日期子文件夹",
    )
    p_pre.add_argument("--dry-run", action="store_true", help="仅用于显示，不影响统计")

    # undo
    p_undo = sub.add_parser("undo", help="撤销上次执行")
    p_undo.add_argument("--folder", required=True, help="待撤销目录（用于定位日志）")
    p_undo.add_argument("--yes", action="store_true", help="跳过确认")
    p_undo.add_argument("--quiet", action="store_true", help="减少输出（仍显示摘要）")

    return parser


def resolve_rules_from_args(mode: str, rules_text: str) -> Set[str]:
    if mode == MODE_CUSTOM:
        if rules_text.strip():
            rs = parse_rules_csv(rules_text.strip())
            if not rs:
                raise ValueError("custom 模式下 rules 不能为空")
            return rs
        return {"1", "2", "3", "4"}
    return set()


def cmd_preview(args: argparse.Namespace) -> int:
    root = safe_resolve_dir(args.folder)
    selected = resolve_rules_from_args(args.mode, args.rules)
    effective = resolve_effective_rules(args.mode, selected)
    pre = preview_scan(root, effective, travel_mode=args.travel)
    print_preview(pre, effective, args.mode, root, args.dry_run, args.travel)
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    root = safe_resolve_dir(args.folder)
    selected = resolve_rules_from_args(args.mode, args.rules)
    effective = resolve_effective_rules(args.mode, selected)

    pre = preview_scan(root, effective, travel_mode=args.travel)
    print_preview(pre, effective, args.mode, root, args.dry_run, args.travel)

    if not args.confirm:
        if not confirm("确认开始执行？", default_no=True):
            print("已取消。")
            return 0

    started = time.time()
    result, _, log_path = organize_folder(
        root=root,
        mode=args.mode,
        selected_rules=selected,
        dry_run=args.dry_run,
        verbose=not args.quiet,
        travel_mode=args.travel,
    )
    elapsed = time.time() - started

    print(c("\n[执行完成]", "1;32"))
    print_kv("模式", MODE_LABELS.get(args.mode, args.mode))
    print_kv("旅行模式", "开启" if args.travel else "关闭")
    print_kv("规则", str(sorted(effective)))
    print_kv("演练模式", str(args.dry_run))
    print_kv("已移动/转换", str(result.moved))
    print_kv("跳过", str(result.skipped))
    print_kv("错误", str(result.errors))
    print_kv("耗时(秒)", f"{elapsed:.2f}")
    print_kv("日志", str(log_path) if log_path else "（演练模式未生成）")
    return 0 if result.errors == 0 else 1


def cmd_undo(args: argparse.Namespace) -> int:
    root = safe_resolve_dir(args.folder)
    loaded = load_last_log(root)
    if not loaded:
        print("未找到上次执行日志，无法撤销。")
        return 1

    _, log = loaded
    if log.dry_run:
        print("上次执行是演练模式（未实际移动），无需撤销。")
        return 0

    if not args.yes:
        print(c("\n[撤销预览]", "1;33"))
        print_kv("run_id", log.run_id)
        print_kv("time", log.timestamp)
        print_kv("mode", log.mode_label)
        print_kv("entries", str(len(log.entries)))
        if not confirm("确认撤销上次执行？", default_no=True):
            print("已取消。")
            return 0

    result = undo_last_execution(root, verbose=not args.quiet)
    print(c("\n[撤销完成]", "1;32"))
    print_kv("已撤销", str(result.reverted))
    print_kv("跳过", str(result.skipped))
    print_kv("错误", str(result.errors))
    return 0 if result.errors == 0 else 1


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    # 未传子命令 -> 进入交互向导（贴近 GUI 体验）
    if not args.cmd:
        return interactive_wizard()

    try:
        if args.cmd == "preview":
            return cmd_preview(args)
        if args.cmd == "run":
            return cmd_run(args)
        if args.cmd == "undo":
            return cmd_undo(args)
        parser.print_help()
        return 2
    except UserExit:
        print("\n已退出。")
        return 130
    except KeyboardInterrupt:
        print("\n已取消。")
        return 130
    except Exception as e:
        print(f"错误：{e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
