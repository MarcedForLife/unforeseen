$ErrorActionPreference = "Stop"
$repo = "MarcedForLife/unforeseen"

Write-Host "Unforeseen Achievements installer" -ForegroundColor Cyan
Write-Host ""

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
$tag = $release.tag_name
Write-Host "  version : $tag"

# Download DLL to temp
$tmp = Join-Path $env:TEMP "unforeseen"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$asset = $release.assets | Where-Object { $_.name -eq "unforeseen-x86.dll" }
if ($asset) {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile (Join-Path $tmp "unforeseen-x86.dll") -UseBasicParsing
    Write-Host "  fetched : unforeseen-x86.dll"
}

# Discover Steam library folders from libraryfolders.vdf
$steamDir = "${env:ProgramFiles(x86)}\Steam"
$vdfPath = Join-Path $steamDir "steamapps\libraryfolders.vdf"
$libraries = @()

if (Test-Path $vdfPath) {
    $libraries = (Get-Content $vdfPath | Select-String '"path"\s+"(.+)"' -AllMatches).Matches |
        ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
}

if ($libraries.Count -eq 0) {
    $libraries = @($steamDir)
}

Write-Host "  libraries: $($libraries -join ', ')"

# Install into detected game directories
$games = @(
    @{ Name = "HL2 / EP1 / EP2 / Lost Coast"; Dir = "Half-Life 2\bin"; Dll = "unforeseen-x86.dll" }
    @{ Name = "Portal 2";                      Dir = "Portal 2\bin";   Dll = "unforeseen-x86.dll" }
)

$installed = @()
foreach ($game in $games) {
    foreach ($lib in $libraries) {
        $binDir = Join-Path $lib "steamapps\common\$($game.Dir)"
        if (Test-Path $binDir) {
            $src = Join-Path $tmp $game.Dll
            if (Test-Path $src) {
                Copy-Item $src (Join-Path $binDir "version.dll") -Force
                $installed += "$($game.Name) ($binDir)"
            }
            break
        }
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($installed.Count -gt 0) {
    Write-Host "  Installed for:" -ForegroundColor Green
    foreach ($entry in $installed) { Write-Host "    - $entry" }
    Write-Host ""
    Write-Host "  Achievements will unlock in commentary mode automatically."
} else {
    Write-Host "  No supported games found." -ForegroundColor Yellow
}
Write-Host ""
