param(
    [ValidateSet("", "Apply", "Remove")]
    [string]$InitialAction = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RouteListPath = Join-Path $PSScriptRoot "bypass-routes.txt"
$DnsResolverListPath = Join-Path $PSScriptRoot "dns-resolvers.txt"
$script:SuppressPauseOnExit = $false
$script:ExitCode = 0

function Should-PauseOnExit {
    if ($env:WT_SESSION) { return $false }
    if ($env:TERM_PROGRAM) { return $false }
    if ($Host.Name -ne "ConsoleHost") { return $false }
    return $true
}

function Pause-Console {
    param(
        [string]$Message = "Press Enter to continue..."
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    try {
        [void](Read-Host)
    }
    catch {
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Apply", "Remove")]
        [string]$ActionName
    )

    Write-Host ""
    Write-Host "This action needs administrator rights." -ForegroundColor Yellow
    $answer = Read-Host "Relaunch as administrator now? (Y/N)"
    if ($answer -notmatch "^(y|yes)$") {
        Write-Host "Action cancelled." -ForegroundColor Yellow
        return $false
    }

    $argumentList = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InitialAction $ActionName"
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentList | Out-Null
        $script:SuppressPauseOnExit = $true
        return $true
    }
    catch {
        Write-Host ("Failed to relaunch as administrator: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Get-RouteListHeaderLines {
    return @(
        "# Format:",
        "# IP",
        "# IP | domain.example.com",
        "# IP | domain.example.com, www.example.com | optional note"
    )
}

function Get-DnsResolverListDefaultLines {
    return @(
        "# Public DNS resolver IPv4 addresses used for domain lookup when VPN DNS is problematic.",
        "# One IPv4 address per line.",
        "# The script tries these resolvers before system DNS.",
        "",
        "1.1.1.1",
        "8.8.8.8",
        "9.9.9.9",
        "208.67.222.222"
    )
}

function Ensure-RouteListFile {
    if (-not (Test-Path -LiteralPath $RouteListPath)) {
        Set-Content -LiteralPath $RouteListPath -Value (Get-RouteListHeaderLines) -Encoding UTF8
    }
}

function Ensure-DnsResolverListFile {
    if (-not (Test-Path -LiteralPath $DnsResolverListPath)) {
        Set-Content -LiteralPath $DnsResolverListPath -Value (Get-DnsResolverListDefaultLines) -Encoding UTF8
    }
}

function Test-Ipv4Address {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    try {
        $parsed = [System.Net.IPAddress]::Parse($Address)
        return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    }
    catch {
        return $false
    }
}

function Normalize-TextValue {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return $Value.Trim()
}

function Convert-ToDomainTokenList {
    param(
        [AllowEmptyString()]
        [string]$DomainsText
    )

    if ([string]::IsNullOrWhiteSpace($DomainsText)) {
        return @()
    }

    return @(
        $DomainsText -split "[,;]+" |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Join-DomainTokenList {
    param(
        [Parameter(Mandatory)]
        [string[]]$Tokens
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.Generic.List[string]

    foreach ($token in $Tokens) {
        $value = Normalize-TextValue -Value $token
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($seen.Add($value)) {
            $ordered.Add($value) | Out-Null
        }
    }

    if ($ordered.Count -eq 0) {
        return $null
    }

    return ($ordered -join ", ")
}

function Merge-DomainValues {
    param(
        [AllowEmptyString()]
        [string]$ExistingDomains,

        [AllowEmptyString()]
        [string]$NewDomains
    )

    return Join-DomainTokenList -Tokens @(
        (Convert-ToDomainTokenList -DomainsText $ExistingDomains) +
        (Convert-ToDomainTokenList -DomainsText $NewDomains)
    )
}

function Merge-NoteValues {
    param(
        [AllowEmptyString()]
        [string]$ExistingNote,

        [AllowEmptyString()]
        [string]$NewNote
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($ExistingNote, $NewNote)) {
        $value = Normalize-TextValue -Value $candidate
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($values -notcontains $value) {
            $values.Add($value) | Out-Null
        }
    }

    if ($values.Count -eq 0) {
        return $null
    }

    return ($values -join " ; ")
}

function New-ManagedRouteEntry {
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,

        [AllowEmptyString()]
        [string]$Domains,

        [AllowEmptyString()]
        [string]$Note
    )

    return [pscustomobject]@{
        IPAddress = $IPAddress
        Domains   = Normalize-TextValue -Value $Domains
        Note      = Normalize-TextValue -Value $Note
    }
}

function Convert-RouteListLineToEntry {
    param(
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory)]
        [int]$LineNumber
    )

    $value = $Line.Trim()
    if (-not $value) {
        return $null
    }

    if ($value.StartsWith("#")) {
        return $null
    }

    $parts = @($value -split "\|", 3 | ForEach-Object { $_.Trim() })
    $ipAddress = $parts[0]
    if (-not (Test-Ipv4Address -Address $ipAddress)) {
        throw "Invalid IPv4 address in ${RouteListPath} at line ${LineNumber}: $ipAddress"
    }

    $domains = $null
    $note = $null

    if ($parts.Count -ge 2) {
        $domains = Join-DomainTokenList -Tokens (Convert-ToDomainTokenList -DomainsText $parts[1])
    }

    if ($parts.Count -ge 3) {
        $note = Normalize-TextValue -Value $parts[2]
    }

    return New-ManagedRouteEntry -IPAddress $ipAddress -Domains $domains -Note $note
}

function Merge-ManagedRouteEntries {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $entriesByIp = @{}

    foreach ($entry in $Entries) {
        $ipAddress = $entry.IPAddress
        if ($entriesByIp.ContainsKey($ipAddress)) {
            $existing = $entriesByIp[$ipAddress]
            $existing.Domains = Merge-DomainValues -ExistingDomains $existing.Domains -NewDomains $entry.Domains
            $existing.Note = Merge-NoteValues -ExistingNote $existing.Note -NewNote $entry.Note
            continue
        }

        $entriesByIp[$ipAddress] = New-ManagedRouteEntry -IPAddress $entry.IPAddress -Domains $entry.Domains -Note $entry.Note
    }

    return @($entriesByIp.Values | Sort-Object IPAddress)
}

function Get-ManagedRouteEntries {
    Ensure-RouteListFile

    $rawEntries = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $RouteListPath) {
        $lineNumber++
        $entry = Convert-RouteListLineToEntry -Line $line -LineNumber $lineNumber
        if ($null -ne $entry) {
            $rawEntries.Add($entry) | Out-Null
        }
    }

    return Merge-ManagedRouteEntries -Entries @($rawEntries | ForEach-Object { $_ })
}

function Get-ConfiguredDnsResolvers {
    Ensure-DnsResolverListFile

    $resolvers = foreach ($line in Get-Content -LiteralPath $DnsResolverListPath) {
        $value = $line.Trim()
        if (-not $value) {
            continue
        }

        if ($value.StartsWith("#")) {
            continue
        }

        if (-not (Test-Ipv4Address -Address $value)) {
            throw "Invalid IPv4 address in ${DnsResolverListPath}: $value"
        }

        $value
    }

    return @($resolvers | Sort-Object -Unique)
}

function Convert-ManagedRouteEntryToLine {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Entry
    )

    $ipAddress = $Entry.IPAddress
    $domains = Normalize-TextValue -Value $Entry.Domains
    $note = Normalize-TextValue -Value $Entry.Note

    if ([string]::IsNullOrWhiteSpace($domains) -and [string]::IsNullOrWhiteSpace($note)) {
        return $ipAddress
    }

    if ([string]::IsNullOrWhiteSpace($note)) {
        return ("{0} | {1}" -f $ipAddress, $domains)
    }

    if ([string]::IsNullOrWhiteSpace($domains)) {
        return ("{0} |  | {1}" -f $ipAddress, $note)
    }

    return ("{0} | {1} | {2}" -f $ipAddress, $domains, $note)
}

function Save-ManagedRouteEntries {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $mergedEntries = Merge-ManagedRouteEntries -Entries $Entries
    $content = New-Object System.Collections.Generic.List[string]

    foreach ($line in Get-RouteListHeaderLines) {
        $content.Add($line) | Out-Null
    }

    $content.Add("") | Out-Null

    foreach ($entry in $mergedEntries) {
        $content.Add((Convert-ManagedRouteEntryToLine -Entry $entry)) | Out-Null
    }

    Set-Content -LiteralPath $RouteListPath -Value $content -Encoding UTF8
}

function Get-ManagedIpAddresses {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    return @($Entries | ForEach-Object { $_.IPAddress })
}

function Get-ManagedEntryLookup {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $lookup = @{}
    foreach ($entry in $Entries) {
        $lookup[$entry.IPAddress] = $entry
    }

    return $lookup
}

function Join-DisplayValues {
    param(
        [Parameter(Mandatory)]
        [string[]]$Values
    )

    $items = @(
        $Values |
        ForEach-Object { Normalize-TextValue -Value $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )

    if ($items.Count -eq 0) {
        return "-"
    }

    return ($items -join ", ")
}

function Compare-StringSets {
    param(
        [Parameter(Mandatory)]
        [string[]]$Left,

        [Parameter(Mandatory)]
        [string[]]$Right
    )

    $leftItems = @($Left | Sort-Object -Unique)
    $rightItems = @($Right | Sort-Object -Unique)

    if ($leftItems.Count -ne $rightItems.Count) {
        return $false
    }

    for ($i = 0; $i -lt $leftItems.Count; $i++) {
        if ($leftItems[$i] -ne $rightItems[$i]) {
            return $false
        }
    }

    return $true
}

function Get-DomainRefreshDefinitions {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $definitions = @{}

    foreach ($entry in $Entries) {
        $domainTokens = @(Convert-ToDomainTokenList -DomainsText $entry.Domains)
        foreach ($domainToken in $domainTokens) {
            if (-not $definitions.ContainsKey($domainToken)) {
                $definitions[$domainToken] = [pscustomobject]@{
                    Domain = $domainToken
                    OldIPs = New-Object System.Collections.Generic.List[string]
                    Note   = $null
                }
            }

            $definition = $definitions[$domainToken]
            $definition.OldIPs.Add($entry.IPAddress) | Out-Null
            $definition.Note = Merge-NoteValues -ExistingNote $definition.Note -NewNote $entry.Note
        }
    }

    return @($definitions.Values | Sort-Object Domain)
}

function Get-DefaultLanRoute {
    $vpnPattern = "openvpn|sophos|fortinet|vpn|tap|dco"

    $candidates = foreach ($route in Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($route.NextHop) -or $route.NextHop -eq "0.0.0.0") {
            continue
        }

        $adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
        if ($null -eq $adapter) {
            continue
        }

        if ($adapter.Status -ne "Up") {
            continue
        }

        if ($adapter.Name -match $vpnPattern -or $adapter.InterfaceDescription -match $vpnPattern) {
            continue
        }

        [pscustomobject]@{
            InterfaceIndex       = $route.ifIndex
            InterfaceAlias       = $route.InterfaceAlias
            InterfaceDescription = $adapter.InterfaceDescription
            NextHop              = $route.NextHop
            RouteMetric          = $route.RouteMetric
        }
    }

    $selected = $candidates | Sort-Object RouteMetric, InterfaceIndex | Select-Object -First 1
    if ($null -eq $selected) {
        throw "Could not detect an active non-VPN default gateway."
    }

    return $selected
}

function Get-ManagedPersistentRoutes {
    param(
        [Parameter(Mandatory)]
        [string[]]$IpAddresses
    )

    if ($IpAddresses.Count -eq 0) {
        return @()
    }

    $prefixes = $IpAddresses | ForEach-Object { "$_/32" }

    return @(Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
        Where-Object { $prefixes -contains $_.DestinationPrefix } |
        Sort-Object DestinationPrefix)
}

function Get-ManagedPersistentRouteRows {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $entryLookup = Get-ManagedEntryLookup -Entries $Entries
    $routes = Get-ManagedPersistentRoutes -IpAddresses (Get-ManagedIpAddresses -Entries $Entries)

    return @(
        foreach ($route in $routes) {
            $ipAddress = $route.DestinationPrefix -replace "/32$", ""
            $entry = $entryLookup[$ipAddress]

            [pscustomobject]@{
                IPAddress   = $ipAddress
                Domains     = $entry.Domains
                Note        = $entry.Note
                NextHop     = $route.NextHop
                RouteMetric = $route.RouteMetric
                Store       = $route.Store
            }
        }
    )
}

function Get-AllPersistentHostRoutes {
    return @(Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DestinationPrefix -like "*/32" -and
            -not [string]::IsNullOrWhiteSpace($_.NextHop) -and
            $_.NextHop -ne "0.0.0.0"
        } |
        Sort-Object DestinationPrefix)
}

