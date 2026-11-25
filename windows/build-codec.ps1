$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$revision = 'fca3ee4db0b51f3787534fc370891e93ceb52f59'
$source = Join-Path $PWD 'build/LibRaw-nikon-he'
$build = Join-Path $PWD 'build/windows-codec'
if (-not (Test-Path (Join-Path $source '.git'))) {
    git init -q $source
    if ($LASTEXITCODE) { throw 'Could not initialize LibRaw checkout' }
    git -C $source fetch --depth 1 https://github.com/zidage/LibRaw.git $revision
    if ($LASTEXITCODE) { throw 'Could not fetch pinned LibRaw revision' }
    git -C $source checkout --detach FETCH_HEAD
    if ($LASTEXITCODE) { throw 'Could not check out LibRaw' }
}
if ((git -C $source rev-parse HEAD) -ne $revision) { throw 'Unexpected LibRaw source revision' }
cmake -S windows/raw-decoder -B $build -A x64 "-DLIBRAW_SOURCE=$source"
if ($LASTEXITCODE) { throw 'LibRaw configuration failed' }
cmake --build $build --config Release --parallel 4
if ($LASTEXITCODE) { throw 'LibRaw build failed' }
Copy-Item (Join-Path $source 'COPYRIGHT'), (Join-Path $source 'LICENSE.LGPL'), (Join-Path $source 'LICENSE.CDDL') (Join-Path $build 'Release')
Set-Content (Join-Path $build 'Release/SOURCE.txt') "LibRaw source and history: https://github.com/zidage/LibRaw/tree/$revision" -Encoding ascii
