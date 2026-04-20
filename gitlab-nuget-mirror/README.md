# GitLab NuGet Mirror Script

This folder contains one Windows PowerShell script to seed/mirror NuGet packages into our internal GitLab NuGet feed.

## Script

- `NugetToGitLab.ps1`

## Purpose

- Use GitLab Package Registry (NuGet) as the internal NuGet feed.
- `nuget.org` must **not** be used as a fallback in CI/offline build flows.
- When a package is missing in GitLab, run this script (manually or scheduled) to seed it.

## Platform

- Run this script from **Windows** (PowerShell).
- It depends on Windows-oriented paths and PowerShell execution behavior.

## Required tooling

- `.NET SDK` (`dotnet` on PATH)
- `nuget.exe` on PATH (example: `winget install Microsoft.NuGet`)

## Required environment variables

Set these before running the script:

- `GITLAB_NUGET_USER`
- `GITLAB_NUGET_TOKEN`

Optional:

- `AP_NUGET_SHARED_CACHE` (absolute path for shared cache; default: `C:\Workspace\temp\nuget-shared-cache`)

## Repository NuGet configuration policy

- Keep and use a **repo-level** `NuGet.config`.
- CI runners should use **only** GitLab feed (no `nuget.org`).
- Developers on Windows with internet should use:
  - Default profile/config: only GitLab feed.
  - Optional profile/config: GitLab + `nuget.org` only when intentionally searching/seeding packages for develop.

## How the script works

1. Detects repository root and selects a solution.
2. Restores using a temporary config (`gitlab` + `nuget.org`) to resolve package graph.
3. Reads `project.assets.json` files to discover direct + transitive packages.
4. Skips internal packages matching `AP.*`.
5. Downloads missing packages to cache.
6. Pushes packages to GitLab feed with duplicate-skip and retry logic.
7. Tracks pushed package references in `pushed-packages.txt` to avoid re-pushing.

## Usage

From repository root (or any path under repo):

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1
```

Dry run:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 -WhatIf
```

Ignore `pushed-packages.txt` reference for one run:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 -IgnorePushedPackagesTxtRef
```

## Scheduled/manual sync recommendation

Use a manual run or a Windows scheduled task/job to run this script regularly.

Expected behavior:

- If local dev machine has internet, download required packages and push them to GitLab (skip duplicates/already existing packages).
- If machine is offline, run is naturally limited/fails for external download stage.

## CI / pipeline note

- No pipeline change is required for automatic transfer from `nuget.org` to private GitLab feed.
- Build/restore fails when a package is missing in GitLab.
- Missing packages must be seeded by running this script (or waiting for scheduled job).

## Operational note

- A valid GitLab token is required to push packages into GitLab feed.
