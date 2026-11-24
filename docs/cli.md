# nikonfilter 命令行指南

适用于终端和批处理。GUI 安装与选片请参见 [Filter 使用教程](tutorial.md)。

## 适用场景

一个父文件夹内混有：

- 直出照片（`.jpg` / `.jpeg`）
- RAW 照片（如 `.nef`）
- 普通视频（如 `.mov` / `.mp4`）
- RAW 视频（如 `.nev`）

NIKONFILTER 会递归扫描并整理到标准化子目录。

---

## 规则说明

假设待整理父目录名为 `A001`，将创建 / 使用以下子目录：

1. **规则1：直出照片**
   - 目标目录：`JpgA001`
   - 文件：`.jpg`, `.jpeg`

2. **规则2：RAW 照片**
   - 目标目录：`RawA001`
   - 文件：`.nef`, `.nrw`, `.raw`, `.dng`, `.arw`, `.cr2`, `.cr3`, `.raf`, `.orf`, `.rw2`

旅行模式下，规则1和规则2会先读取照片 EXIF 日期，再进入日期子文件夹：

- JPG/JPEG：`JpgA001/20260520JpgA001/`
- RAW 照片：`RawA001/20260520RawA001/`
- 读不到 EXIF 日期的照片会留在 `JpgA001/` 或 `RawA001/` 根目录

3. **规则3：普通视频**
   - 目标目录：`NLOGA001`
   - 文件：`.mov`, `.mp4`, `.m4v`, `.avi`, `.mkv`, `.mts`, `.m2ts`
   - 说明：若 `.mp4` 与 `.nev` 同名，且规则4或规则5生效，则该 `.mp4` 会被视为 RAW 视频代理文件，优先进入对应 `agent...` 目录

4. **规则4：RAW 视频（普通模式）**
   - 目标目录：`NRAWA001`
   - 内部目录：`nevA001`, `agentA001`
   - `.nev` 视频本体进入：`NRAWA001/nevA001/`
   - 代理文件进入：`NRAWA001/agentA001/`
   - 代理文件识别：`.mp4` 且文件名 stem 与某个 `.nev` 相同

5. **规则5：RED 输出（扩展）**
   - 目标目录：`G10REDA001`
   - 内部目录：`r3dA001`, `agentA001`, `red265A001`
   - `.nev` 视频本体改后缀为 `.r3d` 后进入：`G10REDA001/r3dA001/`
   - 代理文件进入：`G10REDA001/agentA001/`
   - 检测到 `.nev` RAW 视频并走 RED 规则时，三个内部目录会同时出现；`red265A001` 暂时不放文件，供后续转码输出使用

---

## 模式说明

### 1) `normal`（普通模式）
规则：`1 + 2 + 3 + 4`

### 2) `red`（RED 模式）
规则：`1 + 2 + 3 + 5`

> RED 模式下 RAW 视频会直接进入 `G10RED.../r3d...`，不落地 `NRAW...`，避免双份占用存储。

### 3) 旅行模式（二级选项）
旅行模式不是独立规则组，而是在常规模式或 RED 模式之上，对 JPG/JPEG 和 RAW 照片追加日期分桶。

---

## 命令总览

```sh
nikonfilter
nikonfilter run --folder /path/to/A001 --mode red --travel
nikonfilter preview --folder /path/to/A001 --mode normal
nikonfilter undo --folder /path/to/A001
```

---

## 交互向导（最接近 GUI 体验）

直接执行：

```sh
nikonfilter
```

会进入交互式向导流程：

1. 输入目标目录
2. 立即扫描并展示文件种类数量
3. 选择基础模式：直接回车默认普通模式，也可输入 `2` 选择 RED 模式
4. 选择是否启用旅行模式：直接回车默认不启用，输入 `y` 启用
5. 展示带规则影响的执行前预检查
6. 确认执行：直接回车默认开始执行，输入 `n` 取消
7. 实时进度条 + 完成摘要

---

## 子命令详解

## 1) `run` 执行整理

```sh
nikonfilter run --folder /path/to/A001 --mode normal
```

常用参数：

- `--folder`：待整理父目录（必填）
- `--mode`：`normal | red | custom`
- `--rules`：仅 `custom` 使用，例如 `1,2,3,5`
- `--travel`：旅行模式，JPG/RAW 按 EXIF 日期进入日期子文件夹
- `--dry-run`：演练模式（不实际移动）
- `--confirm`：跳过“确认执行”交互，直接执行
- `--quiet`：减少过程输出（仍显示结果摘要）

示例：

