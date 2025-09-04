<#PSScriptInfo
.VERSION 1.7.0
.GUID 4c3f8c5b-4f88-47e7-9a45-2a38c1a9a0b3
.AUTHOR DJ Stomp <85457381+DJStompZone@users.noreply.github.com>
.COPYRIGHT (c) DJ Stomp. MIT License.
#>

<#
.SYNOPSIS
Zip top-level folders that contain specific marker files and delete sources on success, with scalable progress, typed file lists, and a .zipignore top-level exclusion.

.DESCRIPTION
Stage 1 scans top-level subdirectories in the current directory. If a subdirectory’s *immediate children* contain ".zipignore"
(either a file or a directory named exactly ".zipignore"), it is skipped entirely. Otherwise, if its tree contains any of:
  - README.md
  - manifest.json
  - pyproject.toml
  - package.json
it is selected via a fast DFS that skips heavy directories.

Stage 2 builds a typed file list via DFS that SKIPS excluded directories, then stages a filtered copy
(creating parent directories on demand) and archives using system zip:
  zip -5r "<archive>.zip" -- .
Archive is verified by existence, non-zero size, and optional unzip -tq. Source is deleted only upon verified success.

Exclusions:
  - Top-level presence of ".zipignore" => skip project entirely
  - Directories skipped during traversal: "node_modules", ".venv", "venv"
  - Files skipped during traversal: "*.zip"

Progress cadence scales with size:
  - Always update on item 1, on the last item, and every 10^(digits-2) items in between.

Overwrites existing archives with the same name.

.PARAMETER WhatIf
Shows what would happen if the script runs. No changes are made.

.EXAMPLE
PS> ./zip-projects.ps1

.EXAMPLE
PS> ./zip-projects.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$markerFiles     = @('README.md','manifest.json','pyproject.toml','package.json')
$excludedNames   = @('node_modules','.venv','venv')
$exclusionMarker = '.zipignore'

function Get-ProgressStep {
    <#
    .SYNOPSIS
    Return 10^(digits-2) for a given total, minimum 1.
    .PARAMETER Total
    The total count to scale against.
    .OUTPUTS
    int
    #>
    param([Parameter(Mandatory)][int]$Total)
    $n = [math]::Max(1, $Total)
    $digits = ([string]$n).Length
    return [int][math]::Pow(10, [math]::Max(0, $digits - 2))
}

function Test-TopLevelExcluded {
    <#
    .SYNOPSIS
    Returns $true if a directory contains a top-level ".zipignore" (file or dir).
    .PARAMETER Dir
    DirectoryInfo to check.
    .OUTPUTS
    System.Boolean
    #>
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Dir)

    try {
        $childPath = Join-Path $Dir.FullName $exclusionMarker
        if (Test-Path -LiteralPath $childPath) { return $true }

        # Fallback to quick name check over immediate children with -Force so hidden entries are seen
        $names = Get-ChildItem -LiteralPath $Dir.FullName -Force -Depth 0 -Name -ErrorAction SilentlyContinue
        if ($names -and ($names -contains $exclusionMarker)) { return $true }
    } catch { return $false }

    return $false
}