function Get-UnmanagedPersistentHostRoutes {
    param(
        [Parameter(Mandatory)]
        [string[]]$ManagedIpAddresses
    )

    $managedPrefixes = $ManagedIpAddresses | ForEach-Object { "$_/32" }
    return @(Get-AllPersistentHostRoutes | Where-Object { $managedPrefixes -notcontains $_.DestinationPrefix })
}

function Invoke-RouteCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$IgnoreExitCode
    )

    $output = & route.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        $message = ($output | Out-String).Trim()
        throw "route.exe $($Arguments -join ' ') failed with exit code $exitCode. $message"
    }

    return $output
}

function Get-SystemDnsARecords {
    param(
        [Parameter(Mandatory)]
        [string]$DomainName
    )

    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            $records = @(
                Resolve-DnsName -Name $DomainName -Type A -ErrorAction Stop |
                Where-Object { $_.Type -eq "A" -and -not [string]::IsNullOrWhiteSpace($_.IPAddress) } |
                Select-Object -ExpandProperty IPAddress -Unique
            )

            if ($records.Count -gt 0) {
                return @($records | Sort-Object -Unique)
            }
        }
        catch {
        }
    }

    return @(
        [System.Net.Dns]::GetHostAddresses($DomainName) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Sort-Object -Unique
    )
}

