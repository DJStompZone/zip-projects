# zip-projects.ps1

`zip-projects.ps1` is a PowerShell utility for packaging project folders into `.zip` archives. It is designed for environments where projects are numerous, large, and scattered with heavy dependencies. The script automates detection, staging, compression, and cleanup while staying efficient and predictable.

## Features

- Detects top-level directories containing project markers:
  - `README.md`
  - `manifest.json`
  - `pyproject.toml`
  - `package.json`
- Skips directories with a top-level `.zipignore`.
- Excludes common heavy subtrees (`node_modules`, `.venv`, `venv`).
- Optional exclusion of file extensions via `-ExcludeExtensions`.
- Stages files into a temporary working area before archiving.
- Creates archives with:
  - Native `zip` binary if available.
  - Fallback to `Compress-Archive` if not.
- Verifies archives with `unzip -tq` when available, else .NET ZipArchive.
- Deletes source directories only on verified success.
- Controlled overwrite behavior:
  - `-Force` overwrites existing archives.
  - `-NoClobber` prevents overwrite.
  - Without either flag, overwrite requires confirmation.
- Scaled progress reporting suitable for both small and very large projects.

## Requirements

- PowerShell 7+

## Usage

### Basic run

```powershell
./zip-projects.ps1
````

Archives all eligible projects in the current directory to `./compressed/`.

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

Shows planned actions without making changes.

## Behavior

1. **Stage 1 – Discovery**
   Top-level directories are scanned. Directories with `.zipignore` are skipped. A project is selected if any marker file is found.

2. **Stage 2 – Archiving**
   Selected directories are staged into a filtered copy, excluding ignored directories and extensions. The staging area is archived, verified, and the source directory is deleted on success.

## Notes

* Archives are written to `./compressed/`.
* Temporary staging occurs under `./__staging_pack/` and is removed after each run.
* Progress reporting updates scale with the number of files; large projects do not stall due to frequent updates.

## License

MIT License. See the LICENSE file for details.