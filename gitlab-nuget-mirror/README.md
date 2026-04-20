# GitLab NuGet Mirror (AirParsiana)

`NugetToGitLab.ps1` is the team script for seeding external NuGet packages into the shared GitLab feed used by offline-first CI.

## Goal

- CI restore/build uses GitLab feed only.
- `nuget.org` is never used directly in CI.
- Developers can still work with `nuget.org` locally when needed.
- Missing packages are mirrored manually via this script.

## What the script does

1. Finds the repository root and target solution.
2. Runs `dotnet restore` with a temporary config (`gitlab` + `nuget.org`) to resolve the full graph.
3. Reads `obj/project.assets.json` to collect direct + transitive packages.
4. Skips internal packages matching `AP.*` (expected to already exist in GitLab).
5. Downloads uncached packages into a shared cache.
6. Pushes each package to GitLab (`--skip-duplicate`, retry on transient errors).
7. Saves `pushed-packages.txt` so next runs avoid re-pushing already mirrored versions.

## Prerequisites

- Windows PowerShell (`powershell.exe`) or PowerShell 7 (`pwsh`).
- `dotnet` on `PATH`.
- `nuget.exe` on `PATH`.
- GitLab credentials in environment variables:
  - `GITLAB_NUGET_USER`
  - `GITLAB_NUGET_TOKEN`

Optional:

- `AP_NUGET_SHARED_CACHE` absolute path.  
  Default: `C:\Workspace\temp\nuget-shared-cache`
- `-GitLabSourceName` script parameter (default: `gitlab-nuget`) if you want a custom local source alias.

## Usage

Default run from the target repository folder:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1
```

Dry run:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 -WhatIf
```

Ignore `pushed-packages.txt` for one run:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 -IgnorePushedPackagesTxtRef
```

Run against a specific repo/solution (when script is outside the repo):

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 `
  -RepositoryPath C:\Workspace\ap\gitlab-repos\core\services\iam-api `
  -SolutionPath C:\Workspace\ap\gitlab-repos\core\services\iam-api\AP.Core.IAM.Api.sln
```

Run with a custom source alias:

```powershell
pwsh -File .\gitlab-nuget-mirror\NugetToGitLab.ps1 -GitLabSourceName gitlab-nuget
```

## Cache and state files

Under `<AP_NUGET_SHARED_CACHE>\seed`:

- `downloads\` : cached `.nupkg` files used for push.
- `pushed-packages.txt` : package/version references already mirrored.
- `seed-log.txt` : full run log.

## CI policy (recommended)

- CI config file (`NuGet.CI.config`) should contain only GitLab feed.
- Docker/CI restore should explicitly use that file:

```bash
dotnet restore --configfile ./src/NuGet.CI.config
```

- Use CI variables for credentials (masked/protected), not hardcoded values.

## Common failure cases

- `401 Unauthorized`: token or username is wrong, missing, expired, or lacks package registry scope.
- `NU1101 package not found`: package is not mirrored yet; run this script and retry CI.
- Slow first run: expected when seeding many packages; later runs are faster due to cache + pushed reference.
- Single package push timeout: rerun script; it retries transient failures and continues other packages.

## Security notes

- Never commit tokens into scripts, Dockerfiles, or config files.
- Prefer GitLab CI variables and/or deploy tokens for automation.
- If both GitLab and `nuget.org` are enabled in dev configs, treat internal package names carefully to avoid dependency confusion.