function Test-DirHasMarkerFast {
    <#
    .SYNOPSIS
    Returns $true if a directory contains any marker file, scanning with DFS and excluding heavy dirs, with scaled progress.
    .PARAMETER Dir
    DirectoryInfo to scan.
    .PARAMETER OverallId
    Write-Progress ID for Stage 1 overall.
    .PARAMETER FolderId
    Write-Progress ID for Stage 1 per-folder.
    .OUTPUTS
    System.Boolean
    #>
    param(
        [Parameter(Mandatory)][System.IO.DirectoryInfo]$Dir,
        [Parameter(Mandatory)][int]$OverallId,
        [Parameter(Mandatory)][int]$FolderId
    )

    $markerSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $markerFiles | ForEach-Object { [void]$markerSet.Add($_) }

    $excludeDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $excludedNames | ForEach-Object { [void]$excludeDirs.Add($_) }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Dir.FullName) | Out-Null

    $scanned = 0
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $entries = [System.IO.Directory]::EnumerateFileSystemEntries($current)
        } catch {
            continue
        }

        foreach ($entry in $entries) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ([System.IO.Directory]::Exists($entry)) {
                if ($excludeDirs.Contains($name)) { continue }
                $stack.Push($entry) | Out-Null
                continue
            }

            $scanned += 1
            if ($markerSet.Contains($name)) {
                Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 1: Scanning $($Dir.Name)" -Status "Found $name" -PercentComplete 100
                Write-Progress -Id $FolderId -Completed
                return $true
            }

            $step = Get-ProgressStep -Total $scanned
            if ($scanned -eq 1 -or ($scanned % $step -eq 0)) {
                Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 1: Scanning $($Dir.Name)" -Status "$scanned files checked"
            }
        }
    }

    Write-Progress -Id $FolderId -Completed
    return $false
}

function Get-MarkedTopLevelDirs {
    <#
    .SYNOPSIS
    Discover top-level directories that contain any marker file, skipping those with a top-level .zipignore, with progress.
    .PARAMETER OverallId
    Write-Progress ID for Stage 1 overall.
    .PARAMETER FolderId
    Write-Progress ID for Stage 1 per-folder.
    .OUTPUTS
    System.IO.DirectoryInfo[]
    #>
    param(
        [Parameter(Mandatory)][int]$OverallId,
        [Parameter(Mandatory)][int]$FolderId
    )

    $top = Get-ChildItem -Directory -Force
    if (-not $top) { return @() }

    $total = $top.Count
    $i = 0
    $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]

    foreach ($dir in $top) {
        $i += 1
        $pct = [int](($i / [math]::Max(1,$total)) * 100)
        Write-Progress -Id $OverallId -Activity "Stage 1: Discovering projects" -Status "Checking $i of $($total): $($dir.Name)" -PercentComplete $pct

        if (Test-TopLevelExcluded -Dir $dir) {
            Write-Host ("Skipping {0} due to top-level {1}" -f $dir.Name, $exclusionMarker)
            continue
        }

        Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 1: Scanning $($dir.Name)" -Status "Starting"
        if (Test-DirHasMarkerFast -Dir $dir -OverallId $OverallId -FolderId $FolderId) { $found.Add($dir) }
        Write-Progress -Id $FolderId -Completed
    }

    Write-Progress -Id $OverallId -Completed
    return ,$found.ToArray()
}

function Get-FilesFilteredList {
    <#
    .SYNOPSIS
    Enumerate files under a source dir while skipping excluded directories, returning a typed List[FileInfo].
    .PARAMETER Source
    Source directory path.
    .PARAMETER OverallId
    Write-Progress ID for Stage 2 overall.
    .PARAMETER FolderId
    Write-Progress ID for Stage 2 per-folder (used for pre-copy "indexing" progress).
    .OUTPUTS
    System.Collections.Generic.List[System.IO.FileInfo]
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$OverallId,
        [Parameter(Mandatory)][int]$FolderId
    )

    $excludeDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $excludedNames | ForEach-Object { [void]$excludeDirs.Add($_) }

    $excludeExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @('.zip') | ForEach-Object { [void]$excludeExtensions.Add($_) }

    $list = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $rootPath = (Resolve-Path -LiteralPath $Source).Path
    $stack.Push($rootPath) | Out-Null

    $seen = 0
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $entries = [System.IO.Directory]::EnumerateFileSystemEntries($current)
        } catch { continue }

        foreach ($entry in $entries) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ([System.IO.Directory]::Exists($entry)) {
                if ($excludeDirs.Contains($name)) { continue }
                $stack.Push($entry) | Out-Null
                continue
            }

            $seen += 1
            if ($excludeExtensions.Contains([System.IO.Path]::GetExtension($entry))) { continue }

            try {
                $fi = [System.IO.FileInfo]::new($entry)
                $list.Add($fi)
            } catch { continue }

            $step = Get-ProgressStep -Total $seen
            if ($seen -eq 1 -or ($seen % $step -eq 0)) {
                Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 2: Indexing files" -Status "$seen discovered"
            }
        }
    }

    Write-Progress -Id $FolderId -Completed
    return $list
}

