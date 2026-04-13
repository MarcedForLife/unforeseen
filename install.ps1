$ErrorActionPreference = "Stop"
$repo = "MarcedForLife/unforeseen"

function Put($msg, $color) {
    if ($color) { Write-Host "  $msg" -ForegroundColor $color }
    else { Write-Host "  $msg" }
}

function Heading($msg) { Write-Host "  $msg" -ForegroundColor DarkYellow }

function Pick-Items($labels, $details) {
    $checked = [bool[]]::new($labels.Count)
    for ($i = 0; $i -lt $labels.Count; $i++) { $checked[$i] = $true }
    $cursor = 0
    $linesPer = if ($details) { 2 } else { 1 }

    function Render {
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $box = if ($checked[$i]) { "[x]" } else { "[ ]" }
            $color = if ($i -eq $cursor) { "DarkYellow" } else { "Gray" }
            $arrow = if ($i -eq $cursor) { ">" } else { " " }
            Write-Host "   $arrow $box $($labels[$i])" -ForegroundColor $color
            if ($details) {
                Write-Host "         $($details[$i])" -ForegroundColor DarkGray
            }
        }
    }

    Render

    $done = $false
    while (-not $done) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow" { if ($cursor -gt 0) { $cursor-- } }
            "DownArrow" { if ($cursor -lt $labels.Count - 1) { $cursor++ } }
            "Spacebar" { $checked[$cursor] = -not $checked[$cursor] }
            "Enter" { $done = $true }
            "Escape" { return @() }
        }
        if (-not $done) {
            [Console]::SetCursorPosition(0, [Console]::CursorTop - ($labels.Count * $linesPer))
            Render
        }
    }

    $selected = @()
    for ($i = 0; $i -lt $labels.Count; $i++) {
        if ($checked[$i]) { $selected += $i }
    }
    return $selected
}

function Get-SteamLibraries {
    $steamDir = "${env:ProgramFiles(x86)}\Steam"
    $vdf = Join-Path $steamDir "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        $paths = (Get-Content $vdf | Select-String '"path"\s+"(.+)"' -AllMatches).Matches |
        ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
        if ($paths) { return $paths }
    }
    return @($steamDir)
}

Write-Host ""
Heading "Unforeseen Achievements"
Write-Host ""

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
Put "version : $($release.tag_name)"

$tmp = Join-Path $env:TEMP "unforeseen"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$asset = $release.assets | Where-Object { $_.name -eq "unforeseen-x86.dll" }
if ($asset) {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile (Join-Path $tmp "unforeseen-x86.dll") -UseBasicParsing
    Put "fetched : unforeseen-x86.dll"
}

$games = @(
    @{ Name = "Half-Life 2 (20th Anniversary)"; Dir = "Half-Life 2\bin" }
    @{ Name = "Portal"; Dir = "Portal\bin" }
    @{ Name = "Portal 2"; Dir = "Portal 2\bin" }
    @{ Name = "Left 4 Dead"; Dir = "Left 4 Dead\bin" }
    @{ Name = "Left 4 Dead 2"; Dir = "Left 4 Dead 2\bin" }
)

$libraries = Get-SteamLibraries
$found = @()
foreach ($game in $games) {
    foreach ($lib in $libraries) {
        $binDir = Join-Path $lib "steamapps\common\$($game.Dir)"
        if (Test-Path $binDir) {
            $found += @{ Name = $game.Name; BinDir = $binDir }
            break
        }
    }
}

if ($found.Count -eq 0) {
    Write-Host ""
    Put "No supported games found." Yellow
    Write-Host ""
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

Write-Host ""
Heading "Select games (Space = toggle, Enter = confirm, Esc = cancel)"
Write-Host ""

$names = $found | ForEach-Object { $_.Name }
$dirs = $found | ForEach-Object { $_.BinDir }
$indices = Pick-Items $names $dirs

Write-Host ""

if ($indices.Count -eq 0) {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

$src = Join-Path $tmp "unforeseen-x86.dll"
$installed = @()
foreach ($idx in $indices) {
    $game = $found[$idx]
    Copy-Item $src (Join-Path $game.BinDir "version.dll") -Force
    $installed += $game.Name
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($installed.Count -gt 0) {
    Put "Installed for:" Green
    foreach ($name in $installed) { Put "  - $name" }
    Write-Host ""
    Put "Achievements should now unlock in commentary mode"
}
Write-Host ""
