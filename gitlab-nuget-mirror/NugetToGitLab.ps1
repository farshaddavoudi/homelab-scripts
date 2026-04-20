[CmdletBinding()]
param(
  [switch]$WhatIf,
  [switch]$IgnorePushedPackagesTxtRef,
  [string]$RepositoryPath,
  [string]$SolutionPath,
  [ValidateNotNullOrWhiteSpace()][string]$GitLabSourceName = "gitlab-nuget"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GitLabFeedIndexUrl = "https://gitlab.airparsiana.com/api/v4/projects/35/packages/nuget/index.json"
$NuGetOrgFeedIndexUrl = "https://api.nuget.org/v3/index.json"
$SkipSeedingPackagePattern = "AP.*"
$PushTimeoutSeconds = 1800
$PushRetryCount = 3
$PushRetryDelaySeconds = 5

$DefaultSharedCacheRoot = "C:\Workspace\temp\nuget-shared-cache"
$ConfiguredCacheRoot = if (-not [string]::IsNullOrWhiteSpace($env:AP_NUGET_SHARED_CACHE)) { $env:AP_NUGET_SHARED_CACHE } else { $DefaultSharedCacheRoot }
if (-not [System.IO.Path]::IsPathRooted($ConfiguredCacheRoot)) {
  throw "Cache path must be absolute. AP_NUGET_SHARED_CACHE='$ConfiguredCacheRoot'"
}

$SharedCacheRoot = $ConfiguredCacheRoot.TrimEnd("\", "/")

$ScriptDir = Split-Path -Parent $PSCommandPath
$CacheDir = Join-Path $SharedCacheRoot "seed"
$DownloadsDir = Join-Path $CacheDir "downloads"
$PushedPackagesRefPath = Join-Path $CacheDir "pushed-packages.txt"
$LogPath = Join-Path $CacheDir "seed-log.txt"
$RestoreConfigPath = Join-Path $CacheDir "NuGet.Seed.restore.config"
$PushConfigPath = Join-Path $CacheDir "NuGet.Seed.push.config"

$Summary = [ordered]@{
  ResolvedPackages = 0
  PatternSkipped = 0
  Downloaded = 0
  DownloadSkipped = 0
  DownloadFailed = 0
  ReferenceSkipped = 0
  Pushed = 0
  PushSkipped = 0
  PushFailed = 0
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$timestamp] [$Level] $Message"

  Add-Content -Path $script:LogPath -Value $line

  $color = switch ($Level) {
    "SUCCESS" { "Green" }
    "WARN" { "Yellow" }
    "ERROR" { "Red" }
    default { "Cyan" }
  }

  Write-Host $line -ForegroundColor $color
}

function Write-LogSeparator {
  Write-Log ("-" * 72) "INFO"
}

function Find-RepoRoot {
  param([Parameter(Mandatory = $true)][string]$StartPath)

  $resolvedStartPath = (Resolve-Path $StartPath).Path
  $current = if (Test-Path -Path $resolvedStartPath -PathType Leaf) {
    Split-Path -Parent $resolvedStartPath
  } else {
    $resolvedStartPath
  }

  while ($true) {
    if (Test-Path (Join-Path $current ".git")) {
      return $current
    }

    $parent = Split-Path -Parent $current
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
      throw "Cannot locate repository root (.git) starting from '$StartPath'."
    }

    $current = $parent
  }
}

function Ensure-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' is not available on PATH."
  }
}

function Resolve-NuGetExe {
  $nuget = Get-Command "nuget.exe" -ErrorAction SilentlyContinue
  if ($nuget) {
    return $nuget.Source
  }

  throw @"
nuget.exe not found.
Install it before running this script:
  winget install Microsoft.NuGet
"@
}

function Get-RequiredEnvVar {
  param([Parameter(Mandatory = $true)][string]$Name)

  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required environment variable '$Name'. Set it before running the script."
  }

  return $value.Trim()
}

