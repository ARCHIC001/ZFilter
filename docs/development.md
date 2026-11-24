# ZFilter 构建与验证

[返回项目介绍](../README.md) · [图文使用教程](tutorial.md)

## 构建和打包

在 Apple Silicon Mac 上安装带 macOS 26 或更新 SDK 的 Xcode 命令行工具，在仓库根目录运行以下命令。

```sh
bash GUI/build.sh
bash GUI/package.sh
```

- `build/ZFilter.app` 是原生应用。也可用 `bash GUI/build.sh --install` 安装到 `~/Applications`。
- `build/dist/` 包含带「Applications」快捷方式的 DMG 和 SHA-256 文件。
- `GUI/DrawIcon.swift` 生成应用图标。应用内包含整理桥接脚本和 CLI 核心，运行时使用 `/usr/bin/python3`。
- 本地构建默认使用 ad-hoc 签名。GitHub 分发包的签名和首次启动步骤见 [图文教程](tutorial.md#安装和首次启动)。

## 回归检查

以下检查会生成临时测试数据，验证目录边界、文件大小、配对和浏览范围。

```sh
python3 GUI/test_scan_scope.py
python3 GUI/test_storage.py
python3 GUI/test_view_scopes.py
```

维护者的 `--self-test` 原生回归另需本地 Nikon 样本，覆盖实际 NEF 解码、对焦、EXIF、连拍、待删池恢复以及选片交互。教程演示使用独立素材副本，验证了 9 个文件的清点、旅行模式演练和整理、待删池恢复、RAW 解码及整理撤销。

## 元数据参考

- RAW 图像由 macOS Core Image 显影，支持的相机格式取决于系统版本。 [Apple CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
- Nikon MakerNotes 的 AFInfo2、LensData、连拍与 Picture Control 字段参考 Phil Harvey 的 ExifTool 文档与实现。 [Nikon 标签表](https://exiftool.org/TagNames/Nikon.html) · [ExifTool Nikon 模块](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Nikon.pm)
- 照片中的 Picture Control 名称和基础预设来自相机记录。名称可以用于核对拍摄预设，配方的来源需要独立验证。 [Nikon Z8 Flexible Color 指南](https://onlinemanual.nikonimglib.com/z8/en/adding_flexible_color_to_picture_control_392.html)
