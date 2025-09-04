<#PSScriptInfo
.VERSION 1.10.0
.GUID 4c3f8c5b-4f88-47e7-9a45-2a38c1a9a0b3
.AUTHOR DJ Stomp <85457381+DJStompZone@users.noreply.github.com>
.COPYRIGHT (c) DJ Stomp. MIT License.
#>

<#
.SYNOPSIS
Zip top-level folders that contain specific marker files and delete sources on success, with scalable progress, path-typed lists, .zipignore support, and SOLID archiver abstraction.

.DESCRIPTION
Stage 1 scans top-level subdirectories under the specified Root. If a subdirectory’s immediate children contain ".zipignore"
(file or directory), it is skipped entirely. Otherwise, if its tree contains any of:
  - README.md
  - manifest.json
  - pyproject.toml
  - package.json
it is selected via a fast DFS that skips heavy directories.

Stage 2 builds a typed list of file paths via DFS (skipping excluded directories), then stages a filtered copy
(creating parent directories on demand) and archives using:
  - Preferred: system zip → zip -5r "<archive>.zip" -- .
  - Fallback: Compress-Archive (Optimal)
Archive is verified by unzip -tq when available, else via .NET ZipArchive. Source is deleted only upon verified success.

Exclusions:
  - Top-level presence of ".zipignore" => skip project entirely.
  - Directories skipped during traversal: "node_modules", ".venv", "venv".
  - File extensions can be excluded by passing -ExcludeExtensions (e.g. -ExcludeExtensions .zip,.rar).

Progress cadence scales with size:
  - Always update on item 1, on the last item, and every 10^(digits-2) items in between.

Overwrites of existing archives are controlled by -Force / -NoClobber with ShouldProcess confirmation if neither is set.

.PARAMETER Root
Root directory to scan. Defaults to the current directory.

.PARAMETER ExcludeExtensions
One or more file extensions to exclude during staging. Example: -ExcludeExtensions .zip,.rar,.iso

.PARAMETER Force
Overwrite existing archives without prompting.

.PARAMETER NoClobber
Never overwrite; error if the archive already exists.

.PARAMETER WhatIf
Shows what would happen if the script runs. No changes are made.

.EXAMPLE
PS> ./zip-projects.ps1

.EXAMPLE
PS> ./zip-projects.ps1 ~/Projects -ExcludeExtensions .zip,.rar

.EXAMPLE
PS> ./zip-projects.ps1 -Force
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Position=0)]
    [string]$Root = (Get-Location).Path,
    [string[]]$ExcludeExtensions,
    [switch]$Force,
    [switch]$NoClobber
)

# Resolve and validate root once; expose as script-scoped for all helpers.
try {
    $script:Root = (Resolve-Path -LiteralPath $Root).Path
} catch {
    throw "Root path not found or inaccessible: $Root"
}
if (-not (Test-Path -LiteralPath $script:Root -PathType Container)) {
    throw "Root must be a directory: $script:Root"
}

$markerFiles     = @('README.md','manifest.json','pyproject.toml','package.json')
$excludedNames   = @('node_modules','.venv','venv')
$exclusionMarker = '.zipignore'

