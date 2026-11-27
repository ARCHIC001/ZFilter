# ZFilter Windows 预览版

Windows 前端与 macOS 应用共用整理、日志、统计和 JPEG／RAW 配对引擎。Windows 界面采用 Qt Widgets 和高斯模糊材质，显示原生标题栏、系统文件夹选择器及深浅色界面。工具栏采用统一的 Fluent 线框图标，展开和折叠侧栏时保留相同的按钮尺寸。 [Microsoft Fluent System Icons](https://github.com/microsoft/fluentui-system-icons)

## 运行预览包

在 Windows 11 x64 上，下载并解压 ZIP，运行 `ZFilter` 文件夹里的 `ZFilter.exe`，保留同目录的 `_internal`。预览包未做代码签名。 [下载 Windows 便携版](https://github.com/ARCHIC001/ZFilter/releases/download/v1.10.1/ZFilter-1.10.1-Windows-x64-preview.zip) · [发布说明与 SHA-256 校验](https://github.com/ARCHIC001/ZFilter/releases/tag/v1.10.1)

## 操作

| 操作 | Windows 快捷键 |
| --- | --- |
| 打开素材父目录、刷新项目 | **Ctrl+O / Ctrl+R** |
| 上一张、下一张 | **← / →** 或 **A / D** |
| 100% 对焦点放大、回到适应窗口 | **0 / O**、**,** |
| 对焦框、EXIF、预览条、连拍折叠 | **F / I / T / B** |
| 暂存到待删池或在待删池中恢复 | **W** |
| 移入 Windows 系统回收站、撤回 | **S / Delete**、**Ctrl+Z** |
| 沉浸、全屏 | **Tab / F11** |

左下角绿、黄、红三个按钮分别控制仅 JPEG、仅 RAW、已配对的 JPEG+RAW。拖动快速定位轨，松手后跳到目标照片。左上角 Logo 切换深浅色。

只选片时，在「素材整理」选择「影子模式」，点击「创建影子待删池并选片」。例如 `旅拍/第一天/相机 A` 会在并列的 `旅拍 - 待删池` 里生成 `第一天/相机 A` 空目录。按 **W** 暂存的文件会进入对应目录，在待删池按 **W** 可恢复到原位。以后可以用「同步影子目录并选片」补齐新建的子目录。

在沉浸选片顶部点击「全部文件夹」打开目录树。选中目录后可浏览该目录及其子目录。正式池与待删池各自记住当前目录，旅行模式生成的日期文件夹也能直接选片。

在待删池界面，点击底部「删除整个待删池」，可在确认框中展开目录清单。确认后，当前项目的全部待删池文件夹及其中内容会移入 Windows 系统回收站，按 **Ctrl+Z** 可整批恢复。

## 和 macOS 版的差异

- Windows 通过 LibRaw 显影 RAW。无损 NEF 用标准 LibRaw，Nikon 高效率 NEF 用打包内的 HE 解码组件。RAW 大图从传感器数据生成。Windows 与 macOS 使用不同的显影引擎，色彩与有效画幅边缘可能有差异。 [LibRaw 相机支持](https://www.libraw.org/supported-cameras) · [HE 解码组件源码](https://github.com/zidage/LibRaw/tree/fca3ee4db0b51f3787534fc370891e93ceb52f59)
- 文件进入 Windows 系统回收站后，可在资源管理器恢复，也可在 ZFilter 按 **Ctrl+Z** 撤回最近一批。磁盘或系统设置不支持回收时，ZFilter 会停止删除并提示。旧版项目内暂存的文件仍可用 **Ctrl+Z** 恢复。
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