function Get-ProjectsFromSln {
  param([Parameter(Mandatory = $true)][string]$SolutionPath)

  $solutionDirectory = Split-Path -Parent $SolutionPath
  $projects = @()

  foreach ($line in Get-Content $SolutionPath) {
    if ($line -match 'Project\(".*"\)\s*=\s*".*"\s*,\s*"(.*?\.csproj)"\s*,') {
      $relativePath = $matches[1]
      $fullPath = Join-Path $solutionDirectory $relativePath
      if (Test-Path $fullPath) {
        $projects += (Resolve-Path $fullPath).Path
      }
    }
  }

  return $projects | Sort-Object -Unique
}

function Select-Solution {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $solutions = @(Get-ChildItem -Path $RepoRoot -Filter "*.sln" -File -Recurse | Sort-Object FullName)
  if ($solutions.Count -eq 0) {
    throw "No .sln file found under '$RepoRoot'."
  }

  $rootSolutions = @($solutions | Where-Object { (Split-Path -Parent $_.FullName) -eq $RepoRoot })
  if ($rootSolutions.Count -eq 1) {
    return $rootSolutions[0].FullName
  }

  if ($rootSolutions.Count -gt 1) {
    $selectedRoot = $rootSolutions[0].FullName
    Write-Log "Multiple root-level solutions found. Selected '$selectedRoot'." "WARN"
    return $selectedRoot
  }

  $ranked = foreach ($solution in $solutions) {
    [pscustomobject]@{
      Path = $solution.FullName
      ProjectCount = (Get-ProjectsFromSln -SolutionPath $solution.FullName).Count
    }
  }

  $selected = $ranked |
    Sort-Object -Property @{ Expression = "ProjectCount"; Descending = $true }, @{ Expression = "Path"; Descending = $false } |
    Select-Object -First 1

  if ($solutions.Count -gt 1) {
    Write-Log "Multiple solutions found. Selected '$($selected.Path)' (projects: $($selected.ProjectCount))." "WARN"
  }

  return $selected.Path
}

function Invoke-LoggedCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $printableArguments = $Arguments | ForEach-Object {
    if ($_ -match "\s") { """$_""" } else { $_ }
  }

  Write-Log ("Running: {0} {1}" -f $FilePath, ($printableArguments -join " ")) "INFO"

  $output = & $FilePath @Arguments 2>&1
  $exitCode = $LASTEXITCODE

  if ($output) {
    foreach ($line in $output) {
      Add-Content -Path $script:LogPath -Value ("    {0}" -f $line)
    }
  }

  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    throw ("Command failed with exit code {0}: {1} {2}" -f $exitCode, $FilePath, ($Arguments -join " "))
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function New-RestoreConfig {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$GitLabUser,
    [Parameter(Mandatory = $true)][string]$GitLabToken
  )

  $escapedUser = [System.Security.SecurityElement]::Escape($GitLabUser)
  $escapedToken = [System.Security.SecurityElement]::Escape($GitLabToken)

  $content = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="gitlab" value="$GitLabFeedIndexUrl" />
    <add key="nuget.org" value="$NuGetOrgFeedIndexUrl" />
  </packageSources>
  <packageSourceCredentials>
    <gitlab>
      <add key="Username" value="$escapedUser" />
      <add key="ClearTextPassword" value="$escapedToken" />
    </gitlab>
  </packageSourceCredentials>
</configuration>
"@

  Set-Content -Path $Path -Value $content -Encoding UTF8
}

function New-PushConfig {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$GitLabUser,
    [Parameter(Mandatory = $true)][string]$GitLabToken
  )

  $escapedUser = [System.Security.SecurityElement]::Escape($GitLabUser)
  $escapedToken = [System.Security.SecurityElement]::Escape($GitLabToken)

  $content = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="$GitLabSourceName" value="$GitLabFeedIndexUrl" />
  </packageSources>
  <packageSourceCredentials>
    <$GitLabSourceName>
      <add key="Username" value="$escapedUser" />
      <add key="ClearTextPassword" value="$escapedToken" />
    </$GitLabSourceName>
  </packageSourceCredentials>
