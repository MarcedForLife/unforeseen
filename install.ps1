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

# ----------------------------------------------------------------------------
# DLL proxy generator. Reads a target DLL's export directory, appends an
# .edata section of forwarder entries to the template DLL, and rewrites the
# PE headers so the Windows loader honors the forwards. Handles PE32 and PE32+.
# ----------------------------------------------------------------------------

function Align-Up([uint32]$value, [uint32]$alignment) {
    if ($alignment -eq 0) { return $value }
    $remainder = $value % $alignment
    if ($remainder -eq 0) { return $value }
    $value + ($alignment - $remainder)
}

function Read-U16([byte[]]$buffer, [int]$offset) {
    [System.BitConverter]::ToUInt16($buffer, $offset)
}

function Read-U32([byte[]]$buffer, [int]$offset) {
    [System.BitConverter]::ToUInt32($buffer, $offset)
}

function Write-U16([byte[]]$buffer, [int]$offset, [uint16]$value) {
    $encoded = [System.BitConverter]::GetBytes($value)
    $buffer[$offset] = $encoded[0]
    $buffer[$offset + 1] = $encoded[1]
}

function Write-U32([byte[]]$buffer, [int]$offset, [uint32]$value) {
    $encoded = [System.BitConverter]::GetBytes($value)
    [Array]::Copy($encoded, 0, $buffer, $offset, 4)
}

function Read-CString([byte[]]$buffer, [int]$offset) {
    $end = $offset
    while ($buffer[$end] -ne 0) { $end++ }
    [System.Text.Encoding]::ASCII.GetString($buffer, $offset, $end - $offset)
}

function Parse-PeInfo([byte[]]$buffer) {
    if ($buffer.Length -lt 0x40 -or $buffer[0] -ne 0x4D -or $buffer[1] -ne 0x5A) {
        throw "not a PE file (missing MZ)"
    }
    $ntOffset = [int](Read-U32 $buffer 0x3C)
    if ($buffer.Length -lt $ntOffset + 24 -or $buffer[$ntOffset] -ne 0x50 -or $buffer[$ntOffset + 1] -ne 0x45) {
        throw "not a PE file (missing PE signature)"
    }

    $coff = $ntOffset + 4
    $numSections = [int](Read-U16 $buffer ($coff + 2))
    $optionalSize = [int](Read-U16 $buffer ($coff + 16))

    $optional = $coff + 20
    $magic = Read-U16 $buffer $optional
    $isPe32Plus = switch ($magic) {
        0x10B { $false; break }
        0x20B { $true; break }
        default { throw ("unknown PE magic: 0x{0:X}" -f $magic) }
    }

    # FileAlignment / SectionAlignment / SizeOfImage / SizeOfHeaders are at
    # identical offsets in PE32 and PE32+ optional headers.
    $sectionAlignment = Read-U32 $buffer ($optional + 32)
    $fileAlignment = Read-U32 $buffer ($optional + 36)

    $sectionTableOffset = $optional + $optionalSize
    $sections = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $numSections; $i++) {
        $header = $sectionTableOffset + $i * 40
        [void]$sections.Add([PSCustomObject]@{
            VirtualSize = Read-U32 $buffer ($header + 8)
            VirtualAddress = Read-U32 $buffer ($header + 12)
            SizeOfRawData = Read-U32 $buffer ($header + 16)
            PointerToRawData = Read-U32 $buffer ($header + 20)
        })
    }

    [PSCustomObject]@{
        NtOffset = $ntOffset
        OptionalSize = $optionalSize
        NumSections = $numSections
        IsPe32Plus = $isPe32Plus
        FileAlignment = $fileAlignment
        SectionAlignment = $sectionAlignment
        Sections = $sections
        SectionTableOffset = $sectionTableOffset
    }
}

function Resolve-RvaToFile($pe, [uint32]$rva) {
    foreach ($section in $pe.Sections) {
        $sectionStart = $section.VirtualAddress
        $sectionSize = [Math]::Max($section.VirtualSize, $section.SizeOfRawData)
        $sectionEnd = $sectionStart + $sectionSize
        if ($rva -ge $sectionStart -and $rva -lt $sectionEnd) {
            return [int]($rva - $sectionStart + $section.PointerToRawData)
        }
    }
    $null
}