```sh
nikonfilter run --folder /Volumes/SSD/DCIM/A001 --mode red
nikonfilter run --folder /Volumes/SSD/DCIM/A001 --mode normal --travel
nikonfilter run --folder /Volumes/SSD/DCIM/A001 --mode custom --rules 1,2,3,5
```

---

## 2) `preview` 仅预检查统计

```sh
nikonfilter preview --folder /path/to/A001 --mode normal
```

用途：

- 先看分类统计，不改动文件
- 便于执行前核对数量和规则影响

统计包含：

- 扫描总数
- JPG/JPEG、NEF、MOV/MP4、NEV、代理 MP4 数量
- 旅行模式下的日期文件夹数量、JPG/RAW 有日期与无日期数量
- 不支持文件数量
- 各规则预计处理数量
- 按规则跳过数量

---

## 3) `undo` 撤销上次执行

```sh
nikonfilter undo --folder /path/to/A001
```

常用参数：

- `--folder`：要撤销的目录（用于定位日志）
- `--yes`：跳过撤销确认
- `--quiet`：减少过程输出

说明：

- 按最近一次日志倒序回滚
- 优先恢复到原路径
- 若路径冲突会自动避免覆盖
- 若文件被手工移动/删除，部分条目会被跳过

---

## 执行前预检查与确认

`run` 在默认情况下会先显示预检查结果并等待确认。
你可以用 `--confirm` 跳过确认，适合批处理脚本。

---

## 进度条与摘要输出

执行和撤销时会在终端显示进度条（百分比、当前/总量）。
完成后输出摘要：

- 已移动/转换
- 跳过
- 错误
- 耗时
- 日志路径（非 dry-run）

---

## JSON 日志与回滚机制

每次**非演练模式**执行后，会在目标目录生成日志：

- 目录：`<目标父目录>/.nikonfilter_logs/`
- 执行日志：`YYYYMMDD_HHMMSS.json`
- 最近指针：`latest.json`

日志记录每个文件迁移前后路径，`undo` 据此回滚。

> 注意：`--dry-run` 不会写入可回滚操作日志。

---

## 全局命令安装（任意目录直接运行）

推荐使用一键安装脚本。

在项目目录执行：

```sh
bash install.sh
```

验证：

```sh
which nikonfilter
nikonfilter --help
```

---

## 安装脚本常用参数

```sh
bash install.sh --dry-run
bash install.sh --prefix ~/.local/bin
bash install.sh --name nikonfilter-cli
bash install.sh --uninstall
```

参数说明：

- `--prefix <dir>`：安装目录（如 `/usr/local/bin` 或 `~/.local/bin`）
- `--name <name>`：命令名（默认 `nikonfilter`）
- `--dry-run`：只打印操作，不实际改动
- `--uninstall`：卸载软链接
- `-h, --help`：查看帮助

---

## 如果命令找不到

通常是 PATH 未生效。
将安装目录加入 shell 配置（例如 `~/.zshrc`）后执行：

```sh
source ~/.zshrc
```

---

## 文件识别默认列表

### 直出照片
- `.jpg`, `.jpeg`

### RAW 照片
- `.nef`, `.nrw`, `.raw`, `.dng`, `.arw`, `.cr2`, `.cr3`, `.raf`, `.orf`, `.rw2`

### 普通视频
- `.mov`, `.mp4`, `.m4v`, `.avi`, `.mkv`, `.mts`, `.m2ts`

### RAW 视频
- `.nev`（规则5/RED 下输出为 `.r3d`）

### RAW 视频代理文件
- `.mp4` 且文件名 stem 与某个 `.nev` 相同
- 例如同一批素材中存在 `A001_C001.nev` 与 `A001_C001.mp4`，后者会被识别为代理文件

---

## 行为细节

- 递归遍历父目录
- 跳过隐藏文件/目录（`.` 开头）
- 自动跳过输出目录，避免重复扫描
- 重名自动追加后缀（如 `_1`, `_2`）避免覆盖
- custom 同时选择规则4和规则5时，RAW 视频及代理文件优先按规则5进入 `G10RED...`
- 旅行模式按 EXIF/TIFF 日期标签分桶，优先读取 `DateTimeOriginal`，其次 `DateTimeDigitized` 和 `DateTime`
- 支持 dry-run 演练
- 非 dry-run 自动记录 JSON 日志用于回滚

---

## 推荐工作流

1. 先执行 `preview` 或 `run --dry-run`
2. 核对统计后正式 `run`
3. 保留日志用于审计与回滚
4. 若结果不满意，执行 `undo`

---

## 项目文件

- 主程序：`nikonfilter.py`
- 启动器：`nikonfilter`
- 安装脚本：`install.sh`
- GUI 文档见 [Filter 使用教程](tutorial.md)。

---

## 许可证

项目当前未声明开源许可证。
