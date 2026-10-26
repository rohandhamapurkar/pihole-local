param([Parameter(Mandatory = $true)][ValidateSet('Enable','Restore')][string]$Action)
$ErrorActionPreference = 'Stop'
$backupPath = Join-Path $PSScriptRoot 'dns-backup.json'
$logPath = Join-Path $PSScriptRoot 'dns-operation.log'
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run dns.ps1 from administrator PowerShell.' }
    if ($Action -eq 'Enable') {
        foreach ($server in @('127.0.0.1','::1')) {
            $answer = @(Resolve-DnsName example.com -Server $server -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress)
            if ($answer.Count -eq 0) { throw "DNS check failed for $server; leaving adapter settings unchanged." }
        }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $records = @()
            $adapters = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Where-Object {
                @(Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count -gt 0
            })
            if ($adapters.Count -eq 0) { throw 'No active physical adapter with a default route found.' }
            foreach ($adapter in $adapters) {
                $guid = ([guid]$adapter.InterfaceGuid).ToString('B')
                foreach ($dns in (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex)) {
                    $service = if ([int]$dns.AddressFamily -eq 2) { 'Tcpip' } else { 'Tcpip6' }
                    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$guid"
                    $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
                    $records += [pscustomobject]@{
                        InterfaceGuid = $guid
                        InterfaceAlias = $adapter.Name
                        AddressFamily = [int]$dns.AddressFamily
                        Automatic = [string]::IsNullOrWhiteSpace([string]$registry.NameServer)
                        ServerAddresses = @($dns.ServerAddresses)
                    }
                }
            }
            ConvertTo-Json -InputObject @($records) -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        }
    } elseif (-not (Test-Path -LiteralPath $backupPath)) {
        throw 'No dns-backup.json found.'
    }
    $records = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    foreach ($record in $records) {
        $adapter = Get-NetAdapter -IncludeHidden | Where-Object { ([guid]$_.InterfaceGuid).ToString('B') -eq $record.InterfaceGuid }
        if (-not $adapter) { throw "Cannot find original adapter $($record.InterfaceAlias)." }
        $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex | Where-Object { [int]$_.AddressFamily -eq [int]$record.AddressFamily }
        if ($Action -eq 'Restore') {
            if ($record.Automatic) { Set-DnsClientServerAddress -InputObject $dns -ResetServerAddresses }
            else { Set-DnsClientServerAddress -InputObject $dns -ServerAddresses @($record.ServerAddresses) }
        } else {
            $server = if ([int]$record.AddressFamily -eq 2) { '127.0.0.1' } else { '::1' }
            Set-DnsClientServerAddress -InputObject $dns -ServerAddresses @($server)
        }
    }
    Clear-DnsClientCache
    if ($Action -eq 'Enable') {
        $resolved = @(Resolve-DnsName example.com -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress)
        if ($resolved.Count -eq 0) { throw 'System DNS verification failed; run dns.ps1 -Action Restore.' }
    }
    "Success: $Action at $(Get-Date -Format o)" | Set-Content -LiteralPath $logPath
} catch {
    $originalError = $_
    if ($Action -eq 'Enable' -and (Test-Path -LiteralPath $backupPath)) {
        try { & $PSCommandPath -Action Restore } catch { "Rollback failed: $($_.Exception.Message)" | Add-Content -LiteralPath $logPath }
    }
    "Failed: $Action - $($originalError.Exception.Message)" | Add-Content -LiteralPath $logPath
    throw $originalError
}