function Get-DataDirectoryOffset($pe, [int]$index) {
    $optional = $pe.NtOffset + 4 + 20
    $base = if ($pe.IsPe32Plus) { 112 } else { 96 }
    $optional + $base + $index * 8
}

function Read-Exports([byte[]]$buffer) {
    $pe = Parse-PeInfo $buffer
    $exportDir = Get-DataDirectoryOffset $pe 0
    $exportRva = Read-U32 $buffer $exportDir
    $exportSize = Read-U32 $buffer ($exportDir + 4)
    if ($exportRva -eq 0 -or $exportSize -eq 0) {
        throw "target DLL has no export directory"
    }

    $baseOffset = Resolve-RvaToFile $pe $exportRva
    if ($null -eq $baseOffset) { throw "export RVA not in any section" }

    $baseOrdinal = Read-U32 $buffer ($baseOffset + 16)
    $numFunctions = Read-U32 $buffer ($baseOffset + 20)
    $numNames = Read-U32 $buffer ($baseOffset + 24)
    $functionsRva = Read-U32 $buffer ($baseOffset + 28)
    $namesRva = Read-U32 $buffer ($baseOffset + 32)
    $ordinalsRva = Read-U32 $buffer ($baseOffset + 36)

    $functionsOffset = Resolve-RvaToFile $pe $functionsRva
    if ($null -eq $functionsOffset) { throw "bad AddressOfFunctions RVA" }

    $namesOffset = 0
    $ordinalsOffset = 0
    if ($numNames -gt 0) {
        $namesOffset = Resolve-RvaToFile $pe $namesRva
        $ordinalsOffset = Resolve-RvaToFile $pe $ordinalsRva
        if ($null -eq $namesOffset -or $null -eq $ordinalsOffset) {
            throw "bad name / ordinal RVA"
        }
    }

    $nameBySlot = @{}
    for ($i = 0; $i -lt $numNames; $i++) {
        $nameRva = Read-U32 $buffer ($namesOffset + $i * 4)
        $slot = Read-U16 $buffer ($ordinalsOffset + $i * 2)
        $nameOffset = Resolve-RvaToFile $pe $nameRva
        if ($null -eq $nameOffset) { throw "bad name RVA" }
        $nameBySlot[[int]$slot] = Read-CString $buffer $nameOffset
    }

    $exports = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $numFunctions; $i++) {
        $functionRva = Read-U32 $buffer ($functionsOffset + $i * 4)
        if ($functionRva -eq 0) { continue }
        [void]$exports.Add([PSCustomObject]@{
            Ordinal = [uint32]($baseOrdinal + $i)
            Name = $nameBySlot[[int]$i]
        })
    }
    ,$exports
}

