$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$out = Join-Path $PWD 'build/windows-release'
$work = Join-Path $PWD 'build/windows-pyinstaller'
$icon = Join-Path $work 'ZFilter.ico'
New-Item -ItemType Directory -Force $work, $out | Out-Null
python -c "from PIL import Image; Image.open('docs/images/zfilter-icon.png').save(r'$icon',sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"
if ($LASTEXITCODE) { throw 'ICO generation failed' }

python -m PyInstaller --noconfirm --clean --windowed --onedir --name ZFilter --paths . `
    --specpath $work --workpath $work --distpath $out --icon $icon `
    --add-data 'docs/images/zfilter-icon.png:docs/images' --collect-all rawpy `
    --copy-metadata PySide6-Essentials --copy-metadata shiboken6 --copy-metadata rawpy `
    --copy-metadata pillow --copy-metadata numpy windows/__main__.py
if ($LASTEXITCODE) { throw 'PyInstaller failed' }

Copy-Item docs/windows.md (Join-Path $out 'ZFilter/README-Windows.md')
$zip = Join-Path $out 'ZFilter-Windows-x64-preview.zip'
Compress-Archive -Path (Join-Path $out 'ZFilter') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content (Join-Path $out 'SHA256SUMS.txt') "$hash  ZFilter-Windows-x64-preview.zip" -Encoding ascii
Write-Host "Packaged $zip"