# Normalize user-supplied extension filters once
$excludeExtSet = $null
if ($ExcludeExtensions -and $ExcludeExtensions.Count -gt 0) {
    $excludeExtSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in $ExcludeExtensions) {
        if ([string]::IsNullOrWhiteSpace($ext)) { continue }
        $e = $ext.Trim()
        if ($e[0] -ne '.') { $e = '.' + $e }
        [void]$excludeExtSet.Add($e)
    }
}

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
        $childPath = [System.IO.Path]::Combine($Dir.FullName, $exclusionMarker)
        if (Test-Path -LiteralPath $childPath) { return $true }
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
    foreach ($m in $markerFiles) { [void]$markerSet.Add($m) }

    $excludeDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $excludedNames) { [void]$excludeDirs.Add($n) }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Dir.FullName) | Out-Null

    $scanned = 0
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

    $top = Get-ChildItem -Path $script:Root -Directory -Force
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
    Enumerate files under a source dir while skipping excluded directories and optional extensions, returning List[string] of full paths.
    .PARAMETER Source
    Source directory path.
    .PARAMETER OverallId
    Write-Progress ID for Stage 2 overall.
    .PARAMETER FolderId
    Write-Progress ID for Stage 2 per-folder (used for pre-copy "indexing" progress).
    .OUTPUTS
    System.Collections.Generic.List[string]
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][int]$OverallId,
        [Parameter(Mandatory)][int]$FolderId
    )

    $excludeDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $excludedNames) { [void]$excludeDirs.Add($n) }

    $list = New-Object 'System.Collections.Generic.List[string]'
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
            if ($excludeExtSet -ne $null) {
                $ext = [System.IO.Path]::GetExtension($entry)
                if ($excludeExtSet.Contains($ext)) { continue }
            }

            $list.Add($entry) | Out-Null

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
        [void][System.IO.Directory]::CreateDirectory($Destination)
    }

    $files = Get-FilesFilteredList -Source $Source -OverallId $OverallId -FolderId $FolderId
    $total = [math]::Max(1, $files.Count)
    $step  = Get-ProgressStep -Total $total

    $rootResolved = (Resolve-Path -LiteralPath $Source).Path
    $i = 0
    foreach ($path in $files) {
        $i += 1
        $relative = [System.IO.Path]::GetRelativePath($rootResolved, $path)
        $destFile = Join-Path $Destination $relative
        $destDir  = Split-Path -Parent $destFile
        if (-not (Test-Path -LiteralPath $destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
        [System.IO.File]::Copy($path, $destFile, $true)

        if ($i -eq 1 -or $i -eq $total -or ($i % $step -eq 0)) {
            $pct = [int](($i / $total) * 100)
            Write-Progress -Id $FolderId -ParentId $OverallId -Activity "Stage 2: Staging files" -Status "$i of $($total)" -PercentComplete $pct
        }
    }

    Write-Progress -Id $FolderId -Completed
    return $files.Count
}

function Invoke-External {
    <#
    .SYNOPSIS
    Run an external process with captured stdout/stderr/exit code.
    .PARAMETER FileName
    Executable path.
    .PARAMETER Arguments
    Command-line arguments.
    .PARAMETER WorkingDirectory
    Optional working directory.
    .OUTPUTS
    psobject with properties: ExitCode, Stdout, Stderr
    #>
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WorkingDirectory
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

function Handle-ExistingArchive {
    <#
    .SYNOPSIS
    Apply -Force / -NoClobber / ShouldProcess policy for an existing zip path.
    .PARAMETER ZipPath
    Destination zip path.
    .OUTPUTS
    None
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    if (-not (Test-Path -LiteralPath $ZipPath)) { return }

    if ($Force) {
        Remove-Item -LiteralPath $ZipPath -Force
        return
    }
    if ($NoClobber) {
        throw "Archive already exists at $ZipPath and -NoClobber was specified."
    }
    if ($PSCmdlet.ShouldProcess($ZipPath, "Overwrite existing archive")) {
        Remove-Item -LiteralPath $ZipPath -Force
        return
    }
    throw "Archive already exists at $ZipPath and overwrite was not confirmed."
}

function Resolve-ArchiveTool {
    <#
    .SYNOPSIS
    Determine the archiving strategy.
    .OUTPUTS
    psobject with properties: Mode ('ZipCmd' or 'CompressArchive'), Command (path) when ZipCmd
    #>
    $zipCmd = Get-Command zip -ErrorAction SilentlyContinue
    if ($zipCmd) {
        return [pscustomobject]@{ Mode = 'ZipCmd'; Command = $zipCmd.Source }
    }
    return [pscustomobject]@{ Mode = 'CompressArchive'; Command = $null }
}

function Test-ZipReadable {
    <#
    .SYNOPSIS
    Verify a zip can be opened and has at least one entry using .NET.
    .PARAMETER ZipPath
    Full path to the zip file.
    .OUTPUTS
    System.Boolean
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    if (-not (Test-Path -LiteralPath $ZipPath)) { return $false }
    if ((Get-Item -LiteralPath $ZipPath).Length -le 22) { return $false }

    try {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Read, $false)
            $ok = ($zip.Entries.Count -gt 0)
            $zip.Dispose()
            return $ok
        } finally { $fs.Dispose() }
    } catch { return $false }
}

function Test-ArchiveIntegrity {
    <#
    .SYNOPSIS
    Verify archive via unzip -tq if present; otherwise .NET.
    .PARAMETER ZipPath
    Zip path.
    .OUTPUTS
    None (throws on failure)
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    $unzip = Get-Command unzip -ErrorAction SilentlyContinue
    if ($unzip) {
        $res = Invoke-External -FileName $unzip.Source -Arguments "-tq ""$ZipPath"""
        if ($res.ExitCode -ne 0) {
            throw "unzip test failed: $($res.Stdout)$($res.Stderr)"
        }
        return
    }

    if (-not (Test-ZipReadable -ZipPath $ZipPath)) {
        throw "Archive verification failed: zip unreadable or empty."
    }
}

function New-ArchiveFromDir {
    <#
    .SYNOPSIS
    Create or overwrite a ZIP archive from a directory using the resolved tool (zip or Compress-Archive) and verify integrity.
    .PARAMETER SourceDir
    Directory to archive (already staged/filtered).
    .PARAMETER ZipPath
    Destination zip path.
    .OUTPUTS
    System.IO.FileInfo
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ZipPath
    )

    Handle-ExistingArchive -ZipPath $ZipPath

    $src = (Resolve-Path -LiteralPath $SourceDir).Path
    $tool = Resolve-ArchiveTool

    if ($tool.Mode -eq 'ZipCmd') {
        $res = Invoke-External -FileName $tool.Command -Arguments "-5r ""$ZipPath"" -- ." -WorkingDirectory $src
        if ($res.ExitCode -ne 0) {
            throw "zip failed with exit code $($res.ExitCode)`nSTDOUT:`n$($res.Stdout)`nSTDERR:`n$($res.Stderr)"
        }
    } else {
        try {
            Compress-Archive -Path (Join-Path $src '*') -DestinationPath $ZipPath -CompressionLevel Optimal -Force
        } catch {
            throw "Compress-Archive failed: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Archive was not created at $ZipPath." }
    Test-ArchiveIntegrity -ZipPath $ZipPath
    return Get-Item -LiteralPath $ZipPath
}

# Top-level paths derived from $script:Root
$compressedDir = Join-Path $script:Root "compressed"
$stagingRoot   = Join-Path $script:Root "__staging_pack"

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
        if (Test-Path -LiteralPath $stageDir)) {
            if ($PSCmdlet.ShouldProcess($stageDir, "Cleanup staging")) {
                Remove-Item -LiteralPath $stageDir -Recurse -Force
            }
        }
    }
}

Write-Progress -Id $stage2Overall -Completed
Write-Host ("Done. Archived {0} project(s) to: {1}" -f $totalTargets, $compressedDir)