function Build-ExportSection($exports, [string]$forwardName, [uint32]$sectionRva) {
    if ($exports.Count -eq 0) { throw "target DLL has zero exports" }

    $baseOrdinal = [uint32]::MaxValue
    $maxOrdinal = 0
    foreach ($export in $exports) {
        if ($export.Ordinal -lt $baseOrdinal) { $baseOrdinal = $export.Ordinal }
        if ($export.Ordinal -gt $maxOrdinal) { $maxOrdinal = $export.Ordinal }
    }
    $numFunctions = [int]($maxOrdinal - $baseOrdinal + 1)

    # The loader does binary search on AddressOfNames, so names must be in
    # ordinal (byte-wise) order. PS's default sort is culture-aware and
    # reorders punctuation vs digits, which breaks GetProcAddress lookups.
    $namedList = [System.Collections.Generic.List[object]]::new()
    foreach ($export in $exports) {
        if ($export.Name) { $namedList.Add($export) }
    }
    $ordinalComparer = [System.Comparison[object]]{
        param($left, $right)
        [string]::CompareOrdinal($left.Name, $right.Name)
    }
    $namedList.Sort($ordinalComparer)
    $named = $namedList
    $numNames = $named.Count

    $dirSize = 40
    $functionsArraySize = $numFunctions * 4
    $namesArraySize = $numNames * 4
    $ordinalsArraySize = $numNames * 2
    $stringsStart = $dirSize + $functionsArraySize + $namesArraySize + $ordinalsArraySize

    $functionsArrayRva = $dirSize
    $namesArrayRva = $functionsArrayRva + $functionsArraySize
    $ordinalsArrayRva = $namesArrayRva + $namesArraySize

    $strings = [System.Collections.Generic.List[byte]]::new()
    $dllNameOffset = $strings.Count
    $strings.AddRange([System.Text.Encoding]::ASCII.GetBytes("unforeseen_proxy.dll" + [char]0))

    # Index exports by slot (0..numFunctions-1) in the original ordinal space.
    $exportBySlot = [object[]]::new($numFunctions)
    foreach ($export in $exports) {
        $exportBySlot[[int]($export.Ordinal - $baseOrdinal)] = $export
    }

    $forwarderOffsetBySlot = [object[]]::new($numFunctions)
    for ($slot = 0; $slot -lt $numFunctions; $slot++) {
        $export = $exportBySlot[$slot]
        if ($null -eq $export) { continue }
        $forwarder = if ($export.Name) {
            "$forwardName.$($export.Name)" + [char]0
        } else {
            "$forwardName.#$($export.Ordinal)" + [char]0
        }
        $forwarderOffsetBySlot[$slot] = $strings.Count
        $strings.AddRange([System.Text.Encoding]::ASCII.GetBytes($forwarder))
    }

    $nameStringOffsets = [int[]]::new($numNames)
    $nameOrdinalIndices = [uint16[]]::new($numNames)
    for ($i = 0; $i -lt $numNames; $i++) {
        $export = $named[$i]
        $nameStringOffsets[$i] = $strings.Count
        $strings.AddRange([System.Text.Encoding]::ASCII.GetBytes($export.Name + [char]0))
        $nameOrdinalIndices[$i] = [uint16]($export.Ordinal - $baseOrdinal)
    }

    $totalSize = $stringsStart + $strings.Count
    $buffer = [byte[]]::new($totalSize)

    Write-U32 $buffer 12 ($sectionRva + $stringsStart + $dllNameOffset)
    Write-U32 $buffer 16 $baseOrdinal
    Write-U32 $buffer 20 $numFunctions
    Write-U32 $buffer 24 $numNames
    Write-U32 $buffer 28 ($sectionRva + $functionsArrayRva)
    Write-U32 $buffer 32 ($sectionRva + $namesArrayRva)
    Write-U32 $buffer 36 ($sectionRva + $ordinalsArrayRva)

    for ($slot = 0; $slot -lt $numFunctions; $slot++) {
        $rva = 0
        if ($null -ne $forwarderOffsetBySlot[$slot]) {
            $rva = $sectionRva + $stringsStart + $forwarderOffsetBySlot[$slot]
        }
        Write-U32 $buffer ($functionsArrayRva + $slot * 4) $rva
    }

    for ($i = 0; $i -lt $numNames; $i++) {
        $rva = $sectionRva + $stringsStart + $nameStringOffsets[$i]
        Write-U32 $buffer ($namesArrayRva + $i * 4) $rva
    }

    for ($i = 0; $i -lt $numNames; $i++) {
        Write-U16 $buffer ($ordinalsArrayRva + $i * 2) $nameOrdinalIndices[$i]
    }

    $stringsArray = $strings.ToArray()
    [Array]::Copy($stringsArray, 0, $buffer, $stringsStart, $stringsArray.Length)

    ,$buffer
}