function Get-ResolverARecords {
    param(
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [string]$ResolverIPAddress
    )

    return @(
        Resolve-DnsName -Name $DomainName -Type A -Server $ResolverIPAddress -ErrorAction Stop |
        Where-Object { $_.Type -eq "A" -and -not [string]::IsNullOrWhiteSpace($_.IPAddress) } |
        Select-Object -ExpandProperty IPAddress -Unique |
        Sort-Object -Unique
    )
}

function Ensure-TemporaryResolverBypassRoute {
    param(
        [Parameter(Mandatory)]
        [string]$ResolverIPAddress
    )

    $gateway = Get-DefaultLanRoute
    $destinationPrefix = "$ResolverIPAddress/32"

    $existing = @(
        Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
        Where-Object {
            $_.NextHop -eq $gateway.NextHop -and
            $_.InterfaceIndex -eq $gateway.InterfaceIndex
        }
    )

    if ($existing.Count -gt 0) {
        return [pscustomobject]@{
            Added         = $false
            Gateway       = $gateway
            ResolverIP    = $ResolverIPAddress
            RoutePrefix   = $destinationPrefix
        }
    }

    New-NetRoute `
        -AddressFamily IPv4 `
        -PolicyStore ActiveStore `
        -DestinationPrefix $destinationPrefix `
        -InterfaceIndex $gateway.InterfaceIndex `
        -NextHop $gateway.NextHop `
        -RouteMetric 1 `
        -ErrorAction Stop | Out-Null

    return [pscustomobject]@{
        Added         = $true
        Gateway       = $gateway
        ResolverIP    = $ResolverIPAddress
        RoutePrefix   = $destinationPrefix
    }
}

function Remove-TemporaryResolverBypassRoute {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$RouteInfo
    )

    if (-not $RouteInfo.Added) {
        return
    }

    Remove-NetRoute `
        -AddressFamily IPv4 `
        -PolicyStore ActiveStore `
        -DestinationPrefix $RouteInfo.RoutePrefix `
        -InterfaceIndex $RouteInfo.Gateway.InterfaceIndex `
        -NextHop $RouteInfo.Gateway.NextHop `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
}

function Show-Header {
    Clear-Host

    Write-Host "VPN Bypass Route Manager" -ForegroundColor Cyan
    Write-Host "List file: $RouteListPath"
    Write-Host "Administrator mode: $(if (Test-IsAdministrator) { 'Yes' } else { 'No' })"

    try {
        $gateway = Get-DefaultLanRoute
        Write-Host ("Detected non-VPN gateway: {0} via {1}" -f $gateway.NextHop, $gateway.InterfaceAlias) -ForegroundColor Green
    }
    catch {
        Write-Host ("Detected non-VPN gateway: unavailable ({0})" -f $_.Exception.Message) -ForegroundColor Red
    }

    $entries = @(Get-ManagedRouteEntries)
    $managedRoutes = @(Get-ManagedPersistentRoutes -IpAddresses (Get-ManagedIpAddresses -Entries $entries))
    $unmanagedRoutes = @(Get-UnmanagedPersistentHostRoutes -ManagedIpAddresses (Get-ManagedIpAddresses -Entries $entries))
    $entriesWithDomains = @($entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Domains) }).Count

    Write-Host ("Managed entries in file: {0}" -f $entries.Count)
    Write-Host ("Managed entries with domains: {0}" -f $entriesWithDomains)
    Write-Host ("Managed persistent routes in Windows: {0}" -f $managedRoutes.Count)
    Write-Host ("Other persistent /32 routes in Windows: {0}" -f $unmanagedRoutes.Count)
    Write-Host ""
    Write-Host "1. Show managed IP list with domains/notes"
    Write-Host "2. Apply or refresh managed routes to the detected gateway"
    Write-Host "3. Remove managed routes from Windows"
    Write-Host "4. Show managed persistent routes from Windows"
    Write-Host "5. Add IPs or update domain/website metadata"
    Write-Host "6. Remove IPs from managed list"
    Write-Host "7. Show other persistent /32 routes not in managed list"
    Write-Host "8. Import other persistent /32 routes into managed list"
    Write-Host "9. Resolve a domain and add its current IPv4 addresses"
    Write-Host "10. Refresh saved domain entries from current DNS"
    Write-Host "11. Open the list file in Notepad"
    Write-Host "12. Show OpenVPN net_gateway lines for the current list"
    Write-Host "0. Exit"
    Write-Host ""
}

function Show-ManagedIpList {
    $entries = @(Get-ManagedRouteEntries)

    Write-Host ""
    Write-Host "Managed IP list" -ForegroundColor Cyan

    if ($entries.Count -eq 0) {
        Write-Host "The list file is empty." -ForegroundColor Yellow
        return
    }

    $rows = @(
        for ($i = 0; $i -lt $entries.Count; $i++) {
            [pscustomobject]@{
                Index    = $i + 1
                IPAddress = $entries[$i].IPAddress
                Domains  = $entries[$i].Domains
                Note     = $entries[$i].Note
            }
        }
    )

    $rows | Format-Table -AutoSize Index, IPAddress, Domains, Note | Out-Host
}

function Apply-ManagedRoutes {
    if (-not (Test-IsAdministrator)) {
        if (Request-Elevation -ActionName "Apply") {
            return $true
        }

        return $false
    }

    $entries = @(Get-ManagedRouteEntries)
    if ($entries.Count -eq 0) {
        throw "The managed list is empty. Add at least one IP first."
    }

    $gateway = Get-DefaultLanRoute
    foreach ($entry in $entries) {
        Invoke-RouteCommand -Arguments @("delete", $entry.IPAddress) -IgnoreExitCode | Out-Null
        Invoke-RouteCommand -Arguments @("-p", "add", $entry.IPAddress, "mask", "255.255.255.255", $gateway.NextHop, "metric", "1") | Out-Null
    }

    Write-Host ""
    Write-Host ("Applied {0} persistent routes to gateway {1} via {2}." -f $entries.Count, $gateway.NextHop, $gateway.InterfaceAlias) -ForegroundColor Green
    Get-ManagedPersistentRouteRows -Entries $entries |
        Format-Table -AutoSize IPAddress, Domains, Note, NextHop, RouteMetric, Store |
        Out-Host

    return $false
}

function Remove-ManagedRoutes {
    if (-not (Test-IsAdministrator)) {
        if (Request-Elevation -ActionName "Remove") {
            return $true
        }

        return $false
    }

    $entries = @(Get-ManagedRouteEntries)
    if ($entries.Count -eq 0) {
        Write-Host "The managed list is empty. Nothing to remove." -ForegroundColor Yellow
        return $false
    }

    foreach ($entry in $entries) {
        Invoke-RouteCommand -Arguments @("delete", $entry.IPAddress) -IgnoreExitCode | Out-Null
    }

    Write-Host ""
    Write-Host ("Removed {0} managed routes from Windows." -f $entries.Count) -ForegroundColor Green
    $entries | Format-Table -AutoSize IPAddress, Domains, Note | Out-Host

    return $false
}

function Add-OrUpdateManagedEntries {
    $entries = @(Get-ManagedRouteEntries)
    $entryLookup = Get-ManagedEntryLookup -Entries $entries

    Write-Host ""
    Write-Host "You can enter one or more IPv4 addresses and optionally attach the same domains/notes to all of them." -ForegroundColor Cyan
    $inputText = Read-Host "Enter one or more IPv4 addresses separated by spaces or commas"
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        Write-Host "Nothing entered." -ForegroundColor Yellow
        return
    }

    $ipAddresses = @(
        $inputText -split "[,\s]+" |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($ipAddresses.Count -eq 0) {
        Write-Host "Nothing entered." -ForegroundColor Yellow
        return
    }

    foreach ($ipAddress in $ipAddresses) {
        if (-not (Test-Ipv4Address -Address $ipAddress)) {
            throw "Invalid IPv4 address: $ipAddress"
        }
    }

    Write-Host ""
    $domainsInput = Read-Host "Optional domain names / website labels (comma-separated, blank = keep existing, - = clear)"
    $noteInput = Read-Host "Optional note (blank = keep existing, - = clear)"

    $updatedEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $updatedEntries.Add((New-ManagedRouteEntry -IPAddress $entry.IPAddress -Domains $entry.Domains -Note $entry.Note)) | Out-Null
    }

    foreach ($ipAddress in $ipAddresses) {
        if ($entryLookup.ContainsKey($ipAddress)) {
            $current = $updatedEntries | Where-Object { $_.IPAddress -eq $ipAddress } | Select-Object -First 1
        }
        else {
            $current = New-ManagedRouteEntry -IPAddress $ipAddress -Domains $null -Note $null
            $updatedEntries.Add($current) | Out-Null
        }

        if ($domainsInput -eq "-") {
            $current.Domains = $null
        }
        elseif (-not [string]::IsNullOrWhiteSpace($domainsInput)) {
            $current.Domains = Merge-DomainValues -ExistingDomains $current.Domains -NewDomains $domainsInput
        }

        if ($noteInput -eq "-") {
            $current.Note = $null
        }
        elseif (-not [string]::IsNullOrWhiteSpace($noteInput)) {
            $current.Note = $noteInput.Trim()
        }
    }

    Save-ManagedRouteEntries -Entries @($updatedEntries | ForEach-Object { $_ })

    Write-Host ""
    Write-Host "Saved/updated entries:" -ForegroundColor Green
    @(Get-ManagedRouteEntries | Where-Object { $ipAddresses -contains $_.IPAddress }) |
        Format-Table -AutoSize IPAddress, Domains, Note |
        Out-Host
}

function Remove-ManagedIps {
    $entries = @(Get-ManagedRouteEntries)
    if ($entries.Count -eq 0) {
        Write-Host "The managed list is empty." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Current managed IPs" -ForegroundColor Cyan
    @(
        for ($i = 0; $i -lt $entries.Count; $i++) {
            [pscustomobject]@{
                Index     = $i + 1
                IPAddress = $entries[$i].IPAddress
                Domains   = $entries[$i].Domains
                Note      = $entries[$i].Note
            }
        }
    ) | Format-Table -AutoSize Index, IPAddress, Domains, Note | Out-Host

    Write-Host ""
    $inputText = Read-Host "Enter one or more numbers or IPs to remove from the managed list"
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        Write-Host "Nothing entered." -ForegroundColor Yellow
        return
    }

    $tokens = @($inputText -split "[,\s]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $toRemove = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($token in $tokens) {
        if ($token -match "^\d+$") {
            $index = [int]$token
            if ($index -lt 1 -or $index -gt $entries.Count) {
                throw "Invalid item number: $token"
            }

            [void]$toRemove.Add($entries[$index - 1].IPAddress)
            continue
        }

        if (-not (Test-Ipv4Address -Address $token)) {
            throw "Invalid entry: $token"
        }

        [void]$toRemove.Add($token)
    }

    $remaining = @($entries | Where-Object { -not $toRemove.Contains($_.IPAddress) })
    Save-ManagedRouteEntries -Entries $remaining

    Write-Host ""
    Write-Host "Removed from managed list:" -ForegroundColor Green
    @($toRemove) | Sort-Object | ForEach-Object { Write-Host "  $_" }
}

function Show-ManagedPersistentRoutesAction {
    $entries = @(Get-ManagedRouteEntries)
    $rows = @(Get-ManagedPersistentRouteRows -Entries $entries)

    Write-Host ""
    Write-Host "Managed persistent routes from Windows" -ForegroundColor Cyan
    if ($rows.Count -eq 0) {
        Write-Host "No matching persistent routes were found." -ForegroundColor Yellow
        return
    }

    $rows | Format-Table -AutoSize IPAddress, Domains, Note, NextHop, RouteMetric, Store | Out-Host
}

function Show-UnmanagedPersistentRoutesAction {
    $entries = @(Get-ManagedRouteEntries)
    $unmanaged = @(Get-UnmanagedPersistentHostRoutes -ManagedIpAddresses (Get-ManagedIpAddresses -Entries $entries))

    Write-Host ""
    Write-Host "Other persistent /32 routes not in the managed list" -ForegroundColor Cyan
    if ($unmanaged.Count -eq 0) {
        Write-Host "No unmanaged persistent /32 routes were found." -ForegroundColor Yellow
        return
    }

    $unmanaged | Format-Table -AutoSize DestinationPrefix, NextHop, RouteMetric, Store | Out-Host
}

function Import-UnmanagedPersistentRoutes {
    $entries = @(Get-ManagedRouteEntries)
    $unmanaged = @(Get-UnmanagedPersistentHostRoutes -ManagedIpAddresses (Get-ManagedIpAddresses -Entries $entries))

    if ($unmanaged.Count -eq 0) {
        Write-Host "No unmanaged persistent /32 routes were found." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "The following routes can be imported into the managed list:" -ForegroundColor Cyan
    $unmanaged | Format-Table -AutoSize DestinationPrefix, NextHop, RouteMetric, Store | Out-Host

    $answer = Read-Host "Import all of them into bypass-routes.txt? (Y/N)"
    if ($answer -notmatch "^(y|yes)$") {
        Write-Host "Import cancelled." -ForegroundColor Yellow
        return
    }

    $mergedEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $mergedEntries.Add((New-ManagedRouteEntry -IPAddress $entry.IPAddress -Domains $entry.Domains -Note $entry.Note)) | Out-Null
    }

    foreach ($route in $unmanaged) {
        $mergedEntries.Add((New-ManagedRouteEntry -IPAddress ($route.DestinationPrefix -replace "/32$", "") -Domains $null -Note $null)) | Out-Null
    }

    Save-ManagedRouteEntries -Entries @($mergedEntries | ForEach-Object { $_ })
    Write-Host ("Imported {0} IPs into the managed list." -f $unmanaged.Count) -ForegroundColor Green
}

function Resolve-Ipv4AddressesForDomain {
    param(
        [Parameter(Mandatory)]
        [string]$DomainName
    )

    $normalizedDomain = Normalize-TextValue -Value $DomainName
    if ([string]::IsNullOrWhiteSpace($normalizedDomain)) {
        throw "A domain name is required."
    }

    $resolverErrors = New-Object System.Collections.Generic.List[string]
    $configuredResolvers = @(Get-ConfiguredDnsResolvers)

    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        foreach ($resolverIp in $configuredResolvers) {
            try {
                $resolvedIps = @(Get-ResolverARecords -DomainName $normalizedDomain -ResolverIPAddress $resolverIp)
                if ($resolvedIps.Count -gt 0) {
                    return [pscustomobject]@{
                        IPAddresses = @($resolvedIps)
                        Source      = "Public DNS server $resolverIp"
                    }
                }
            }
            catch {
                $resolverErrors.Add(("Resolver {0} direct query failed: {1}" -f $resolverIp, $_.Exception.Message)) | Out-Null
            }

            if (Test-IsAdministrator) {
                $routeInfo = $null
                try {
                    $routeInfo = Ensure-TemporaryResolverBypassRoute -ResolverIPAddress $resolverIp
                    $resolvedIps = @(Get-ResolverARecords -DomainName $normalizedDomain -ResolverIPAddress $resolverIp)
                    if ($resolvedIps.Count -gt 0) {
                        $source = "Public DNS server $resolverIp via temporary bypass route"
                        return [pscustomobject]@{
                            IPAddresses = @($resolvedIps)
                            Source      = $source
                        }
                    }
                }
                catch {
                    $resolverErrors.Add(("Resolver {0} with bypass route failed: {1}" -f $resolverIp, $_.Exception.Message)) | Out-Null
                }
                finally {
                    if ($null -ne $routeInfo) {
                        Remove-TemporaryResolverBypassRoute -RouteInfo $routeInfo
                    }
                }
            }
        }
    }

    try {
        $resolvedIps = @(Get-SystemDnsARecords -DomainName $normalizedDomain)
        if ($resolvedIps.Count -gt 0) {
            return [pscustomobject]@{
                IPAddresses = @($resolvedIps)
                Source      = "Current system DNS path"
            }
        }
    }
    catch {
        $resolverErrors.Add(("System DNS resolution failed: {0}" -f $_.Exception.Message)) | Out-Null
    }

    $detail = $resolverErrors -join " | "
    if ([string]::IsNullOrWhiteSpace($detail)) {
        throw "No IPv4 A records were found for '$normalizedDomain'."
    }

    throw "Failed to resolve '$normalizedDomain'. $detail"
}

function Resolve-DomainAndAddEntries {
    Write-Host ""
    $domainName = Read-Host "Enter a domain name to resolve and add"
    if ([string]::IsNullOrWhiteSpace($domainName)) {
        Write-Host "Nothing entered." -ForegroundColor Yellow
        return
    }

    $resolutionResult = Resolve-Ipv4AddressesForDomain -DomainName $domainName
    $resolvedIps = @($resolutionResult.IPAddresses)

    Write-Host ""
    Write-Host ("Resolution source: {0}" -f $resolutionResult.Source) -ForegroundColor Green
    Write-Host ("Resolved IPv4 addresses for {0}:" -f $domainName) -ForegroundColor Cyan
    $resolvedIps | ForEach-Object { Write-Host "  $_" }

    $noteInput = Read-Host "Optional note to store for these IPs"
    $answer = Read-Host "Add these IPs to the managed list with this domain? (Y/N)"
    if ($answer -notmatch "^(y|yes)$") {
        Write-Host "Add cancelled." -ForegroundColor Yellow
        return
    }

    $entries = @(Get-ManagedRouteEntries)
    $updatedEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $updatedEntries.Add((New-ManagedRouteEntry -IPAddress $entry.IPAddress -Domains $entry.Domains -Note $entry.Note)) | Out-Null
    }

    foreach ($ipAddress in $resolvedIps) {
        $existing = $updatedEntries | Where-Object { $_.IPAddress -eq $ipAddress } | Select-Object -First 1
        if ($null -eq $existing) {
            $existing = New-ManagedRouteEntry -IPAddress $ipAddress -Domains $null -Note $null
            $updatedEntries.Add($existing) | Out-Null
        }

        $existing.Domains = Merge-DomainValues -ExistingDomains $existing.Domains -NewDomains $domainName
        if (-not [string]::IsNullOrWhiteSpace($noteInput)) {
            $existing.Note = $noteInput.Trim()
        }
    }

    Save-ManagedRouteEntries -Entries @($updatedEntries | ForEach-Object { $_ })

    Write-Host ""
    Write-Host "Saved/updated entries:" -ForegroundColor Green
    @(Get-ManagedRouteEntries | Where-Object { $resolvedIps -contains $_.IPAddress }) |
        Format-Table -AutoSize IPAddress, Domains, Note |
        Out-Host
}

function Refresh-SavedDomainEntries {
    $entries = @(Get-ManagedRouteEntries)
    $entriesWithDomains = @($entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Domains) })
    $entriesWithoutDomains = @($entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Domains) })

    if ($entriesWithDomains.Count -eq 0) {
        Write-Host "There are no managed entries with saved domains to refresh." -ForegroundColor Yellow
        return $false
    }

    $definitions = @(Get-DomainRefreshDefinitions -Entries $entriesWithDomains)
    $refreshedEntries = New-Object System.Collections.Generic.List[object]
    $previewRows = New-Object System.Collections.Generic.List[object]
    $changedDomainCount = 0

    foreach ($definition in $definitions) {
        $oldIps = @($definition.OldIPs | Sort-Object -Unique)
        $newIps = @()
        $status = $null
        $source = $null
        $detail = $null

        try {
            $resolutionResult = Resolve-Ipv4AddressesForDomain -DomainName $definition.Domain
            $newIps = @($resolutionResult.IPAddresses | Sort-Object -Unique)
            $source = $resolutionResult.Source

            if (Compare-StringSets -Left $oldIps -Right $newIps) {
                $status = "Unchanged"
            }
            else {
                $status = "Refreshed"
                $changedDomainCount++
            }
        }
        catch {
            $newIps = $oldIps
            $status = "Kept old IPs"
            $detail = $_.Exception.Message
        }

        foreach ($ipAddress in $newIps) {
            $refreshedEntries.Add((New-ManagedRouteEntry -IPAddress $ipAddress -Domains $definition.Domain -Note $definition.Note)) | Out-Null
        }

        $previewRows.Add([pscustomobject]@{
            Domain = $definition.Domain
            OldIPs = Join-DisplayValues -Values $oldIps
            NewIPs = Join-DisplayValues -Values $newIps
            Status = $status
            Source = if (-not [string]::IsNullOrWhiteSpace($detail)) { $detail } else { $source }
        }) | Out-Null
    }

    Write-Host ""
    Write-Host "Domain refresh preview" -ForegroundColor Cyan
    @($previewRows | ForEach-Object { $_ }) |
        Format-Table -AutoSize Domain, OldIPs, NewIPs, Status, Source |
        Out-Host

    $answer = Read-Host "Save this refreshed domain-to-IP mapping into bypass-routes.txt? (Y/N)"
    if ($answer -notmatch "^(y|yes)$") {
        Write-Host "Refresh cancelled." -ForegroundColor Yellow
        return $false
    }

    $finalEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entriesWithoutDomains) {
        $finalEntries.Add((New-ManagedRouteEntry -IPAddress $entry.IPAddress -Domains $entry.Domains -Note $entry.Note)) | Out-Null
    }

    foreach ($entry in $refreshedEntries) {
        $finalEntries.Add($entry) | Out-Null
    }

    Save-ManagedRouteEntries -Entries @($finalEntries | ForEach-Object { $_ })

    Write-Host ""
    Write-Host ("Saved refreshed domain IPs. Domains changed: {0}" -f $changedDomainCount) -ForegroundColor Green
    if ($changedDomainCount -gt 0) {
        Write-Host "Run option 2 to refresh the Windows routes for the updated IP list." -ForegroundColor Yellow
    }

    return $false
}

function Open-RouteListInNotepad {
    Ensure-RouteListFile
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$RouteListPath`""
    Write-Host "Opened the list file in Notepad." -ForegroundColor Green
}