</configuration>
"@

  Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Get-PackagesFromAssets {
  param([Parameter(Mandatory = $true)][string[]]$ProjectPaths)

  $unique = @{}
  $missingAssets = New-Object System.Collections.Generic.List[object]

  foreach ($projectPath in $ProjectPaths) {
    $projectDirectory = Split-Path -Parent $projectPath
    $assetsPath = Join-Path $projectDirectory "obj\project.assets.json"

    if (-not (Test-Path $assetsPath)) {
      $missingAssets.Add([pscustomobject]@{
        Project = $projectPath
        Reason = "project.assets.json not found"
      })
      continue
    }

    try {
      $assets = Get-Content -Path $assetsPath -Raw | ConvertFrom-Json
    } catch {
      $missingAssets.Add([pscustomobject]@{
        Project = $projectPath
        Reason = "Failed to parse project.assets.json: $($_.Exception.Message)"
      })
      continue
    }

    if (-not $assets.libraries) {
      continue
    }

    foreach ($library in $assets.libraries.PSObject.Properties) {
      $libraryInfo = $library.Value
      if (-not $libraryInfo -or $libraryInfo.type -ne "package") {
        continue
      }

      $parts = $library.Name.Split("/", 2)
      if ($parts.Count -ne 2) {
        continue
      }

      $packageId = $parts[0]
      $packageVersion = $parts[1]
      if ([string]::IsNullOrWhiteSpace($packageId) -or [string]::IsNullOrWhiteSpace($packageVersion)) {
        continue
      }

      $key = "{0}|{1}" -f $packageId, $packageVersion
      if (-not $unique.ContainsKey($key)) {
        $unique[$key] = [pscustomobject]@{
          Id = $packageId
          Version = $packageVersion
        }
      }
    }
  }

  return [pscustomobject]@{
    Packages = @($unique.Values | Sort-Object Id, Version)
    MissingAssets = $missingAssets
  }
}

function Get-DownloadSourcesForPackageId {
  param([Parameter(Mandatory = $true)][string]$PackageId)

  if ($PackageId -like $SkipSeedingPackagePattern) {
    return @($GitLabFeedIndexUrl)
  }

  return @($NuGetOrgFeedIndexUrl, $GitLabFeedIndexUrl)
}

function Get-LooseNuGetVersionKey {
  param([Parameter(Mandatory = $true)][string]$Version)

  $cleanVersion = $Version.Trim()
  if ([string]::IsNullOrWhiteSpace($cleanVersion)) {
    return ""
  }

  $withoutMetadata = ($cleanVersion -split "\+", 2)[0]
  $versionParts = $withoutMetadata -split "-", 2
  $core = $versionParts[0]
  $suffix = if ($versionParts.Count -gt 1) { "-" + $versionParts[1].ToLowerInvariant() } else { "" }

  $coreParts = @($core.Split(".") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  while ($coreParts.Count -gt 2 -and $coreParts[-1] -eq "0") {
    $coreParts = @($coreParts[0..($coreParts.Count - 2)])
  }

  if ($coreParts.Count -eq 0) {
    $coreParts = @("0")
  }

  return (($coreParts -join ".").ToLowerInvariant() + $suffix)
}

function Resolve-DownloadedNupkgPath {
  param(
    [Parameter(Mandatory = $true)][string]$TargetDirectory,
    [Parameter(Mandatory = $true)][string]$PackageId,
    [Parameter(Mandatory = $true)][string]$PackageVersion
  )

  $exactDirectory = Join-Path $TargetDirectory ("{0}.{1}" -f $PackageId, $PackageVersion)
  $exactNupkgPath = Join-Path $exactDirectory ("{0}.{1}.nupkg" -f $PackageId, $PackageVersion)
  if (Test-Path $exactNupkgPath) {
    return $exactNupkgPath
  }

  $expectedVersionKey = Get-LooseNuGetVersionKey -Version $PackageVersion
  $candidateDirectories = @(Get-ChildItem -Path $TargetDirectory -Directory -Filter ("{0}.*" -f $PackageId) -ErrorAction SilentlyContinue)

  foreach ($directory in $candidateDirectories) {
    $prefix = ("{0}." -f $PackageId)
    if (-not $directory.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      continue
    }

    $directoryVersion = $directory.Name.Substring($prefix.Length)
    $directoryVersionKey = Get-LooseNuGetVersionKey -Version $directoryVersion
    if ($directoryVersionKey -ne $expectedVersionKey) {
      continue
    }

    $candidateNupkg = Get-ChildItem -Path $directory.FullName -File -Filter ("{0}.*.nupkg" -f $PackageId) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidateNupkg) {
      return $candidateNupkg.FullName
    }
  }

  return $null
}