function New-DllProxy {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$ForwardName,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $target = [System.IO.File]::ReadAllBytes($TargetPath)
    $template = [System.IO.File]::ReadAllBytes($TemplatePath)

    $exports = Read-Exports $target
    $pe = Parse-PeInfo $template

    $sectionTableEnd = $pe.SectionTableOffset + $pe.NumSections * 40
    $firstSectionRaw = [uint32]::MaxValue
    foreach ($section in $pe.Sections) {
        if ($section.PointerToRawData -gt 0 -and $section.PointerToRawData -lt $firstSectionRaw) {
            $firstSectionRaw = $section.PointerToRawData
        }
    }
    if ($sectionTableEnd + 40 -gt $firstSectionRaw) {
        throw "no room for another section header"
    }

    $maxVaEnd = 0
    foreach ($section in $pe.Sections) {
        $sectionSize = [Math]::Max($section.VirtualSize, 1)
        $sectionEnd = $section.VirtualAddress + $sectionSize
        if ($sectionEnd -gt $maxVaEnd) { $maxVaEnd = $sectionEnd }
    }
    $sectionRva = Align-Up $maxVaEnd $pe.SectionAlignment

    $sectionBytes = Build-ExportSection $exports $ForwardName $sectionRva
    $virtualSize = [uint32]$sectionBytes.Length
    $rawSize = Align-Up $virtualSize $pe.FileAlignment

    $currentEnd = Align-Up $template.Length $pe.FileAlignment
    $newRawPointer = [int]$currentEnd
    $output = [byte[]]::new($newRawPointer + $rawSize)
    [Array]::Copy($template, 0, $output, 0, $template.Length)
    [Array]::Copy($sectionBytes, 0, $output, $newRawPointer, $sectionBytes.Length)

    $sectionHeaderOffset = $pe.SectionTableOffset + $pe.NumSections * 40
    $nameBuffer = [byte[]]::new(8)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes(".edata"), 0, $nameBuffer, 0, 6)
    [Array]::Copy($nameBuffer, 0, $output, $sectionHeaderOffset, 8)
    Write-U32 $output ($sectionHeaderOffset + 8) $virtualSize
    Write-U32 $output ($sectionHeaderOffset + 12) $sectionRva
    Write-U32 $output ($sectionHeaderOffset + 16) $rawSize
    Write-U32 $output ($sectionHeaderOffset + 20) $newRawPointer
    Write-U32 $output ($sectionHeaderOffset + 24) 0
    Write-U32 $output ($sectionHeaderOffset + 28) 0
    Write-U16 $output ($sectionHeaderOffset + 32) 0
    Write-U16 $output ($sectionHeaderOffset + 34) 0
    Write-U32 $output ($sectionHeaderOffset + 36) 0x40000040  # initialized data, read-only

    $coff = $pe.NtOffset + 4
    Write-U16 $output ($coff + 2) ($pe.NumSections + 1)

    $optional = $pe.NtOffset + 4 + 20
    $oldInitialized = Read-U32 $output ($optional + 8)
    Write-U32 $output ($optional + 8) ($oldInitialized + $rawSize)
    $newSizeOfImage = Align-Up ($sectionRva + $virtualSize) $pe.SectionAlignment
    Write-U32 $output ($optional + 56) $newSizeOfImage

    $exportDir = Get-DataDirectoryOffset $pe 0
    Write-U32 $output $exportDir $sectionRva
    Write-U32 $output ($exportDir + 4) $virtualSize

    Write-U32 $output ($optional + 64) 0  # clear checksum

    [System.IO.File]::WriteAllBytes($OutputPath, $output)
}

# ----------------------------------------------------------------------------

Write-Host ""
Heading "Unforeseen Achievements"
Write-Host ""

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
Put "version : $($release.tag_name)"

$tmp = Join-Path $env:TEMP "unforeseen"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$asset = $release.assets | Where-Object { $_.name -eq "unforeseen-x86.dll" }
if (-not $asset) { throw "release is missing asset: unforeseen-x86.dll" }
$templateDll = Join-Path $tmp "unforeseen-x86.dll"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $templateDll -UseBasicParsing
Put "fetched : unforeseen-x86.dll"

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

$installed = @()
$failed = @()
foreach ($idx in $indices) {
    $game = $found[$idx]
    $binDir = $game.BinDir
    $realDll = Join-Path $binDir "tier0_real.dll"
    $proxyDll = Join-Path $binDir "tier0.dll"

    # First install: preserve the pristine tier0.dll as tier0_real.dll.
    # Subsequent installs: tier0.dll is already our proxy, so skip the backup.
    if (-not (Test-Path $realDll)) {
        Copy-Item $proxyDll $realDll -Force
    }

    try {
        New-DllProxy -TemplatePath $templateDll -TargetPath $realDll -ForwardName "tier0_real" -OutputPath $proxyDll
        $installed += $game.Name
    } catch {
        Put "  error: $_" Red
        $failed += $game.Name
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($installed.Count -gt 0) {
    Put "Installed for:" Green
    foreach ($name in $installed) { Put "  - $name" }
    Write-Host ""
    Put "Achievements should now unlock in commentary mode"
}
if ($failed.Count -gt 0) {
    Put "Failed for:" Red
    foreach ($name in $failed) { Put "  - $name" }
}
Write-Host ""
