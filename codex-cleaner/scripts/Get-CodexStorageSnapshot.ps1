[CmdletBinding()]
param(
    [string]$CodexRoot,
    [string]$StateRoot,
    [string[]]$ProjectRoot = @(),
    [ValidateRange(1, 1000)]
    [int]$Top = 20,
    [ValidateRange(1, 3650)]
    [int]$ProtectRecentDays = 7,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$CurrentTaskId,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string[]]$AdditionalProtectedTaskId = @(),
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$platformName = if ($IsWindows) {
    'Windows'
}
elseif ($IsLinux) {
    'Linux'
}
elseif ($IsMacOS) {
    'macOS'
}
else {
    throw 'Unsupported operating system'
}
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}
$pathComparer = if ($IsWindows) {
    [StringComparer]::OrdinalIgnoreCase
}
else {
    [StringComparer]::Ordinal
}
if ([string]::IsNullOrWhiteSpace($CodexRoot)) {
    $configuredCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $CodexRoot = if ([string]::IsNullOrWhiteSpace($configuredCodexHome)) {
        Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.codex'
    }
    else {
        $configuredCodexHome
    }
}
if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    $configuredStateHome = [Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME')
    $StateRoot = if ([string]::IsNullOrWhiteSpace($configuredStateHome)) {
        $CodexRoot
    }
    else {
        $configuredStateHome
    }
}
$uuidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$rolloutNamePattern = "^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<id>$uuidPattern)$"
$scanErrors = [Collections.Generic.List[string]]::new()
$scanWarnings = [Collections.Generic.List[string]]::new()
$criticalScanErrors = [Collections.Generic.List[string]]::new()
$capturedAtUtc = [datetime]::UtcNow

function Add-ScanIssue {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Critical
    )

    $text = "${Category}: $Message"
    if ($Critical) {
        $criticalScanErrors.Add($text)
        $scanErrors.Add($text)
    }
    else {
        $scanWarnings.Add($text)
    }
}

