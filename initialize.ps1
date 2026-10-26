$ErrorActionPreference = 'Stop'
$envPath = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    [IO.File]::WriteAllText($envPath, "PIHOLE_PASSWORD=$password`n", (New-Object Text.UTF8Encoding($false)))
    Write-Output 'Created .env with a random admin password.'
}
docker network inspect local-apps *> $null
if ($LASTEXITCODE -ne 0) {
    docker network create local-apps | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the shared local-apps network.' }
}