function Get-PackageReferenceKey {
  param(
    [Parameter(Mandatory = $true)][string]$PackageId,
    [Parameter(Mandatory = $true)][string]$Version
  )

  return ("{0}|{1}" -f $PackageId, $Version)
}

function New-PackageReferenceSet {
  return @{}
}

function Load-PushedPackagesReference {
  param([Parameter(Mandatory = $true)][string]$Path)

  $set = New-PackageReferenceSet
  if (-not (Test-Path $Path)) {
    return $set
  }

  foreach ($line in Get-Content -Path $Path) {
    $trimmed = $line.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      $set[$trimmed] = $true
    }
  }

  return $set
}

function Save-PushedPackagesReference {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Set
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    Ensure-Directory -Path $directory
  }

  $values = @($Set.Keys | Sort-Object)
  Set-Content -Path $Path -Value $values -Encoding UTF8
}

function Download-Packages {
  param(
    [Parameter(Mandatory = $true)][string]$NuGetExePath,
    [Parameter(Mandatory = $true)][object[]]$Packages,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$TargetDirectory
  )
  $failed = New-Object System.Collections.Generic.List[object]
  $downloaded = 0
  $skipped = 0

  Ensure-Directory -Path $TargetDirectory

  foreach ($package in $Packages) {
    $resolvedNupkgPath = Resolve-DownloadedNupkgPath -TargetDirectory $TargetDirectory -PackageId $package.Id -PackageVersion $package.Version

    if (-not [string]::IsNullOrWhiteSpace($resolvedNupkgPath)) {
      $skipped++
      Write-Log ("Skip download (cached): {0} {1}" -f $package.Id, $package.Version) "INFO"
      continue
    }

    $sources = Get-DownloadSourcesForPackageId -PackageId $package.Id

    $isDownloaded = $false
    foreach ($source in $sources) {
      $arguments = @(
        "install", $package.Id,
        "-Version", $package.Version,
        "-OutputDirectory", $TargetDirectory,
        "-NonInteractive",
        "-Prerelease",
        "-ConfigFile", $ConfigPath,
        "-Source", $source
      )

      $result = Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments $arguments -IgnoreExitCode
      $resolvedNupkgPath = Resolve-DownloadedNupkgPath -TargetDirectory $TargetDirectory -PackageId $package.Id -PackageVersion $package.Version
      if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedNupkgPath)) {
        $downloaded++
        $isDownloaded = $true
        Write-Log ("Downloaded: {0} {1} (source: {2})" -f $package.Id, $package.Version, $source) "SUCCESS"
        break
      }

      $summary = ""
      if ($result.Output -and $result.Output.Count -gt 0) {
        $summary = (($result.Output | Select-Object -First 2) -join " | ").Trim()
      }

      if ([string]::IsNullOrWhiteSpace($summary)) {
        Write-Log ("Download attempt failed: {0} {1} (source: {2}, exit: {3})" -f $package.Id, $package.Version, $source, $result.ExitCode) "WARN"
      } else {
        Write-Log ("Download attempt failed: {0} {1} (source: {2}, exit: {3}). {4}" -f $package.Id, $package.Version, $source, $result.ExitCode, $summary) "WARN"
      }
    }

    if (-not $isDownloaded) {
      $failed.Add([pscustomobject]@{
        Id = $package.Id
        Version = $package.Version
        Stage = "download"
        Reason = "All download sources failed."
      })
      Write-Log ("Failed download: {0} {1}" -f $package.Id, $package.Version) "ERROR"
    }
  }

  return [pscustomobject]@{
    Downloaded = $downloaded
    Skipped = $skipped
    Failed = $failed
  }
}

