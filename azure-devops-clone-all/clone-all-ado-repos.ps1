param(
    [string]$CollectionUrl = "http://your-ado-server:8080/tfs/DefaultCollection",
    [string]$PAT = "rcfa5t23q5gabhrqmd3lwo5oiraxsj7spvo5xiziptt6elix7lma",
    [string]$OutputFolder = "C:\Workspace",
    [switch]$Mirror
)

# 🚨 IMPORTANT: show all errors
$ErrorActionPreference = "Stop"

try {
    Write-Host "🚀 Starting cloning process..."

    # Fix TLS issues (very common in on-prem)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Auth header
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
    $headers = @{ Authorization = ("Basic {0}" -f $base64AuthInfo) }

    # Ensure output folder exists
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

    Write-Host "🔍 Fetching projects..."

    $projectsUrl = "$CollectionUrl/_apis/projects?api-version=6.0"
    Write-Host "URL: $projectsUrl"

    $projects = Invoke-RestMethod -Uri $projectsUrl -Headers $headers

    if (-not $projects.value) {
        throw "❌ No projects returned. Check PAT or URL."
    }

    foreach ($project in $projects.value) {

        $projectName = $project.name
        Write-Host "`n📁 Project: $projectName"

        $projectFolder = Join-Path $OutputFolder $projectName
        New-Item -ItemType Directory -Force -Path $projectFolder | Out-Null

        $reposUrl = "$CollectionUrl/$projectName/_apis/git/repositories?api-version=6.0"
        Write-Host "   → Fetching repos..."

        $repos = Invoke-RestMethod -Uri $reposUrl -Headers $headers

        foreach ($repo in $repos.value) {

            $repoName = $repo.name
            $repoUrl = $repo.remoteUrl
            $targetPath = Join-Path $projectFolder $repoName

            if (Test-Path $targetPath) {
                Write-Host "⏭️ Skipping (exists): $repoName"
                continue
            }

            Write-Host "⬇️ Cloning: $repoName"

            if ($Mirror) {
                git clone --mirror $repoUrl $targetPath
            }
            else {
                git clone $repoUrl $targetPath
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "⚠️ Git clone failed: $repoName"
            }
        }
    }

    Write-Host "`n✅ Done."

}
catch {
    Write-Host "`n❌ ERROR OCCURRED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
finally {
    Write-Host "`nPress Enter to exit..."
    Read-Host
}