function Copy-TreeFiltered {
    <#
    .SYNOPSIS
    Copy files from a prebuilt typed list, creating parent directories on demand, with scaled progress.
    .PARAMETER Source
    Source directory path.
    .PARAMETER Destination
    Destination directory path.
    .PARAMETER OverallId
    Write-Progress ID for Stage 2 overall.
    .PARAMETER FolderId
    Write-Progress ID for Stage 2 per-folder.
    .OUTPUTS
    int
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$OverallId,
        [Parameter(Mandatory)][int]$FolderId
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    $files = Get-FilesFilteredList -Source $Source -OverallId $OverallId -FolderId $FolderId
    $total = [math]::Max(1, $files.Count)
    $step  = Get-ProgressStep -Total $total

    $rootResolved = (Resolve-Path -LiteralPath $Source).Path
    $i = 0
    foreach ($f in $files) {
        $i += 1
        $relative = $f.FullName.Substring($rootResolved.Length).TrimStart('\','/')
        $destFile = Join-Path $Destination $relative
        $destDir  = Split-Path -Parent $destFile
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $destFile -Force

        if ($i -eq 1 -or $i -eq $total -or ($i % $step -eq 0)) {
            $pct = [int](($i / $total) * 100)
            Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 2: Staging files" -Status "$i of $($total)" -PercentComplete $pct
        }
    }

    Write-Progress -Id $FolderId -Completed
    return $files.Count
}

function New-ArchiveFromDir {
    <#
    .SYNOPSIS
    Create or overwrite a ZIP archive from a directory using /bin/zip -5r, with verification.
    .PARAMETER SourceDir
    Directory to archive.
    .PARAMETER ZipPath
    Destination zip path.
    .OUTPUTS
    System.IO.FileInfo
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ZipPath
    )

    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    $src = (Resolve-Path -LiteralPath $SourceDir).Path

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "/bin/zip"
    $psi.Arguments = "-5r ""$ZipPath"" -- ."
    $psi.WorkingDirectory = $src
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) { throw "zip failed with exit code $($proc.ExitCode)`nSTDOUT:`n$stdout`nSTDERR:`n$stderr" }
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "zip did not create archive." }
    if ((Get-Item -LiteralPath $ZipPath).Length -le 22) { throw "zip created a tiny/empty file." }

    $unzip = Get-Command unzip -ErrorAction SilentlyContinue
    if ($unzip) {
        $psi2 = New-Object System.Diagnostics.ProcessStartInfo
        $psi2.FileName = $unzip.Source
        $psi2.Arguments = "-tq ""$ZipPath"""
        $psi2.UseShellExecute = $false
        $psi2.RedirectStandardError = $true
        $psi2.RedirectStandardOutput = $true
        $proc2 = [System.Diagnostics.Process]::Start($psi2)
        $out2 = $proc2.StandardOutput.ReadToEnd() + $proc2.StandardError.ReadToEnd()
        $proc2.WaitForExit()
        if ($proc2.ExitCode -ne 0) { throw "unzip test failed: $out2" }
    }

    return Get-Item -LiteralPath $ZipPath
}

$root = Get-Location
$compressedDir = Join-Path $root "compressed"
$stagingRoot   = Join-Path $root "__staging_pack"

if (-not (Test-Path -LiteralPath $compressedDir)) {
    if ($PSCmdlet.ShouldProcess($compressedDir, "Create directory")) {
        New-Item -ItemType Directory -Path $compressedDir | Out-Null
    }
}
if (-not (Test-Path -LiteralPath $stagingRoot)) {
    if ($PSCmdlet.ShouldProcess($stagingRoot, "Create staging directory")) {
        New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    }
}

