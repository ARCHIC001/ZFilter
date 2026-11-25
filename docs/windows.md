# ZFilter Windows 预览版

Windows 前端与 macOS 应用共用整理、日志、统计和 JPEG／RAW 配对引擎。Windows 界面采用 Qt Widgets 和高斯模糊材质，显示原生标题栏、系统文件夹选择器及深浅色界面。工具栏采用统一的 Fluent 线框图标，展开和折叠侧栏时保留相同的按钮尺寸。 [Microsoft Fluent System Icons](https://github.com/microsoft/fluentui-system-icons)

## 运行预览包

Windows 11 x64 下，从 [测试运行记录](https://github.com/ARCHIC001/ZFilter/actions/workflows/windows-preview.yml?query=branch%3Awindows-preview) 下载 `ZFilter-Windows-x64-preview` 工件，解开外层工件 ZIP 后，再解开便携版 ZIP。运行其中的 `ZFilter.exe`，并保留同目录的 `_internal`。预览包未做代码签名。

## 操作

| 操作 | Windows 快捷键 |
| --- | --- |
| 打开素材父目录、刷新项目 | **Ctrl+O / Ctrl+R** |
| 上一张、下一张 | **← / →** 或 **A / D** |
| 100% 对焦点放大、回到适应窗口 | **0 / O**、**,** |
| 对焦框、EXIF、预览条、连拍折叠 | **F / I / T / B** |
| 暂存到待删池或在待删池中恢复 | **W** |
| 移入 ZFilter 废纸篓、撤回 | **S / Delete**、**Ctrl+Z** |
| 沉浸、全屏 | **Tab / F11** |

左下角绿、黄、红三个按钮分别控制仅 JPEG、仅 RAW、已配对的 JPEG+RAW。拖动快速定位轨，松手后跳到目标照片。左上角 Logo 切换深浅色。

在待删池界面，点击底部「删除整个待删池」，可在确认框中展开目录清单。确认后，当前项目的全部待删池文件夹及其中内容会移入 ZFilter 废纸篓，按 **Ctrl+Z** 可整批恢复。

## 和 macOS 版的差异

- Windows 通过 LibRaw 显影 RAW。无损 NEF 用标准 LibRaw，Nikon 高效率 NEF 用打包内的 HE 解码组件。RAW 大图从传感器数据生成。Windows 与 macOS 使用不同的显影引擎，色彩与有效画幅边缘可能有差异。 [LibRaw 相机支持](https://www.libraw.org/supported-cameras) · [HE 解码组件源码](https://github.com/zidage/LibRaw/tree/fca3ee4db0b51f3787534fc370891e93ceb52f59)
- Windows 预览版的 **S / Delete** 把文件移到项目下隐藏的 `.nikonfilter_logs/recycle`，可用 **Ctrl+Z** 恢复。整个文件仍在原盘，恢复会检查目标是否已存在。Windows 系统回收站由系统单独管理。
- 共享的整理日志和待删池日志记录绝对路径。跨系统或迁移磁盘目录前，建议在原位置完成撤回和恢复。

## 从源码运行和打包

在仓库根目录使用 64 位 Python 3.12。构建包含 HE 解码组件的便携包需要 Git、CMake 和 Visual Studio 2022 的 C++ 桌面开发工具。

```powershell
python -m pip install -r windows/requirements.txt
python -m windows
python -m pip install 'pyinstaller>=6.14,<7'
./windows/build.ps1
```

打包输出位于 `build/windows-release/`。从源码运行时，可先执行 `windows/build-codec.ps1`，再指定 HE 解码组件路径。测试会构造独立目录并验证中文路径、整理、RAW 解码、筛选、待删池和恢复。测试使用本地样本或 [raw.pixls.us](https://raw.pixls.us/) 的公开 Nikon NEF。

```powershell
$env:ZFILTER_RAW_CODEC = (Resolve-Path 'build/windows-codec/Release/zfilter-raw.exe').Path
python -m windows.test_windows --raw C:\素材\Z8-lossless.NEF
```
