# zip-projects

`zip-projects.ps1` is a PowerShell utility for packaging project folders into `.zip` archives.

## Features

- Detects top-level directories containing any of these marker files:
  - `README.md`
  - `manifest.json`
  - `pyproject.toml`
  - `package.json`
- Skips directories with a top-level `.zipignore`
- Excludes common heavy subtrees (`node_modules`, `.venv`, `venv`)
- Optional exclusion of file extensions via `-ExcludeExtensions`
- Stages files into a temporary working area before archiving
- Creates archives with:
  - Native `zip` (preferred) if available
  - Else fallback to `Compress-Archive`
- Verifies archives with `unzip -tq` when available, otherwise via .NET `ZipArchive`
- Deletes source directories only on verified success
- Controlled overwrite behavior:
  - `-Force` overwrites existing archives
  - `-NoClobber` prevents overwrite
  - With neither flag, overwrite requires confirmation
- Scaled progress reporting suitable for both small and very large projects

## Requirements

- PowerShell 7+
- Optional
  - `zip`
  - `unzip`

## Usage

### Specify a root directory

```powershell
./zip-projects.ps1 ~/Projects
```

Scans and archives projects under `~/Projects` into `~/Projects/compressed/`.

### Exclude extensions

```powershell
./zip-projects.ps1 -ExcludeExtensions .zip,.rar
```

Skips staging files with the listed extensions.

### Overwrite control

```powershell
./zip-projects.ps1 -Force
```

Overwrite existing archives without prompting.

```powershell
./zip-projects.ps1 -NoClobber
```

Abort if the archive already exists.

### Dry run

```powershell
./zip-projects.ps1 -WhatIf
```

Show planned actions without making changes.

## Behavior

1. **Stage 1 – Discovery**
   Top-level directories under `Root` are scanned. Directories with a top-level `.zipignore` are skipped immediately. A project is selected if any marker file appears anywhere in the tree.

2. **Stage 2 – Archiving**
   Selected directories are staged into a filtered copy, excluding ignored directories and any extensions you specify. The staging area is archived using native `zip` (if present) or `Compress-Archive` (fallback), verified for integrity, and the **source directory is deleted** only after a verified archive exists.

## Notes

* Archives are written to `./compressed/` under the specified `Root`.
* Temporary staging occurs under `./__staging_pack/` and is removed after each project.
* Progress updates scale with item counts; large projects remain responsive without chatty updates.

## License

MIT License. See the [LICENSE](LICENSE) file for details.