function ConvertTo-PlatformPath {
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path
    if ($IsWindows) {
        if ($candidate.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
            $candidate = '\\' + $candidate.Substring(8)
        }
        elseif ($candidate.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
            $candidate = $candidate.Substring(4)
        }
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($candidate)
        $rootPath = [IO.Path]::GetPathRoot($fullPath)
        if ([string]::Equals(
            $fullPath.TrimEnd('\', '/'),
            $rootPath.TrimEnd('\', '/'),
            $pathComparison
        )) {
            return $rootPath
        }
        $fullPath.TrimEnd('\', '/')
    }
    catch {
        $candidate.TrimEnd('\', '/')
    }
}

function ConvertFrom-MountEscapedPath {
    param([Parameter(Mandatory)][string]$Path)

    $Path.
        Replace('\040', ' ').
        Replace('\011', "`t").
        Replace('\012', "`n").
        Replace('\134', '\')
}

function Get-PlatformMountInventory {
    $mounts = [Collections.Generic.HashSet[string]]::new($pathComparer)
    if ($IsWindows) {
        return [pscustomobject]@{
            Complete = $true
            Source = 'WindowsReparseMetadata'
            Paths = $mounts
            Errors = @()
        }
    }

    $errors = [Collections.Generic.List[string]]::new()
    if ($IsLinux) {
        $mountInfoPath = '/proc/self/mountinfo'
        if (-not (Test-Path -LiteralPath $mountInfoPath -PathType Leaf)) {
            $errors.Add("$mountInfoPath is unavailable")
        }
        else {
            try {
                foreach ($line in [IO.File]::ReadLines($mountInfoPath)) {
                    $separator = $line.IndexOf(' - ', [StringComparison]::Ordinal)
                    if ($separator -lt 0) { continue }
                    $fields = $line.Substring(0, $separator).Split(' ')
                    if ($fields.Count -lt 5) { continue }
                    $mountPath = ConvertFrom-MountEscapedPath -Path $fields[4]
                    [void]$mounts.Add((ConvertTo-PlatformPath -Path $mountPath))
                }
            }
            catch {
                $errors.Add($_.Exception.Message)
            }
        }
        return [pscustomobject]@{
            Complete = ($errors.Count -eq 0 -and $mounts.Count -gt 0)
            Source = 'proc-self-mountinfo'
            Paths = $mounts
            Errors = @($errors)
        }
    }

    $mountCommand = Get-Command mount -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $mountCommand) {
        $errors.Add('mount command is unavailable')
    }
    else {
        try {
            $mountOutput = @(& $mountCommand.Source 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("mount command exited with code $LASTEXITCODE")
            }
            foreach ($line in $mountOutput) {
                if ([string]$line -match '^.* on (?<path>.+) \([^)]+\)$') {
                    $mountPath = ConvertFrom-MountEscapedPath -Path $Matches.path
                    [void]$mounts.Add((ConvertTo-PlatformPath -Path $mountPath))
                }
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }
    [pscustomobject]@{
        Complete = ($errors.Count -eq 0 -and $mounts.Count -gt 0)
        Source = 'mount-command'
        Paths = $mounts
        Errors = @($errors)
    }
}

function Test-IsLinkLike {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $true
    }
    $linkType = $Item.PSObject.Properties['LinkType']
    if ($null -ne $linkType -and -not [string]::IsNullOrWhiteSpace([string]$linkType.Value)) {
        return $true
    }
    $false
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if (-not (Test-IsLinkLike -Item $item)) {
        return [IO.Path]::GetFullPath($item.FullName)
    }
    $target = [IO.File]::ResolveLinkTarget($item.FullName, $true)
    if ($null -eq $target -or -not $target.Exists) {
        throw "Executable link target cannot be resolved: $LiteralPath"
    }
    [IO.Path]::GetFullPath($target.FullName)
}

function Test-IsNestedMountPoint {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LiteralPath
    )

    if ($IsWindows -or $null -eq $script:mountInventory -or -not $script:mountInventory.Complete) {
        return $false
    }
    $rootPath = ConvertTo-PlatformPath -Path $Root
    $candidatePath = ConvertTo-PlatformPath -Path $LiteralPath
    (
        -not [string]::Equals($rootPath, $candidatePath, $pathComparison) -and
        $script:mountInventory.Paths.Contains($candidatePath)
    )
}

function Test-IsUnsafeTraversalEntry {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][IO.FileSystemInfo]$Item
    )

    (Test-IsLinkLike -Item $Item) -or
        (Test-IsNestedMountPoint -Root $Root -LiteralPath $Item.FullName)
}

function Get-CheckedChildren {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [switch]$File,
        [switch]$Directory,
        [switch]$Recurse,
        [string]$Filter,
        [Parameter(Mandatory)][string]$Category,
        [switch]$Critical
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        Add-ScanIssue -Category $Category -Message "directory not found: $LiteralPath" -Critical:$Critical
        return [pscustomobject]@{
            Items = @()
            Complete = $false
            Errors = @('directory not found')
            UnsafePathEntries = @()
        }
    }

    $issues = @()
    $unsafePathEntries = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $matchesSelection = {
        param([IO.FileSystemInfo]$Item)
        if ($File -and $Item.PSIsContainer) { return $false }
        if ($Directory -and -not $Item.PSIsContainer) { return $false }
        if ($Filter -and $Item.Name -notlike $Filter) { return $false }
        $true
    }

    if ($Recurse) {
        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue((ConvertTo-PlatformPath -Path $LiteralPath))
        while ($queue.Count -gt 0) {
            $currentPath = $queue.Dequeue()
            $currentIssues = @()
            try {
                $children = @(
                    Get-ChildItem -LiteralPath $currentPath -Force `
                        -ErrorAction SilentlyContinue -ErrorVariable currentIssues
                )
            }
            catch {
                $currentIssues += $_
                $children = @()
            }
            $issues += $currentIssues
            foreach ($child in $children) {
                if (Test-IsUnsafeTraversalEntry -Root $LiteralPath -Item $child) {
                    $unsafePathEntries.Add($child.FullName)
                    Add-ScanIssue -Category $Category -Message "unsafe link or nested mount skipped: $($child.FullName)" -Critical:$Critical
                    continue
                }
                if (& $matchesSelection $child) {
                    $items.Add($child)
                }
                if ($child.PSIsContainer) {
                    $queue.Enqueue($child.FullName)
                }
            }
        }
    }
    else {
        $parameters = @{
            LiteralPath   = $LiteralPath
            Force         = $true
            ErrorAction   = 'SilentlyContinue'
            ErrorVariable = 'issues'
        }
        if ($File) { $parameters.File = $true }
        if ($Directory) { $parameters.Directory = $true }
        if ($Filter) { $parameters.Filter = $Filter }
        try {
            foreach ($item in @(Get-ChildItem @parameters)) {
                if (Test-IsUnsafeTraversalEntry -Root $LiteralPath -Item $item) {
                    $unsafePathEntries.Add($item.FullName)
                    Add-ScanIssue -Category $Category -Message "unsafe link or nested mount skipped: $($item.FullName)" -Critical:$Critical
                    continue
                }
                $items.Add($item)
            }
        }
        catch {
            $issues += $_
        }
    }

    $messages = @(
        foreach ($issue in $issues) {
            $message = $issue.Exception.Message
            Add-ScanIssue -Category $Category -Message $message -Critical:$Critical
            $message
        }
    )
    [pscustomobject]@{
        Items             = @($items)
        Complete          = ($messages.Count -eq 0 -and $unsafePathEntries.Count -eq 0)
        Errors            = $messages
        UnsafePathEntries = @($unsafePathEntries)
    }
}

function Test-NoReparseWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Category,
        [switch]$LinksOnly
    )

    try {
        $rootFullPath = [IO.Path]::GetFullPath($Root)
        $volumeRoot = [IO.Path]::GetPathRoot($rootFullPath)
        $rootPath = if (
            [string]::Equals(
                $rootFullPath.TrimEnd('\', '/'),
                $volumeRoot.TrimEnd('\', '/'),
                $pathComparison
            )
        ) {
            $volumeRoot
        }
        else {
            $rootFullPath.TrimEnd('\', '/')
        }
        $targetPath = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\', '/')
        $rootComparable = $rootPath.TrimEnd('\', '/')
        $rootBoundary = if ($rootPath.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $rootPath
        }
        else {
            $rootPath + [IO.Path]::DirectorySeparatorChar
        }
        if (
            -not [string]::Equals($rootComparable, $targetPath, $pathComparison) -and
            -not $targetPath.StartsWith($rootBoundary, $pathComparison)
        ) {
            Add-ScanIssue -Category $Category -Message "path escapes validation root: $targetPath" -Critical
            return $false
        }

        $relative = [IO.Path]::GetRelativePath($rootPath, $targetPath)
        $paths = [Collections.Generic.List[string]]::new()
        $paths.Add($rootPath)
        if ($relative -ne '.') {
            $cursor = $rootPath
            foreach ($part in ($relative -split '[\\/]')) {
                $cursor = Join-Path $cursor $part
                $paths.Add($cursor)
            }
        }

        foreach ($path in $paths) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (Test-IsLinkLike -Item $item) {
                Add-ScanIssue -Category $Category -Message "symbolic link or reparse point in path chain: $($item.FullName)" -Critical
                return $false
            }
            if (-not $LinksOnly -and (Test-IsNestedMountPoint -Root $rootPath -LiteralPath $item.FullName)) {
                Add-ScanIssue -Category $Category -Message "nested mount point in path chain: $($item.FullName)" -Critical
                return $false
            }
        }
        return $true
    }
    catch {
        Add-ScanIssue -Category $Category -Message "path-chain validation failed for ${LiteralPath}: $($_.Exception.Message)" -Critical
        return $false
    }
}

function Measure-Tree {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Category,
        [switch]$Critical
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [pscustomobject]@{
            Exists              = $false
            Files               = 0
            Bytes               = 0L
            MiB                 = 0
            MaxLastWriteTimeUtc = $null
            MeasurementComplete = $true
            ReparsePoints       = 0
            UnsafePathEntries   = 0
            Errors              = @()
        }
    }

    $item = Get-Item -LiteralPath $LiteralPath -Force
    if (Test-IsLinkLike -Item $item) {
        return [pscustomobject]@{
            Exists              = $true
            Files               = 0
            Bytes               = 0L
            MiB                 = 0
            MaxLastWriteTimeUtc = $item.LastWriteTimeUtc
            MeasurementComplete = $false
            ReparsePoints       = 1
            UnsafePathEntries   = 1
            Errors              = @('link target was not traversed')
        }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{
            Exists              = $true
            Files               = 1
            Bytes               = [long]$item.Length
            MiB                 = [math]::Round($item.Length / 1MB, 2)
            MaxLastWriteTimeUtc = $item.LastWriteTimeUtc
            MeasurementComplete = $true
            ReparsePoints       = [int][bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            UnsafePathEntries   = 0
            Errors              = @()
        }
    }

    $listing = Get-CheckedChildren -LiteralPath $item.FullName -Recurse -Category $Category -Critical:$Critical
    $files = @($listing.Items | Where-Object { -not $_.PSIsContainer })
    $measure = $files | Measure-Object -Property Length -Sum
    $bytes = if ($null -eq $measure.Sum) { 0L } else { [long]$measure.Sum }
    $timestamps = @($item.LastWriteTimeUtc) + @($listing.Items.LastWriteTimeUtc)
    $maxLastWriteTimeUtc = ($timestamps | Sort-Object -Descending | Select-Object -First 1)
    $reparsePoints = @(
        @($item) + @($listing.Items) |
            Where-Object { Test-IsLinkLike -Item $_ }
    ).Count
    $unsafePathEntries = $reparsePoints + @($listing.UnsafePathEntries).Count

    [pscustomobject]@{
        Exists              = $true
        Files               = $files.Count
        Bytes               = $bytes
        MiB                 = [math]::Round($bytes / 1MB, 2)
        MaxLastWriteTimeUtc = $maxLastWriteTimeUtc
        MeasurementComplete = $listing.Complete
        ReparsePoints       = $reparsePoints
        UnsafePathEntries   = $unsafePathEntries
        Errors              = @($listing.Errors)
    }
}

function Get-RolloutMetadata {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Root
    )

    if ($File.BaseName -notmatch $rolloutNamePattern) {
        Add-ScanIssue -Category 'rollouts' -Message "unsupported filename: $($File.FullName)" -Critical
        return $null
    }
    if (-not (Test-NoReparseWithinRoot -Root $Root -LiteralPath $File.FullName -Category 'rollouts')) {
        return $null
    }
    $filenameId = $Matches.id.ToLowerInvariant()

    $stream = $null
    $reader = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new(
            $File.FullName,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            $share
        )
        $reader = [IO.StreamReader]::new($stream)
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'empty rollout'
        }
        $firstRecord = $line | ConvertFrom-Json -Depth 100
        if ($firstRecord.type -ne 'session_meta') {
            throw "first record is not session_meta"
        }
        $metadataId = if ($firstRecord.payload.id) {
            [string]$firstRecord.payload.id
        }
        else {
            [string]$firstRecord.payload.session_id
        }
        if ($metadataId -notmatch "^$uuidPattern$") {
            throw 'session_meta has no canonical task ID'
        }
        if ($metadataId.ToLowerInvariant() -ne $filenameId) {
            throw "filename ID and session_meta ID differ"
        }
        [pscustomobject]@{ Id = $filenameId; File = $File }
    }
    catch {
        Add-ScanIssue -Category 'rollouts' -Message "$($File.FullName): $($_.Exception.Message)" -Critical
        $null
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-StateSnapshot {
    param([Parameter(Mandatory)][string]$Root)

    $databaseListing = Get-CheckedChildren -LiteralPath $Root -File -Filter 'state_*.sqlite' -Category 'state-database' -Critical
    $databases = @(
        $databaseListing.Items |
            Sort-Object -Property @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
    )
    if (-not $databaseListing.Complete -or $databases.Count -eq 0) {
        if ($databases.Count -eq 0) {
            Add-ScanIssue -Category 'state-database' -Message 'no state_*.sqlite database found' -Critical
        }
        return [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $null; Threads = @(); Edges = @() }
    }
    $authoritativeResolved = ($databases.Count -eq 1)
    if ($databases.Count -gt 1) {
        Add-ScanIssue -Category 'state-database' -Message "multiple state databases make the authoritative source ambiguous; reading newest of $($databases.Count) for diagnosis only" -Critical
    }
    if (-not (Test-NoReparseWithinRoot -Root $Root -LiteralPath $databases[0].FullName -Category 'state-database')) {
        return [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $databases[0]; Threads = @(); Edges = @() }
    }

    $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $helper = Join-Path $PSScriptRoot 'read_codex_state.py'
    if ($null -eq $python -or -not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        Add-ScanIssue -Category 'state-database' -Message 'Python or read_codex_state.py is unavailable' -Critical
        return [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $databases[0]; Threads = @(); Edges = @() }
    }
    $pythonPath = Resolve-ExecutablePath -LiteralPath ([string]$python.Path)
    $pythonRoot = [IO.Path]::GetPathRoot($pythonPath)
    $helperPath = [IO.Path]::GetFullPath($helper)
    $helperRoot = [IO.Path]::GetPathRoot($helperPath)
    if (
        -not (Test-NoReparseWithinRoot -Root $pythonRoot -LiteralPath $pythonPath -Category 'python-runtime') -or
        -not (Test-NoReparseWithinRoot -Root $helperRoot -LiteralPath $helperPath -Category 'state-helper')
    ) {
        return [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $databases[0]; Threads = @(); Edges = @() }
    }

    try {
        $raw = @(& $pythonPath -I -B $helperPath $databases[0].FullName 2>&1)
        $exitCode = $LASTEXITCODE
        $parsed = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        if ($exitCode -ne 0 -or -not $parsed.complete) {
            foreach ($errorText in @($parsed.errors)) {
                Add-ScanIssue -Category 'state-database' -Message ([string]$errorText) -Critical
            }
            return [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $databases[0]; Threads = @(); Edges = @() }
        }
        [pscustomobject]@{
            Complete = $true
            AuthoritativeResolved = $authoritativeResolved
            Database = $databases[0]
            Threads  = @($parsed.threads)
            Edges    = @($parsed.edges)
        }
    }
    catch {
        Add-ScanIssue -Category 'state-database' -Message $_.Exception.Message -Critical
        [pscustomobject]@{ Complete = $false; AuthoritativeResolved = $false; Database = $databases[0]; Threads = @(); Edges = @() }
    }
}

function ConvertTo-ComparablePath {
    param([Parameter(Mandatory)][string]$Path)

    ConvertTo-PlatformPath -Path $Path
}

function Get-ItemSetSignature {
    param([AllowEmptyCollection()][object[]]$Items)

    $lines = @(
        $Items |
            Sort-Object FullName |
            ForEach-Object {
                $length = if ($_.PSIsContainer) { 0L } else { [long]$_.Length }
                '{0}|{1}|{2}|{3}|{4}' -f (
                    (ConvertTo-ComparablePath -Path $_.FullName),
                    [bool]$_.PSIsContainer,
                    $length,
                    $_.LastWriteTimeUtc.Ticks,
                    [int]$_.Attributes
                )
            }
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-StateSignature {
    param([Parameter(Mandatory)][object]$Snapshot)

    $payload = [ordered]@{
        AuthoritativeResolved = [bool]$Snapshot.AuthoritativeResolved
        Database = if ($Snapshot.Database) {
            ConvertTo-ComparablePath -Path $Snapshot.Database.FullName
        }
        else { $null }
        Threads = @(
            $Snapshot.Threads |
                ForEach-Object {
                    [ordered]@{
                        id = [string]$_.id
                        rollout_path = [string]$_.rollout_path
                        archived = [bool]$_.archived
                    }
                }
        )
        Edges = @($Snapshot.Edges)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10 -Compress))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-UnprotectedRolloutItems {
    param(
        [AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$ProtectedIds
    )

    @(
        foreach ($item in $Items) {
            if ($item.BaseName -match $rolloutNamePattern -and $ProtectedIds.Contains($Matches.id)) {
                continue
            }
            $item
        }
    )
}

function Get-UnprotectedAssetItems {
    param(
        [AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$TaskIdPartIndex,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$ProtectedIds
    )

    @(
        foreach ($item in $Items) {
            $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
            $parts = $relative -split '[\\/]'
            if (
                $parts.Count -gt $TaskIdPartIndex -and
                $parts[$TaskIdPartIndex] -match "^$uuidPattern$" -and
                $ProtectedIds.Contains($parts[$TaskIdPartIndex])
            ) {
                continue
            }
            $item
        }
    )
}

function New-TaskDirectoryRecord {
    param(
        [Parameter(Mandatory)][IO.DirectoryInfo]$DirectoryInfo,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$RolloutIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$StateIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$ProtectedIds,
        [Parameter(Mandatory)][datetime]$Cutoff,
        [Parameter(Mandatory)][string]$Category
    )

    $measurement = Measure-Tree -LiteralPath $DirectoryInfo.FullName -Category $Category -Critical
    $taskId = $DirectoryInfo.Name.ToLowerInvariant()
    $referencedByRollout = $RolloutIds.Contains($taskId)
    $referencedByState = $StateIds.Contains($taskId)
    $isProtected = $ProtectedIds.Contains($taskId)
    $ambiguityReasons = @(
        if (-not $referencedByRollout) { 'NoRolloutReference' }
        if (-not $referencedByState) { 'NoStateReference' }
        if ($isProtected) { 'ProtectedTaskFamily' }
        if (-not $measurement.MeasurementComplete) { 'IncompleteMeasurement' }
        if ($measurement.ReparsePoints -gt 0) { 'ReparsePointDetected' }
        if ($measurement.UnsafePathEntries -gt 0) { 'UnsafeLinkOrMountDetected' }
        'ContentUniquenessNotEvaluated'
    )
    [pscustomobject]@{
        TaskId              = $taskId
        Path                = $DirectoryInfo.FullName
        Files               = $measurement.Files
        Bytes               = $measurement.Bytes
        MiB                 = $measurement.MiB
        MaxLastWriteTimeUtc = $measurement.MaxLastWriteTimeUtc
        MeasurementComplete = $measurement.MeasurementComplete
        ReparsePoints       = $measurement.ReparsePoints
        UnsafePathEntries   = $measurement.UnsafePathEntries
        ReferencedByRollout = $referencedByRollout
        ReferencedByState   = $referencedByState
        Protected           = $isProtected
        OlderThanCutoff     = (
            $null -ne $measurement.MaxLastWriteTimeUtc -and
            $measurement.MaxLastWriteTimeUtc -lt $Cutoff
        )
        ReviewOnly          = $true
        MeasurementOnly     = $true
        Classification      = 'EvidenceOnly'
        Disposition         = 'ProtectPendingExactSelection'
        DeletionAuthorized  = $false
        ContentUniqueness   = 'NotEvaluated'
        RequiresSeparateAssetAuthorization = $true
        AmbiguityReasons    = @($ambiguityReasons | Sort-Object -Unique)
    }
}

function Get-ReportCandidates {
    param(
        [string[]]$Roots,
        [int]$Limit
    )

    $excludedDirectoryNames = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('.git', '.svn', 'node_modules', 'build', 'dist', '.expo', '.godot', '.gradle', '.venv', 'venv'),
        [StringComparer]::OrdinalIgnoreCase
    )
    $allowedExtensions = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('.md', '.txt', '.html', '.json', '.csv', '.png', '.jpg', '.jpeg', '.webp', '.pdf', '.docx'),
        [StringComparer]::OrdinalIgnoreCase
    )
    $namePattern = '(?i)(^|[-_. ])(report|audit|summary|handoff|contact[-_ ]?sheet|cleanup)([-_. ]|$)'
    $seenPaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
    $reviewRecords = [Collections.Generic.List[object]]::new()
    $skippedRoots = [Collections.Generic.List[string]]::new()
    $skippedReparsePaths = [Collections.Generic.List[string]]::new()
    $reportErrors = [Collections.Generic.List[string]]::new()
    $complete = $true

    foreach ($root in $Roots) {
        $resolvedRoot = [IO.Path]::GetFullPath($root)
        if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
            Add-ScanIssue -Category 'report-scan' -Message "project root not found: $resolvedRoot"
            $skippedRoots.Add($resolvedRoot)
            $reportErrors.Add("project root not found: $resolvedRoot")
            $complete = $false
            continue
        }
        $queue = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
        $queue.Enqueue((Get-Item -LiteralPath $resolvedRoot -Force))

        while ($queue.Count -gt 0) {
            $directory = $queue.Dequeue()
            if (Test-IsUnsafeTraversalEntry -Root $resolvedRoot -Item $directory) {
                Add-ScanIssue -Category 'report-scan' -Message "skipped unsafe link or nested mount: $($directory.FullName)"
                $skippedReparsePaths.Add($directory.FullName)
                $complete = $false
                continue
            }

            $children = Get-CheckedChildren -LiteralPath $directory.FullName -Category 'report-scan'
            if (-not $children.Complete) {
                $complete = $false
                foreach ($message in @($children.Errors)) {
                    $reportErrors.Add([string]$message)
                }
            }
            foreach ($childDirectory in @($children.Items | Where-Object { $_.PSIsContainer })) {
                if (-not $excludedDirectoryNames.Contains($childDirectory.Name)) {
                    $queue.Enqueue($childDirectory)
                }
            }
            foreach ($file in @($children.Items | Where-Object { -not $_.PSIsContainer })) {
                if (
                    $allowedExtensions.Contains($file.Extension) -and
                    $file.BaseName -match $namePattern -and
                    $seenPaths.Add($file.FullName)
                ) {
                    $reviewRecords.Add([pscustomobject]@{
                        ProjectRoot  = $resolvedRoot
                        Path         = $file.FullName
                        Bytes        = [long]$file.Length
                        MiB          = [math]::Round($file.Length / 1MB, 2)
                        LastWriteTimeUtc = $file.LastWriteTimeUtc
                        ReviewOnly = $true
                        MeasurementOnly = $true
                        Classification = 'EvidenceOnly'
                        Disposition = 'ProtectPendingExactSelection'
                        DeletionAuthorized = $false
                    })
                }
            }
        }
    }

    $sortedRecords = @(
        $reviewRecords |
            Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true }, @{ Expression = 'Path'; Descending = $false } |
            ForEach-Object { $_ }
    )
    $totalBytes = ($sortedRecords | Measure-Object -Property Bytes -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0L }
    [pscustomobject]@{
        Requested = ($Roots.Count -gt 0)
        Complete = $complete
        MeasurementOnly = $true
        RecordsAuthorizeDeletion = $false
        Total = $sortedRecords.Count
        Bytes = [long]$totalBytes
        MiB = [math]::Round($totalBytes / 1MB, 2)
        Truncated = ($sortedRecords.Count -gt $Limit)
        Limit = $Limit
        Items = @($sortedRecords | Select-Object -First $Limit)
        SkippedRoots = @(
            $skippedRoots |
                Sort-Object |
                ForEach-Object {
                    [pscustomobject]@{
                        Path = $_
                        MeasurementOnly = $true
                        DeletionAuthorized = $false
                        Disposition = 'Protect'
                    }
                }
        )
        SkippedReparsePaths = @(
            $skippedReparsePaths |
                Sort-Object |
                ForEach-Object {
                    [pscustomobject]@{
                        Path = $_
                        MeasurementOnly = $true
                        DeletionAuthorized = $false
                        Disposition = 'Protect'
                    }
                }
        )
        Errors = @($reportErrors | Sort-Object)
        ExcludedDirectoryNames = @($excludedDirectoryNames | Sort-Object)
    }
}

$script:mountInventory = Get-PlatformMountInventory
if (-not $script:mountInventory.Complete) {
    foreach ($mountError in @($script:mountInventory.Errors)) {
        Add-ScanIssue -Category 'platform-mount-inventory' -Message ([string]$mountError) -Critical
    }
    if (@($script:mountInventory.Errors).Count -eq 0) {
        Add-ScanIssue -Category 'platform-mount-inventory' -Message 'mount inventory is incomplete' -Critical
    }
}

$resolvedCodexRoot = [IO.Path]::GetFullPath($CodexRoot)
if (-not (Test-Path -LiteralPath $resolvedCodexRoot -PathType Container)) {
    throw "Codex root not found: $resolvedCodexRoot"
}
$codexVolumeRoot = [IO.Path]::GetPathRoot($resolvedCodexRoot)
if (-not (Test-NoReparseWithinRoot -Root $codexVolumeRoot -LiteralPath $resolvedCodexRoot -Category 'codex-root-ancestors' -LinksOnly)) {
    throw "Codex root ancestor chain is unsafe: $resolvedCodexRoot"
}
$codexRootItem = Get-Item -LiteralPath $resolvedCodexRoot -Force
if (Test-IsLinkLike -Item $codexRootItem) {
    Add-ScanIssue -Category 'codex-root' -Message 'Codex root is a symbolic link or reparse point' -Critical
}
$resolvedStateRoot = [IO.Path]::GetFullPath($StateRoot)
if (-not (Test-Path -LiteralPath $resolvedStateRoot -PathType Container)) {
    throw "Codex state root not found: $resolvedStateRoot"
}
$stateVolumeRoot = [IO.Path]::GetPathRoot($resolvedStateRoot)
if (-not (Test-NoReparseWithinRoot -Root $stateVolumeRoot -LiteralPath $resolvedStateRoot -Category 'state-root-ancestors' -LinksOnly)) {
    throw "Codex state root ancestor chain is unsafe: $resolvedStateRoot"
}
$stateRootItem = Get-Item -LiteralPath $resolvedStateRoot -Force
if (Test-IsLinkLike -Item $stateRootItem) {
    Add-ScanIssue -Category 'state-root' -Message 'Codex state root is a symbolic link or reparse point' -Critical
}

$sessionRoot = Join-Path $resolvedCodexRoot 'sessions'
$archiveRoot = Join-Path $resolvedCodexRoot 'archived_sessions'
$imageRoot = Join-Path $resolvedCodexRoot 'generated_images'
$visualRoot = Join-Path $resolvedCodexRoot 'visualizations'

$sessionRootSafe = Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $sessionRoot -Category 'sessions'
$archiveRootSafe = Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $archiveRoot -Category 'archived-sessions'
$imageRootSafe = Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $imageRoot -Category 'generated-image-directories'
$visualRootSafe = Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $visualRoot -Category 'visualization-directories'

$emptyIncompleteListing = [pscustomobject]@{
    Items = @()
    Complete = $false
    Errors = @('unsafe or unavailable root')
    UnsafePathEntries = @()
}
$sessionListing = if ($sessionRootSafe) {
    Get-CheckedChildren -LiteralPath $sessionRoot -File -Recurse -Filter '*.jsonl' -Category 'sessions' -Critical
}
else { $emptyIncompleteListing }
$archiveListing = if ($archiveRootSafe) {
    Get-CheckedChildren -LiteralPath $archiveRoot -File -Recurse -Filter '*.jsonl' -Category 'archived-sessions' -Critical
}
else { $emptyIncompleteListing }
$rolloutFiles = @($sessionListing.Items) + @($archiveListing.Items)
$rolloutRecordResults = @(
    foreach ($file in $rolloutFiles) {
        Get-RolloutMetadata -File $file -Root $resolvedCodexRoot
    }
)
$rolloutRecords = @($rolloutRecordResults | Where-Object { $null -ne $_ })
$rolloutIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$duplicateRolloutIds = [Collections.Generic.List[string]]::new()
$rolloutPathById = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($record in $rolloutRecords) {
    if (-not $rolloutIds.Add($record.Id)) {
        $duplicateRolloutIds.Add($record.Id)
        Add-ScanIssue -Category 'rollouts' -Message "duplicate task ID: $($record.Id)" -Critical
    }
    else {
        $rolloutPathById[$record.Id] = ConvertTo-ComparablePath -Path $record.File.FullName
    }
}
$rolloutScanComplete = (
    $sessionListing.Complete -and
    $archiveListing.Complete -and
    $rolloutRecords.Count -eq $rolloutFiles.Count -and
    $duplicateRolloutIds.Count -eq 0
)

$stateSnapshot = Get-StateSnapshot -Root $resolvedStateRoot
$stateSignature = Get-StateSignature -Snapshot $stateSnapshot
$stateIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($thread in $stateSnapshot.Threads) {
    [void]$stateIds.Add(([string]$thread.id).ToLowerInvariant())
}

$missingRolloutIds = @($stateIds | Where-Object { -not $rolloutIds.Contains($_) } | Sort-Object)
$strayRolloutIds = @($rolloutIds | Where-Object { -not $stateIds.Contains($_) } | Sort-Object)
$rolloutPathMismatches = [Collections.Generic.List[object]]::new()
foreach ($thread in $stateSnapshot.Threads) {
    $threadId = ([string]$thread.id).ToLowerInvariant()
    if (-not $rolloutPathById.ContainsKey($threadId)) { continue }
    $stateRolloutPath = [string]$thread.rollout_path
    if ([string]::IsNullOrWhiteSpace($stateRolloutPath)) {
        $rolloutPathMismatches.Add([pscustomobject]@{
            TaskId = $threadId
            StatePath = $null
            ActualPath = $rolloutPathById[$threadId]
            MeasurementOnly = $true
            DeletionAuthorized = $false
            Disposition = 'Protect'
        })
        continue
    }
    $normalizedStatePath = ConvertTo-ComparablePath -Path $stateRolloutPath
    if (-not [string]::Equals(
        $normalizedStatePath,
        $rolloutPathById[$threadId],
        $pathComparison
    )) {
        $rolloutPathMismatches.Add([pscustomobject]@{
            TaskId = $threadId
            StatePath = $normalizedStatePath
            ActualPath = $rolloutPathById[$threadId]
            MeasurementOnly = $true
            DeletionAuthorized = $false
            Disposition = 'Protect'
        })
    }
}
if ($rolloutPathMismatches.Count -gt 0) {
    Add-ScanIssue -Category 'task-consistency' -Message "$($rolloutPathMismatches.Count) state rollout paths differ from discovered rollouts" -Critical
}
$missingEdgeReferences = [Collections.Generic.List[string]]::new()
foreach ($edge in $stateSnapshot.Edges) {
    foreach ($id in @([string]$edge.parent, [string]$edge.child)) {
        if (-not $stateIds.Contains($id)) {
            $missingEdgeReferences.Add($id)
        }
    }
}
$taskConsistencyValid = (
    $stateSnapshot.Complete -and
    $stateSnapshot.AuthoritativeResolved -and
    $rolloutScanComplete -and
    $missingRolloutIds.Count -eq 0 -and
    $strayRolloutIds.Count -eq 0 -and
    $duplicateRolloutIds.Count -eq 0 -and
    $rolloutPathMismatches.Count -eq 0 -and
    $missingEdgeReferences.Count -eq 0
)

$protectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$requestedProtectedIds = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($CurrentTaskId)) {
    $normalizedCurrentTaskId = $CurrentTaskId.ToLowerInvariant()
    [void]$protectedIds.Add($normalizedCurrentTaskId)
    $requestedProtectedIds.Add($normalizedCurrentTaskId)
}
foreach ($id in $AdditionalProtectedTaskId) {
    $normalizedId = $id.ToLowerInvariant()
    [void]$protectedIds.Add($normalizedId)
    $requestedProtectedIds.Add($normalizedId)
}
$unknownProtectedTaskIds = @(
    $requestedProtectedIds |
        Where-Object { -not $stateIds.Contains($_) } |
        Sort-Object -Unique
)
if ($unknownProtectedTaskIds.Count -gt 0) {
    Add-ScanIssue -Category 'task-protection' -Message "$($unknownProtectedTaskIds.Count) supplied protected task IDs are absent from state" -Critical
}
if ($stateSnapshot.Complete -and $protectedIds.Count -gt 0) {
    do {
        $changed = $false
        foreach ($edge in $stateSnapshot.Edges) {
            $parent = ([string]$edge.parent).ToLowerInvariant()
            $child = ([string]$edge.child).ToLowerInvariant()
            if ($protectedIds.Contains($parent) -and $protectedIds.Add($child)) { $changed = $true }
            if ($protectedIds.Contains($child) -and $protectedIds.Add($parent)) { $changed = $true }
        }
    } while ($changed)
}
$currentTaskProtectionProvided = (
    -not [string]::IsNullOrWhiteSpace($CurrentTaskId) -and
    $stateIds.Contains($normalizedCurrentTaskId) -and
    $unknownProtectedTaskIds.Count -eq 0
)
$rolloutFileSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedRolloutItems -Items $rolloutFiles -ProtectedIds $protectedIds
)

$imageDirectoryListing = if ($imageRootSafe) {
    Get-CheckedChildren -LiteralPath $imageRoot -Recurse -Category 'generated-image-directories' -Critical
}
else { $emptyIncompleteListing }
$imageTaskDirectories = [Collections.Generic.List[IO.DirectoryInfo]]::new()
foreach ($item in $imageDirectoryListing.Items) {
    if (Test-IsUnsafeTraversalEntry -Root $imageRoot -Item $item) {
        Add-ScanIssue -Category 'generated-image-directories' -Message "unsafe link or nested mount in asset tree: $($item.FullName)" -Critical
        continue
    }
    $relative = [IO.Path]::GetRelativePath($imageRoot, $item.FullName)
    $parts = $relative -split '[\\/]'
    if ($parts.Count -eq 1) {
        if ($item.PSIsContainer -and $item.Name -match "^$uuidPattern$") {
            $imageTaskDirectories.Add($item)
        }
        else {
            Add-ScanIssue -Category 'generated-image-directories' -Message "unexpected root item: $($item.FullName)" -Critical
        }
    }
    elseif ($item.PSIsContainer -and $item.Name -match "^$uuidPattern$") {
        Add-ScanIssue -Category 'generated-image-directories' -Message "unexpected nested UUID directory: $($item.FullName)" -Critical
    }
}
$imageTaskDirectories = @($imageTaskDirectories | Sort-Object FullName)

$visualDirectoryListing = if ($visualRootSafe) {
    Get-CheckedChildren -LiteralPath $visualRoot -Recurse -Category 'visualization-directories' -Critical
}
else { $emptyIncompleteListing }
$visualTaskDirectories = [Collections.Generic.List[IO.DirectoryInfo]]::new()
$visualTaskPathsById = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in $visualDirectoryListing.Items) {
    if (Test-IsUnsafeTraversalEntry -Root $visualRoot -Item $item) {
        Add-ScanIssue -Category 'visualization-directories' -Message "unsafe link or nested mount in asset tree: $($item.FullName)" -Critical
        continue
    }
    $relative = [IO.Path]::GetRelativePath($visualRoot, $item.FullName)
    $parts = $relative -split '[\\/]'
    $dateValue = [datetime]::MinValue
    $datePrefixValid = (
        $parts.Count -ge 3 -and
        [datetime]::TryParseExact(
            ($parts[0..2] -join '/'),
            'yyyy/MM/dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$dateValue
        )
    )
    $valid = switch ($parts.Count) {
        1 { $item.PSIsContainer -and $parts[0] -match '^\d{4}$'; break }
        2 { $item.PSIsContainer -and $parts[0] -match '^\d{4}$' -and $parts[1] -match '^(0[1-9]|1[0-2])$'; break }
        3 { $item.PSIsContainer -and $datePrefixValid; break }
        4 { $item.PSIsContainer -and $datePrefixValid -and $parts[3] -match "^$uuidPattern$"; break }
        default {
            $datePrefixValid -and
            $parts[3] -match "^$uuidPattern$" -and
            -not ($item.PSIsContainer -and $item.Name -match "^$uuidPattern$")
        }
    }
    if (-not $valid) {
        Add-ScanIssue -Category 'visualization-directories' -Message "unexpected visualization layout item: $($item.FullName)" -Critical
        continue
    }
    if ($parts.Count -eq 4) {
        $taskId = $parts[3].ToLowerInvariant()
        if ($visualTaskPathsById.ContainsKey($taskId)) {
            Add-ScanIssue -Category 'visualization-directories' -Message "duplicate task ID directories: $taskId" -Critical
        }
        else {
            $visualTaskPathsById[$taskId] = $item.FullName
            $visualTaskDirectories.Add($item)
        }
    }
}
$visualTaskDirectories = @($visualTaskDirectories | Sort-Object FullName)

$imageAssetSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedAssetItems -Items @($imageDirectoryListing.Items) -Root $imageRoot -TaskIdPartIndex 0 -ProtectedIds $protectedIds
)
$visualAssetSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedAssetItems -Items @($visualDirectoryListing.Items) -Root $visualRoot -TaskIdPartIndex 3 -ProtectedIds $protectedIds
)
$cutoff = $capturedAtUtc.AddDays(-$ProtectRecentDays)
$imageRecords = @(
    foreach ($directory in $imageTaskDirectories) {
        New-TaskDirectoryRecord -DirectoryInfo $directory -RolloutIds $rolloutIds -StateIds $stateIds -ProtectedIds $protectedIds -Cutoff $cutoff -Category 'generated-image-measurement'
    }
)
$visualRecords = @(
    foreach ($directory in @($visualTaskDirectories)) {
        New-TaskDirectoryRecord -DirectoryInfo $directory -RolloutIds $rolloutIds -StateIds $stateIds -ProtectedIds $protectedIds -Cutoff $cutoff -Category 'visualization-measurement'
    }
)

$rootsStillSafe = (
    (Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $sessionRoot -Category 'capture-stability') -and
    (Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $archiveRoot -Category 'capture-stability') -and
    (Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $imageRoot -Category 'capture-stability') -and
    (Test-NoReparseWithinRoot -Root $resolvedCodexRoot -LiteralPath $visualRoot -Category 'capture-stability') -and
    (Test-NoReparseWithinRoot -Root $resolvedStateRoot -LiteralPath $resolvedStateRoot -Category 'capture-stability')
)
$sessionVerification = if ($rootsStillSafe) {
    Get-CheckedChildren -LiteralPath $sessionRoot -File -Recurse -Filter '*.jsonl' -Category 'capture-stability' -Critical
}
else { $emptyIncompleteListing }
$archiveVerification = if ($rootsStillSafe) {
    Get-CheckedChildren -LiteralPath $archiveRoot -File -Recurse -Filter '*.jsonl' -Category 'capture-stability' -Critical
}
else { $emptyIncompleteListing }
$imageVerification = if ($rootsStillSafe) {
    Get-CheckedChildren -LiteralPath $imageRoot -Recurse -Category 'capture-stability' -Critical
}
else { $emptyIncompleteListing }
$visualVerification = if ($rootsStillSafe) {
    Get-CheckedChildren -LiteralPath $visualRoot -Recurse -Category 'capture-stability' -Critical
}
else { $emptyIncompleteListing }
$stateVerification = Get-StateSnapshot -Root $resolvedStateRoot
$rolloutVerificationSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedRolloutItems -Items (@($sessionVerification.Items) + @($archiveVerification.Items)) -ProtectedIds $protectedIds
)
$imageVerificationSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedAssetItems -Items @($imageVerification.Items) -Root $imageRoot -TaskIdPartIndex 0 -ProtectedIds $protectedIds
)
$visualVerificationSignature = Get-ItemSetSignature -Items @(
    Get-UnprotectedAssetItems -Items @($visualVerification.Items) -Root $visualRoot -TaskIdPartIndex 3 -ProtectedIds $protectedIds
)
$stateVerificationSignature = Get-StateSignature -Snapshot $stateVerification
$rolloutCaptureStable = ($rolloutFileSignature -eq $rolloutVerificationSignature)
$imageCaptureStable = ($imageAssetSignature -eq $imageVerificationSignature)
$visualCaptureStable = ($visualAssetSignature -eq $visualVerificationSignature)
$stateCaptureStable = ($stateSignature -eq $stateVerificationSignature)
$captureStable = (
    $rootsStillSafe -and
    $sessionVerification.Complete -and
    $archiveVerification.Complete -and
    $imageVerification.Complete -and
    $visualVerification.Complete -and
    $stateVerification.Complete -and
    $rolloutCaptureStable -and
    $imageCaptureStable -and
    $visualCaptureStable -and
    $stateCaptureStable
)
if (-not $captureStable) {
    Add-ScanIssue -Category 'capture-stability' -Message 'Codex state or task assets changed during capture' -Critical
}

$reviewClassificationComplete = (
    $taskConsistencyValid -and
    $captureStable -and
    $imageDirectoryListing.Complete -and
    $visualDirectoryListing.Complete -and
    $currentTaskProtectionProvided -and
    $criticalScanErrors.Count -eq 0
)
$oldUnreferencedImageCandidates = @()
$oldUnreferencedVisualCandidates = @()
if ($reviewClassificationComplete) {
    $oldUnreferencedImageCandidates = @(
        $imageRecords |
            Where-Object {
                -not $_.ReferencedByRollout -and
                -not $_.ReferencedByState -and
                -not $_.Protected -and
                $_.OlderThanCutoff -and
                $_.MeasurementComplete -and
                $_.UnsafePathEntries -eq 0
            } |
            Sort-Object Path
    )
    $oldUnreferencedVisualCandidates = @(
        $visualRecords |
            Where-Object {
                -not $_.ReferencedByRollout -and
                -not $_.ReferencedByState -and
                -not $_.Protected -and
                $_.OlderThanCutoff -and
                $_.MeasurementComplete -and
                $_.UnsafePathEntries -eq 0
            } |
            Sort-Object Path
    )
}

$imageReviewPaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
foreach ($record in $oldUnreferencedImageCandidates) { [void]$imageReviewPaths.Add($record.Path) }
$visualReviewPaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
foreach ($record in $oldUnreferencedVisualCandidates) { [void]$visualReviewPaths.Add($record.Path) }
$protectedAmbiguousImageDirectories = @(
    $imageRecords |
        Where-Object {
            (-not $_.ReferencedByRollout -or -not $_.ReferencedByState) -and
            -not $imageReviewPaths.Contains($_.Path)
        } |
        Sort-Object Path
)
$protectedAmbiguousVisualDirectories = @(
    $visualRecords |
        Where-Object {
            (-not $_.ReferencedByRollout -or -not $_.ReferencedByState) -and
            -not $visualReviewPaths.Contains($_.Path)
        } |
        Sort-Object Path
)

$areaMap = [ordered]@{
    sessions          = $sessionRoot
    archived_sessions = $archiveRoot
    generated_images  = $imageRoot
    visualizations    = $visualRoot
    attachments       = (Join-Path $resolvedCodexRoot 'attachments')
    temp              = (Join-Path $resolvedCodexRoot '.tmp')
    plugins           = (Join-Path $resolvedCodexRoot 'plugins')
    skills            = (Join-Path $resolvedCodexRoot 'skills')
}
$areaRows = @(
    foreach ($entry in $areaMap.GetEnumerator()) {
        $measurement = Measure-Tree -LiteralPath $entry.Value -Category "area-$($entry.Key)"
        [pscustomobject]@{
            Name                = $entry.Key
            Path                = $entry.Value
            Exists              = $measurement.Exists
            Files               = $measurement.Files
            Bytes               = $measurement.Bytes
            MiB                 = $measurement.MiB
            MeasurementComplete = $measurement.MeasurementComplete
            MeasurementOnly     = $true
            DeletionAuthorized  = $false
            Disposition         = 'Protect'
        }
    }
)

$databaseRoots = [Collections.Generic.HashSet[string]]::new($pathComparer)
[void]$databaseRoots.Add($resolvedCodexRoot)
[void]$databaseRoots.Add($resolvedStateRoot)
$databaseItems = [Collections.Generic.List[object]]::new()
$databaseListingComplete = $true
foreach ($databaseRoot in $databaseRoots) {
    $listing = Get-CheckedChildren -LiteralPath $databaseRoot -File -Filter '*.sqlite*' -Category 'database-list'
    if (-not $listing.Complete) { $databaseListingComplete = $false }
    foreach ($databaseItem in $listing.Items) {
        $databaseItems.Add($databaseItem)
    }
}
$databaseRows = @(
    $databaseItems |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                Path          = $_.FullName
                Bytes         = [long]$_.Length
                MiB           = [math]::Round($_.Length / 1MB, 2)
                LastWriteTimeUtc = $_.LastWriteTimeUtc
                MeasurementOnly = $true
                DeletionAuthorized = $false
                Disposition = 'Protect'
            }
        }
)

$reportScan = Get-ReportCandidates -Roots $ProjectRoot -Limit $Top
$overallScanComplete = (
    $scanErrors.Count -eq 0 -and
    $databaseListingComplete -and
    (-not $reportScan.Requested -or $reportScan.Complete)
)
$overallComplete = (
    $reviewClassificationComplete -and
    $databaseListingComplete -and
    (-not $reportScan.Requested -or $reportScan.Complete)
)
$snapshot = [pscustomobject]@{
    SchemaVersion = 4
    OutputKind = 'ReadOnlyDiagnosticSnapshot'
    UsableAsActionManifest = $false
    RecordsAuthorizeDeletion = $false
    PathRecordsAuthorizeDeletion = $false
    CapturedAtUtc = $capturedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    Platform = [pscustomobject]@{
        Name = $platformName
        PathCaseSensitive = (-not $IsWindows)
        MountInventoryComplete = $script:mountInventory.Complete
        MountInventorySource = $script:mountInventory.Source
        MountPointCount = $script:mountInventory.Paths.Count
    }
    CodexRoot = [pscustomobject]@{
        Path = $resolvedCodexRoot
        MeasurementOnly = $true
        DeletionAuthorized = $false
        Disposition = 'Protect'
    }
    StateRoot = [pscustomobject]@{
        Path = $resolvedStateRoot
        MeasurementOnly = $true
        DeletionAuthorized = $false
        Disposition = 'Protect'
    }
    ScanComplete = $overallScanComplete
    ReviewClassificationComplete = $overallComplete
    Errors = @($scanErrors | Sort-Object -Unique)
    Warnings = @($scanWarnings | Sort-Object -Unique)
    Safety = [pscustomobject]@{
        AnalysisOnly = $true
        SnapshotAuthorizesDeletion = $false
        PlatformPathSafetyComplete = $script:mountInventory.Complete
        RolloutScanComplete = $rolloutScanComplete
        StateDatabaseComplete = $stateSnapshot.Complete
        AuthoritativeStateDatabaseResolved = $stateSnapshot.AuthoritativeResolved
        CaptureStable = $captureStable
        CaptureComponents = [pscustomobject]@{
            Roots = $rootsStillSafe
            Rollouts = $rolloutCaptureStable
            GeneratedImages = $imageCaptureStable
            Visualizations = $visualCaptureStable
            State = $stateCaptureStable
        }
        TaskConsistencyValid = $taskConsistencyValid
        CurrentTaskProtectionProvided = $currentTaskProtectionProvided
        CurrentTaskId = if ([string]::IsNullOrWhiteSpace($CurrentTaskId)) { $null } else { $normalizedCurrentTaskId }
        UnknownProtectedTaskIds = $unknownProtectedTaskIds
        ProtectedTaskIds = @($protectedIds | Sort-Object)
        TaskAssetReviewClassificationComplete = $reviewClassificationComplete
        RecordsAuthorizeDeletion = $false
    }
    Areas = $areaRows
    State = [pscustomobject]@{
        MeasurementOnly = $true
        DeletionAuthorized = $false
        Disposition = 'Protect'
        Database = [pscustomobject]@{
            Path = if ($stateSnapshot.Database) { $stateSnapshot.Database.FullName } else { $null }
            MeasurementOnly = $true
            DeletionAuthorized = $false
            Disposition = 'Protect'
        }
        Threads = $stateSnapshot.Threads.Count
        ArchivedThreads = @($stateSnapshot.Threads | Where-Object { $_.archived }).Count
        SpawnEdges = $stateSnapshot.Edges.Count
        MissingRolloutIds = $missingRolloutIds
        StrayRolloutIds = $strayRolloutIds
        DuplicateRolloutIds = @($duplicateRolloutIds | Sort-Object)
        RolloutPathMismatches = @($rolloutPathMismatches | Sort-Object TaskId)
        MissingEdgeReferences = @($missingEdgeReferences | Sort-Object -Unique)
    }
    Rollouts = [pscustomobject]@{
        Total = $rolloutRecords.Count
        Sessions = @($rolloutRecords | Where-Object { $_.File.FullName.StartsWith($sessionRoot, $pathComparison) }).Count
        Archived = @($rolloutRecords | Where-Object { $_.File.FullName.StartsWith($archiveRoot, $pathComparison) }).Count
    }
    GeneratedImages = [pscustomobject]@{
        MeasurementOnly = $true
        RecordsAuthorizeDeletion = $false
        TaskDirectories = $imageRecords.Count
        ReviewOnlyHistoricalAssetRecords = $oldUnreferencedImageCandidates
        ProtectedAmbiguousDirectories = $protectedAmbiguousImageDirectories
    }
    Visualizations = [pscustomobject]@{
        MeasurementOnly = $true
        RecordsAuthorizeDeletion = $false
        TaskDirectories = $visualRecords.Count
        ReviewOnlyHistoricalAssetRecords = $oldUnreferencedVisualCandidates
        ProtectedAmbiguousDirectories = $protectedAmbiguousVisualDirectories
    }
    Databases = $databaseRows
    ReportScan = $reportScan
}

if ($AsJson) {
    $snapshot | ConvertTo-Json -Depth 10
    return
}

$areaRows | Sort-Object MiB -Descending | Format-Table Name, Files, MiB, MeasurementComplete, Path -AutoSize
$snapshot.Safety | Format-List
$snapshot.State | Format-List
$snapshot.Rollouts | Format-List
[pscustomobject]@{
    GeneratedImageTaskDirectories = $snapshot.GeneratedImages.TaskDirectories
    GeneratedImageReviewOnlyRecords = $snapshot.GeneratedImages.ReviewOnlyHistoricalAssetRecords.Count
    VisualizationTaskDirectories  = $snapshot.Visualizations.TaskDirectories
    VisualizationReviewOnlyRecords = $snapshot.Visualizations.ReviewOnlyHistoricalAssetRecords.Count
    ReportReviewOnlyRecords         = $snapshot.ReportScan.Total
} | Format-List
if ($snapshot.Errors.Count) {
    'Errors (deletion assessment is blocked):'
    $snapshot.Errors
}
if ($snapshot.Warnings.Count) {
    'Warnings:'
    $snapshot.Warnings
}