function Push-Packages {
  param(
    [Parameter(Mandatory = $true)][object[]]$Packages,
    [Parameter(Mandatory = $true)][string]$SourceName,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [Parameter(Mandatory = $true)]$PushedPackagesSet,
    [Parameter(Mandatory = $true)][string]$DownloadsDirectory
  )

  $failed = New-Object System.Collections.Generic.List[object]
  $pushed = 0
  $skipped = 0

  foreach ($package in $Packages) {
    $packageRefKey = Get-PackageReferenceKey -PackageId $package.Id -Version $package.Version
    $nupkgPath = Resolve-DownloadedNupkgPath -TargetDirectory $DownloadsDirectory -PackageId $package.Id -PackageVersion $package.Version

    if ([string]::IsNullOrWhiteSpace($nupkgPath) -or -not (Test-Path $nupkgPath)) {
      $failed.Add([pscustomobject]@{
        Id = $package.Id
        Version = $package.Version
        Stage = "push"
        Reason = "Package file not found in cache."
      })
      Write-Log ("Cannot push missing package: {0} {1}" -f $package.Id, $package.Version) "ERROR"
      continue
    }

    $attempt = 0
    $isDone = $false
    $lastExitCode = -1
    $lastOutputText = ""

    while ($attempt -lt $PushRetryCount -and -not $isDone) {
      $attempt++
      if ($attempt -gt 1) {
        Write-Log ("Retrying push ({0}/{1}): {2} {3}" -f $attempt, $PushRetryCount, $package.Id, $package.Version) "WARN"
      }

      $arguments = @(
        "nuget", "push", $nupkgPath,
        "--source", $SourceName,
        "--configfile", $ConfigPath,
        "--api-key", $ApiKey,
        "--skip-duplicate",
        "--timeout", $PushTimeoutSeconds,
        "--disable-buffering"
      )

      $result = Invoke-LoggedCommand -FilePath "dotnet" -Arguments $arguments -IgnoreExitCode
      $lastExitCode = $result.ExitCode
      $lastOutputText = ($result.Output | Out-String)

      if ($result.ExitCode -eq 0) {
        if ($lastOutputText -match "already exists|duplicate|409|Conflict") {
          $skipped++
          Write-Log ("Skip push (duplicate): {0} {1}" -f $package.Id, $package.Version) "WARN"
        } else {
          $pushed++
          Write-Log ("Pushed: {0} {1}" -f $package.Id, $package.Version) "SUCCESS"
        }

        $PushedPackagesSet[$packageRefKey] = $true
        $isDone = $true
        continue
      }

      if ($lastOutputText -match "already exists|duplicate|409|Conflict") {
        $skipped++
        Write-Log ("Skip push (duplicate with non-zero exit): {0} {1}" -f $package.Id, $package.Version) "WARN"
        $PushedPackagesSet[$packageRefKey] = $true
        $isDone = $true
        continue
      }

      $outputIndicatesSuccessfulPush = $lastOutputText -match "Your package was pushed\.|Created\s+https?://"
      if ($outputIndicatesSuccessfulPush) {
        $pushed++
        Write-Log ("Pushed (confirmed by output): {0} {1}" -f $package.Id, $package.Version) "SUCCESS"
        $PushedPackagesSet[$packageRefKey] = $true
        $isDone = $true
        continue
      }

      $isTransientError = $lastOutputText -match "timed out|took too long|task was canceled|forcibly closed|transport connection|502|503|504|BadGateway|GatewayTimeout|ServiceUnavailable"
      if ($isTransientError -and $attempt -lt $PushRetryCount) {
        Write-Log ("Transient push error detected. Waiting {0}s before retry." -f $PushRetryDelaySeconds) "WARN"
        Start-Sleep -Seconds $PushRetryDelaySeconds
        continue
      }

      break
    }

    if (-not $isDone) {
      $failureSummary = ""
      if (-not [string]::IsNullOrWhiteSpace($lastOutputText)) {
        $failureSummary = ($lastOutputText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
      }

      $failureReason = ("dotnet nuget push failed after {0} attempts (last exit {1})" -f $PushRetryCount, $lastExitCode)
      if (-not [string]::IsNullOrWhiteSpace($failureSummary)) {
        $failureReason = "{0}. {1}" -f $failureReason, $failureSummary.Trim()
      }

      $failed.Add([pscustomobject]@{
        Id = $package.Id
        Version = $package.Version
        Stage = "push"
        Reason = $failureReason
      })
      Write-Log ("Push failed: {0} {1}" -f $package.Id, $package.Version) "ERROR"
    }
  }

  return [pscustomobject]@{
    Pushed = $pushed
    Skipped = $skipped
    Failed = $failed
  }
}

function Show-Summary {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Counters,
    [object[]]$Failures = @()
  )

  Write-Host ""
  Write-Host "NuGet Seed Summary" -ForegroundColor Cyan

  @(
    [pscustomobject]@{ Metric = "Resolved packages"; Count = $Counters.ResolvedPackages }
    [pscustomobject]@{ Metric = "Pattern skipped"; Count = $Counters.PatternSkipped }
    [pscustomobject]@{ Metric = "Reference skipped"; Count = $Counters.ReferenceSkipped }
    [pscustomobject]@{ Metric = "Downloaded"; Count = $Counters.Downloaded }
    [pscustomobject]@{ Metric = "Download skipped"; Count = $Counters.DownloadSkipped }
    [pscustomobject]@{ Metric = "Download failed"; Count = $Counters.DownloadFailed }
    [pscustomobject]@{ Metric = "Pushed"; Count = $Counters.Pushed }
    [pscustomobject]@{ Metric = "Push skipped"; Count = $Counters.PushSkipped }
    [pscustomobject]@{ Metric = "Push failed"; Count = $Counters.PushFailed }
  ) | Format-Table -AutoSize

  if ($Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed packages" -ForegroundColor Red
    $Failures |
      Sort-Object Stage, Id, Version |
      Format-Table -Property Stage, Id, Version, Reason -AutoSize
  }
}