$stage1Overall = 100
$stage1Folder  = 101
$targets = Get-MarkedTopLevelDirs -OverallId $stage1Overall -FolderId $stage1Folder

if (-not $targets -or $targets.Count -eq 0) {
    Write-Host "No top-level directories with required marker files were found. Nothing to do."
    return
}

$stage2Overall = 200
$stage2Folder  = 201

$totalTargets = $targets.Count
$processed = 0

foreach ($dir in $targets) {
    # Re-check top-level .zipignore right before processing, in case it appeared after Stage 1
    if (Test-TopLevelExcluded -Dir $dir) {
        Write-Host ("Skipping {0} due to top-level {1}" -f $dir.Name, $exclusionMarker)
        continue
    }

    $processed += 1
    $overallPct = [int](($processed / $totalTargets) * 100)
    Write-Progress -Id $stage2Overall -Activity "Stage 2: Archiving projects" -Status "Processing $processed of $($totalTargets): $($dir.Name)" -PercentComplete $overallPct

    $zipPath  = Join-Path $compressedDir ("{0}.zip" -f $dir.Name)
    $stageDir = Join-Path $stagingRoot $dir.Name

    try {
        if (Test-Path -LiteralPath $stageDir) {
            if ($PSCmdlet.ShouldProcess($stageDir, "Remove existing staging")) {
                Remove-Item -LiteralPath $stageDir -Recurse -Force
            }
        }

        if ($PSCmdlet.ShouldProcess($dir.FullName, "Stage filtered copy")) {
            $copied = Copy-TreeFiltered -Source $dir.FullName -Destination $stageDir -OverallId $stage2Overall -FolderId $stage2Folder
            Write-Host ("Staged {0} files for {1}" -f $copied, $dir.Name)
        }

        if ($copied -le 0) {
            Write-Warning ("Nothing to archive for: {0} (staging produced 0 files)" -f $dir.Name)
            continue
        }

        Write-Progress -Id $stage2Folder -ParentId $stage2Overall -Activity "Stage 2: Compressing" -Status $dir.Name -PercentComplete 0
        if ($PSCmdlet.ShouldProcess($zipPath, "Create archive")) {
            $zipItem = $null
            try {
                $zipItem = New-ArchiveFromDir -SourceDir $stageDir -ZipPath $zipPath
            } catch {
                $msg = $_.Exception.Message
                $sample = Get-ChildItem -LiteralPath $stageDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 5 -ExpandProperty FullName
                Write-Warning ("Archive failed for: {0}`nReason: {1}`nExamples:`n - {2}" -f $dir.Name, $msg, ($sample -join "`n - "))
            }
        }
        Write-Progress -Id $stage2Folder -Completed

        $ok = $null -ne $zipItem -and (Test-Path -LiteralPath $zipPath) -and ((Get-Item -LiteralPath $zipPath).Length -gt 0)
        if ($ok) {
            $sizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
            if ($PSCmdlet.ShouldProcess($dir.FullName, "Remove source directory after verified archive")) {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            }
            Write-Host ("Packed {0} -> {1} ({2} MB) and removed source" -f $dir.Name, (Split-Path -Leaf $zipPath), $sizeMB)
        } else {
            Write-Warning ("Archive failed or empty for: {0}" -f $dir.Name)
        }
    }
    catch {
        Write-Warning ("Error processing {0}: {1}" -f $dir.Name, $_)
    }
    finally {
        if (Test-Path -LiteralPath $stageDir) {
            if ($PSCmdlet.ShouldProcess($stageDir, "Cleanup staging")) {
                Remove-Item -LiteralPath $stageDir -Recurse -Force
            }
        }
    }
}

Write-Progress -Id $stage2Overall -Completed
Write-Host ("Done. Archived {0} project(s) to: {1}" -f $totalTargets, $compressedDir)