function Show-OvpnNetGatewayLines {
    $entries = @(Get-ManagedRouteEntries)

    Write-Host ""
    Write-Host "OpenVPN lines for the current list" -ForegroundColor Cyan

    if ($entries.Count -eq 0) {
        Write-Host "The managed list is empty." -ForegroundColor Yellow
        return
    }

    foreach ($entry in $entries) {
        $line = "route {0} 255.255.255.255 net_gateway" -f $entry.IPAddress
        $commentParts = New-Object System.Collections.Generic.List[string]

        if (-not [string]::IsNullOrWhiteSpace($entry.Domains)) {
            $commentParts.Add($entry.Domains) | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.Note)) {
            $commentParts.Add($entry.Note) | Out-Null
        }

        if ($commentParts.Count -gt 0) {
            Write-Host ("{0}    # {1}" -f $line, ($commentParts -join " | "))
        }
        else {
            Write-Host $line
        }
    }
}

function Invoke-MenuAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12")]
        [string]$Choice
    )

    switch ($Choice) {
        "1" { Show-ManagedIpList }
        "2" { return (Apply-ManagedRoutes) }
        "3" { return (Remove-ManagedRoutes) }
        "4" { Show-ManagedPersistentRoutesAction }
        "5" { Add-OrUpdateManagedEntries }
        "6" { Remove-ManagedIps }
        "7" { Show-UnmanagedPersistentRoutesAction }
        "8" { Import-UnmanagedPersistentRoutes }
        "9" { Resolve-DomainAndAddEntries }
        "10" { return (Refresh-SavedDomainEntries) }
        "11" { Open-RouteListInNotepad }
        "12" { Show-OvpnNetGatewayLines }
    }

    return $false
}