function Should-PauseOnExit {
  if ($env:WT_SESSION) { return $false }
  if ($env:TERM_PROGRAM) { return $false }
  if ($Host.Name -ne "ConsoleHost") { return $false }
  return $true
}

function Invoke-NuGetSeeding {
  Ensure-Directory -Path $CacheDir
  Ensure-Directory -Path $DownloadsDir

  if (Test-Path $LogPath) {
    Remove-Item -Path $LogPath -Force
  }

  New-Item -ItemType File -Path $LogPath -Force | Out-Null

  Write-LogSeparator
  Write-Log "Starting offline NuGet seeding flow."
  Write-Log ("Script path: {0}" -f $PSCommandPath)
  Write-Log ("Shared cache root: {0}" -f $SharedCacheRoot)
  Write-Log ("Cache path: {0}" -f $CacheDir)
  Write-Log ("WhatIf mode: {0}" -f $WhatIf.IsPresent)
  Write-Log ("IgnorePushedPackagesTxtRef mode: {0}" -f $IgnorePushedPackagesTxtRef.IsPresent)
  Write-Log ("GitLab source alias: {0}" -f $GitLabSourceName)
  if (-not [string]::IsNullOrWhiteSpace($RepositoryPath)) {
    Write-Log ("RepositoryPath override: {0}" -f $RepositoryPath)
  }
  if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
    Write-Log ("SolutionPath override: {0}" -f $SolutionPath)
  }

  Ensure-Command -Name "dotnet"
  $nugetExe = Resolve-NuGetExe

  $gitLabUser = Get-RequiredEnvVar -Name "GITLAB_NUGET_USER"
  $gitLabToken = Get-RequiredEnvVar -Name "GITLAB_NUGET_TOKEN"

  $repoStartPath = if (-not [string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath
  } else {
    (Get-Location).Path
  }

  $repoRoot = Find-RepoRoot -StartPath $repoStartPath

  $solutionPath = if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
    if (-not (Test-Path -Path $SolutionPath -PathType Leaf)) {
      throw "Provided SolutionPath does not exist: '$SolutionPath'."
    }

    $resolvedSolutionPath = (Resolve-Path $SolutionPath).Path
    if ([System.IO.Path]::GetExtension($resolvedSolutionPath) -ne ".sln") {
      throw "Provided SolutionPath must point to a .sln file: '$resolvedSolutionPath'."
    }

    $resolvedSolutionPath
  } else {
    Select-Solution -RepoRoot $repoRoot
  }
  $projectPaths = @(Get-ProjectsFromSln -SolutionPath $solutionPath)

  if ($projectPaths.Count -eq 0) {
    throw "No .csproj entries discovered in solution '$solutionPath'."
  }

  Write-Log ("Repository root: {0}" -f $repoRoot)
  Write-Log ("Selected solution: {0}" -f $solutionPath)
  Write-Log ("Projects found in solution: {0}" -f $projectPaths.Count)

  New-RestoreConfig -Path $RestoreConfigPath -GitLabUser $gitLabUser -GitLabToken $gitLabToken

  $restoreArguments = @(
    "restore", $solutionPath,
    "--configfile", $RestoreConfigPath,
    "--verbosity", "minimal"
  )

  Invoke-LoggedCommand -FilePath "dotnet" -Arguments $restoreArguments | Out-Null
  Write-Log "Restore completed using temporary config (gitlab + nuget.org)." "SUCCESS"

  $resolvedData = Get-PackagesFromAssets -ProjectPaths $projectPaths
  $packages = @($resolvedData.Packages)
  $Summary.ResolvedPackages = $packages.Count

  foreach ($missing in $resolvedData.MissingAssets) {
    Write-Log ("Asset warning: {0} - {1}" -f $missing.Project, $missing.Reason) "WARN"
  }

  if ($packages.Count -eq 0) {
    throw "No resolved packages found in project.assets.json files."
  }

  Write-Log ("Resolved package count (direct + transitive): {0}" -f $packages.Count)

  $pushedPackagesReference = Load-PushedPackagesReference -Path $PushedPackagesRefPath
  Write-Log ("Loaded pushed package references: {0}" -f $pushedPackagesReference.Count)
  if ($IgnorePushedPackagesTxtRef.IsPresent) {
    Write-Log "Ignoring pushed-packages.txt reference for this run." "WARN"
  }

  $packagesToProcess = New-Object System.Collections.Generic.List[object]
  foreach ($package in $packages) {
    if ($package.Id -like $SkipSeedingPackagePattern) {
      $Summary.PatternSkipped++
      Write-Log ("Skip internal package by pattern '{0}': {1} {2}" -f $SkipSeedingPackagePattern, $package.Id, $package.Version) "INFO"
      continue
    }

    $packageRefKey = Get-PackageReferenceKey -PackageId $package.Id -Version $package.Version
    if ((-not $IgnorePushedPackagesTxtRef.IsPresent) -and $pushedPackagesReference.ContainsKey($packageRefKey)) {
      $Summary.ReferenceSkipped++
      Write-Log ("Skip by pushed-packages reference: {0} {1}" -f $package.Id, $package.Version) "INFO"
      continue
    }

    $packagesToProcess.Add($package) | Out-Null
  }

  Write-Log ("Packages to process after pushed-reference filter: {0}" -f $packagesToProcess.Count)

  if ($WhatIf.IsPresent) {
    $Summary.DownloadSkipped = $packagesToProcess.Count
    $Summary.PushSkipped = $packagesToProcess.Count
    Write-Log "WhatIf enabled. Skipping download and push steps." "WARN"
    Show-Summary -Counters $Summary -Failures @()
    Write-Log "Completed in WhatIf mode." "SUCCESS"
    return
  }

  if ($packagesToProcess.Count -eq 0) {
    Write-Log "No external packages to process after pattern/reference filters." "SUCCESS"
    Show-Summary -Counters $Summary -Failures @()
    return
  }

  $downloadResult = Download-Packages -NuGetExePath $nugetExe -Packages $packagesToProcess -ConfigPath $RestoreConfigPath -TargetDirectory $DownloadsDir
  $Summary.Downloaded = $downloadResult.Downloaded
  $Summary.DownloadSkipped = $downloadResult.Skipped
  $Summary.DownloadFailed = $downloadResult.Failed.Count

  New-PushConfig -Path $PushConfigPath -GitLabUser $gitLabUser -GitLabToken $gitLabToken

  $failedDownloadKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($failed in $downloadResult.Failed) {
    [void]$failedDownloadKeys.Add(("{0}|{1}" -f $failed.Id, $failed.Version))
  }

  $packagesToPush = @($packagesToProcess | Where-Object {
    -not $failedDownloadKeys.Contains(("{0}|{1}" -f $_.Id, $_.Version))
  })

  $pushResult = [pscustomobject]@{
    Pushed = 0
    Skipped = 0
    Failed = @()
  }

  if ($packagesToPush.Count -gt 0) {
    $pushResult = Push-Packages -Packages $packagesToPush -SourceName $GitLabSourceName -ConfigPath $PushConfigPath -ApiKey $gitLabToken -PushedPackagesSet $pushedPackagesReference -DownloadsDirectory $DownloadsDir
  } else {
    Write-Log "No packages available to push after download stage." "WARN"
  }

  $Summary.Pushed = $pushResult.Pushed
  $Summary.PushSkipped = $pushResult.Skipped
  $Summary.PushFailed = $pushResult.Failed.Count

  Save-PushedPackagesReference -Path $PushedPackagesRefPath -Set $pushedPackagesReference
  Write-Log ("Saved pushed-packages reference file: {0}" -f $PushedPackagesRefPath)

  $allFailures = @()
  $allFailures += $downloadResult.Failed
  $allFailures += $pushResult.Failed

  Show-Summary -Counters $Summary -Failures $allFailures

  if ($allFailures.Count -gt 0) {
    Write-Log ("Seeding completed with failures. Count: {0}" -f $allFailures.Count) "ERROR"
    throw "One or more packages failed during download/push. See $LogPath"
  }

  Write-Log "NuGet seeding completed successfully." "SUCCESS"
}

$hasError = $false
try {
  Invoke-NuGetSeeding
} catch {
  $hasError = $true
  Write-Log ("Script failed: {0}" -f $_.Exception.Message) "ERROR"
  Write-Error $_
} finally {
  if (Test-Path $RestoreConfigPath) {
    Remove-Item -Path $RestoreConfigPath -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path $PushConfigPath) {
    Remove-Item -Path $PushConfigPath -Force -ErrorAction SilentlyContinue
  }

  if (Should-PauseOnExit) {
    Write-Host ""
    if ($hasError) {
      Write-Host "Seeding failed. Press Enter to close..." -ForegroundColor Red
    } else {
      Write-Host "Seeding completed successfully. Press Enter to close..." -ForegroundColor Green
    }
    try { [void](Read-Host) } catch { }
  }
}

if ($hasError) {
  exit 1
}

exit 0
