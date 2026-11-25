$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$out = Join-Path $PWD 'build/windows-release'
$work = Join-Path $PWD 'build/windows-pyinstaller'
$icon = Join-Path $work 'ZFilter.ico'
$iconPng = (Resolve-Path 'docs/images/zfilter-icon.png').Path
$symbols = (Resolve-Path 'windows/icons').Path
$codec = Join-Path $PWD 'build/windows-codec/Release'
if (-not (Test-Path (Join-Path $codec 'zfilter-raw.exe'))) { & "$PSScriptRoot/build-codec.ps1" }
New-Item -ItemType Directory -Force $work, $out | Out-Null
python -c 'from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2], sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])' $iconPng $icon
if ($LASTEXITCODE) { throw 'ICO generation failed' }

python -m PyInstaller --noconfirm --clean --windowed --onedir --name ZFilter --paths . `
    --specpath $work --workpath $work --distpath $out --icon $icon `
    --add-data "${iconPng}:docs/images" --add-data "${symbols}:windows/icons" --collect-all rawpy `
    --add-binary "$codec/zfilter-raw.exe:rawcodec" `
    --add-data "$codec/LICENSE.LGPL:rawcodec" --add-data "$codec/LICENSE.CDDL:rawcodec" `
    --add-data "$codec/COPYRIGHT:rawcodec" --add-data "$codec/SOURCE.txt:rawcodec" `
    --copy-metadata PySide6-Essentials --copy-metadata shiboken6 --copy-metadata rawpy `
    --copy-metadata pillow --copy-metadata numpy windows/__main__.py
if ($LASTEXITCODE) { throw 'PyInstaller failed' }

Copy-Item docs/windows.md (Join-Path $out 'ZFilter/README-Windows.md')
$zip = Join-Path $out 'ZFilter-Windows-x64-preview.zip'
Compress-Archive -Path (Join-Path $out 'ZFilter') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content (Join-Path $out 'SHA256SUMS.txt') "$hash  ZFilter-Windows-x64-preview.zip" -Encoding ascii
Write-Host "Packaged $zip"