function Run-InitialAction {
    if ([string]::IsNullOrWhiteSpace($InitialAction)) {
        return
    }

    try {
        $map = @{
            Apply  = "2"
            Remove = "3"
        }

        [void](Invoke-MenuAction -Choice $map[$InitialAction])
    }
    catch {
        $script:ExitCode = 1
        Write-Host ("Initial action failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Pause-Console
    }
}

Ensure-RouteListFile
Run-InitialAction

try {
    while ($true) {
        Show-Header
        $choice = Read-Host "Choose an option"

        if ($choice -eq "0") {
            break
        }

        if ($choice -notin @("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12")) {
            Write-Host ""
            Write-Host "Invalid option." -ForegroundColor Red
            Pause-Console
            continue
        }

        try {
            $shouldExitAfterRelaunch = Invoke-MenuAction -Choice $choice
            if ($shouldExitAfterRelaunch) {
                break
            }
        }
        catch {
            $script:ExitCode = 1
            Write-Host ""
            Write-Host ("Action failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }

        Pause-Console
    }
}
catch {
    $script:ExitCode = 1
    Write-Host ("Script failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    if (-not $script:SuppressPauseOnExit -and (Should-PauseOnExit)) {
        if ($script:ExitCode -eq 0) {
            Pause-Console "Script finished. Press Enter to close..."
        }
        else {
            Pause-Console "Script finished with errors. Press Enter to close..."
        }
    }
}

exit $script:ExitCode
