#requires -Version 5.1
<#
    OrganizerEngine - all sorting rules and file operations used by Organizer.ps1.

    Safety rules that every run follows:
      * Only files directly inside the chosen folder are sorted. Folders are never moved.
      * Nothing is ever deleted or overwritten. A name clash gets " (2)", " (3)" ...
      * Hidden and system files and unfinished downloads are left alone.
      * Every run is written to a history file so it can be undone.
#>

$script:IncompleteExtensions = @('crdownload', 'part', 'partial', 'tmp', 'download', 'opdownload', '!ut', '!qb', 'aria2')

# ------------------------------------------------------------------------------------------------
#  Paths
# ------------------------------------------------------------------------------------------------
function Get-OrganizerDataDir {
    $dir = if ($env:ORGANIZER_DATA_DIR) { $env:ORGANIZER_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Organizer' }
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    return $dir
}

function Get-OrganizerDownloadsPath {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($value) { return [Environment]::ExpandEnvironmentVariables($value).TrimEnd('\') }
    }
    catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Get-OrganizerSource($Settings) {
    $folder = [string]$Settings.SourceFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { return Get-OrganizerDownloadsPath }
    return [Environment]::ExpandEnvironmentVariables($folder.Trim()).TrimEnd('\')
}

function Test-OrganizerSourceSafe([string]$Path) {
    # Returns $null when the folder may be organized, otherwise the reason it may not.
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'No folder is selected.' }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return 'This is not a valid folder path.' }
    $protected = Test-OrganizerPathProtected $Path
    if ($protected) { return $protected }
    if (-not [IO.Directory]::Exists($full)) { return 'This folder does not exist.' }

    # Smart check: does this folder look like an installed program or a code project?
    try { $entries = @([IO.Directory]::GetFileSystemEntries($full) | ForEach-Object { [IO.Path]::GetFileName($_) }) } catch { $entries = @() }
    if ($entries | Where-Object { $_ -match '^unins\d{3}\.exe$' }) {
        return 'This looks like an installed program (it contains an uninstaller). Sorting its files would break the program.'
    }
    if (@($entries | Where-Object { $_ -like '*.dll' }).Count -ge 5) {
        return 'This looks like a program folder (it contains many .dll files). Sorting its files would break the program.'
    }
    $project = $entries | Where-Object { @('.git', '.svn', '.hg', '.vs', 'node_modules') -contains $_ } | Select-Object -First 1
    if ($project) { return "This looks like a code project (it contains `"$project`"). Sorting its files would break the project." }
    return $null
}

function Get-OrganizerProtectedZone {
    <#  The places Organizer never reads from and never moves files into.  #>
    $zones = New-Object System.Collections.ArrayList
    $seen = @{}
    $candidates = @(
        @($env:SystemRoot, 'Windows', 'The operating system itself.'),
        @($env:ProgramFiles, 'Program Files', 'Installed programs.'),
        @(${env:ProgramFiles(x86)}, 'Program Files (x86)', 'Installed 32-bit programs.'),
        @($env:ProgramW6432, 'Program Files', 'Installed programs.'),
        @($env:ProgramData, 'ProgramData', 'Data shared by installed programs.'),
        @((Join-Path $env:USERPROFILE 'AppData'), 'AppData', 'Settings, caches and data of your apps.')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate[0]) { continue }
        $path = ([string]$candidate[0]).TrimEnd('\')
        if ($seen.ContainsKey($path.ToLowerInvariant())) { continue }
        $seen[$path.ToLowerInvariant()] = $true
        [void]$zones.Add([pscustomobject]@{ Name = $candidate[1]; Path = $path; Note = $candidate[2]; Tree = $true })
    }
    [void]$zones.Add([pscustomobject]@{ Name = 'Drive roots'; Path = 'C:\, D:\ and every other drive'; Note = 'A whole drive is never sorted or used as a destination.'; Tree = $false })
    [void]$zones.Add([pscustomobject]@{ Name = 'Recycle Bin and system restore data'; Path = '$Recycle.Bin, System Volume Information, Recovery'; Note = 'Hidden system folders on every drive.'; Tree = $false })
    [void]$zones.Add([pscustomobject]@{ Name = 'Other user accounts'; Path = (Split-Path $env:USERPROFILE -Parent) + '\...'; Note = 'Files of other people on this PC.'; Tree = $false })
    return @($zones)
}

function Test-OrganizerPathProtected {
    <#  Returns $null when the path is outside every protected zone, otherwise the reason it is protected.  #>
    param([string]$Path, [switch]$AsDestination)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'No folder is selected.' }
    if ($Path.Trim() -match '^[A-Za-z]:\\?$') { return 'A whole drive cannot be used. Choose a folder instead.' }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return 'This is not a valid folder path.' }
    if ($full.StartsWith('\\')) { return $null }
    foreach ($zone in (Get-OrganizerProtectedZone)) {
        if (-not $zone.Tree) { continue }
        if ($full -ieq $zone.Path -or $full.StartsWith($zone.Path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return "This is inside $($zone.Name), a protected system folder that Organizer never touches."
        }
    }
    if ($full -match '^[A-Za-z]:\\(\$Recycle\.Bin|System Volume Information|Recovery)(\\|$)') {
        return 'This is a protected system folder that Organizer never touches.'
    }
    $mine = $env:USERPROFILE.TrimEnd('\')
    $users = Split-Path $mine -Parent
    if ($full -ieq $users) { return 'The Users folder holds every account on this PC and cannot be used.' }
    if ($full.StartsWith($users + '\', [StringComparison]::OrdinalIgnoreCase) -and $full -ine $mine -and
        -not $full.StartsWith($mine + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not ($full + '\').StartsWith($users + '\Public\', [StringComparison]::OrdinalIgnoreCase)) {
        return 'This folder belongs to another user account.'
    }
    if (-not $AsDestination) {
        if ($full -ieq $mine) { return 'Your user folder cannot be organized. Choose a folder inside it, like Downloads.' }
        if ($full -ieq $PSScriptRoot.TrimEnd('\')) { return "This is Organizer's own folder." }
    }
    return $null
}

function Test-OrganizerFileFree([string]$Path) {
    # True when no other program has the file open.
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $stream.Dispose()
        return $true
    }
    catch { return $false }
}

function Get-OrganizerSpaceProblem {
    <#  Returns a message when a destination drive is too full for the files going to it, otherwise $null.  #>
    param([object[]]$Items)
    $needed = @{}
    foreach ($item in $Items) {
        try {
            $from = [IO.Path]::GetPathRoot($item.Path); $to = [IO.Path]::GetPathRoot($item.DestinationFolder)
            if ($to -and $to -ine $from -and -not $to.StartsWith('\\')) { $needed[$to.ToUpperInvariant()] = [long]$needed[$to.ToUpperInvariant()] + [long]$item.Size }
        }
        catch { }
    }
    foreach ($root in $needed.Keys) {
        try {
            $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
            if (($needed[$root] + 200MB) -gt $free) {
                return ('Drive {0} does not have enough free space: {1} is needed, {2} is free. Nothing was moved.' -f $root, (Format-OrganizerSize $needed[$root]), (Format-OrganizerSize $free))
            }
        }
        catch { }
    }
    return $null
}

# ------------------------------------------------------------------------------------------------
#  Categories and settings
# ------------------------------------------------------------------------------------------------
function ConvertTo-OrganizerList {
    param($Value, [switch]$Extension)
    $text = (@($Value) | Where-Object { $_ }) -join ','
    $pattern = if ($Extension) { '[,;\s]+' } else { '[,;\r\n]+' }
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($part in ($text -split $pattern)) {
        $item = $part.Trim().ToLowerInvariant()
        if ($Extension) { $item = $item.TrimStart('*').TrimStart('.') }
        if ($item -and -not $seen.ContainsKey($item)) { $seen[$item] = $true; [void]$list.Add($item) }
    }
    return , @($list)
}

function New-OrganizerCategory {
    param([string]$Id, [string]$Name, [string]$Folder, $Extensions, $Keywords, [string]$Color = '#8794A8',
        [bool]$Enabled = $true, [bool]$BuiltIn = $false)
    if (-not $Id) { $Id = 'custom-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
    if ($Color -notmatch '^#[0-9A-Fa-f]{6}$') { $Color = '#8794A8' }
    [pscustomobject]@{
        Id         = $Id
        Name       = $Name
        Folder     = $Folder
        Extensions = (ConvertTo-OrganizerList $Extensions -Extension)
        Keywords   = (ConvertTo-OrganizerList $Keywords)
        Color      = $Color.ToUpperInvariant()
        Enabled    = $Enabled
        BuiltIn    = $BuiltIn
    }
}

function Get-OrganizerDefaultCategory {
    $c = {
        param($Id, $Name, $Color, $Extensions, $Keywords)
        New-OrganizerCategory -Id $Id -Name $Name -Folder $Name -Extensions $Extensions -Keywords $Keywords -Color $Color -BuiltIn $true
    }
    @(
        & $c 'screenshots' 'Screenshots' '#56D4BE' 'png jpg jpeg webp bmp' 'screenshot, screen shot, screen_shot, snip, capture'
        & $c 'images' 'Images' '#4FA3F7' 'jpg jpeg png gif bmp webp svg heic heif tif tiff ico avif raw cr2 nef'
        & $c 'videos' 'Videos' '#B37BF2' 'mp4 mkv avi mov wmv flv webm m4v mpg mpeg 3gp ts'
        & $c 'audio' 'Audio' '#F178B6' 'mp3 wav flac aac ogg m4a wma opus mid midi'
        & $c 'documents' 'Documents' '#F2A742' 'pdf doc docx txt rtf odt md epub mobi pages'
        & $c 'spreadsheets' 'Spreadsheets' '#4CC38A' 'xls xlsx xlsm csv tsv ods numbers'
        & $c 'presentations' 'Presentations' '#F2784B' 'ppt pptx pps ppsx odp key'
        & $c 'archives' 'Archives' '#C9A227' 'zip rar 7z tar gz tgz bz2 xz iso cab'
        & $c 'installers' 'Installers' '#6C8CF5' 'exe msi msix msixbundle appx appxbundle apk dmg pkg deb'
        & $c 'code' 'Code' '#2CC5D2' 'py js ts jsx tsx html htm css json xml yml yaml ps1 psm1 sh bat cmd c cpp h cs java go rs php rb sql ipynb'
        & $c 'design' 'Design' '#E667D0' 'psd ai fig sketch xd indd blend dwg dxf obj stl fbx'
        & $c 'fonts' 'Fonts' '#9AA7B8' 'ttf otf woff woff2'
        & $c 'torrents' 'Torrents' '#7BC96F' 'torrent'
        & $c 'other' 'Other' '#8794A8'
    )
}

function Get-OrganizerDefaultSettings {
    [pscustomobject]@{
        Version       = 1
        SourceFolder  = ''
        DateFolders   = 'None'
        DetectContent = $true
        Theme         = 'System'
        Categories    = @(Get-OrganizerDefaultCategory)
    }
}

function Read-OrganizerSettings {
    $settings = Get-OrganizerDefaultSettings
    $path = Join-Path (Get-OrganizerDataDir) 'settings.json'
    if (-not [IO.File]::Exists($path)) { return $settings }
    try {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($null -ne $saved.SourceFolder) { $settings.SourceFolder = [string]$saved.SourceFolder }
        if (@('None', 'Year', 'Month') -contains $saved.DateFolders) { $settings.DateFolders = [string]$saved.DateFolders }
        if ($null -ne $saved.DetectContent) { $settings.DetectContent = [bool]$saved.DetectContent }
        if (@('System', 'Dark', 'Light') -contains $saved.Theme) { $settings.Theme = [string]$saved.Theme }
        $categories = @(foreach ($c in @($saved.Categories)) {
                if ($c -and $c.Name) {
                    New-OrganizerCategory -Id $c.Id -Name $c.Name -Folder $c.Folder -Extensions $c.Extensions -Keywords $c.Keywords `
                        -Color ([string]$c.Color) -Enabled ([bool]$c.Enabled) -BuiltIn ([bool]$c.BuiltIn)
                }
            })
        if ($categories.Count -gt 0) {
            if (-not ($categories | Where-Object { $_.Id -eq 'other' })) {
                $categories += @(Get-OrganizerDefaultCategory | Where-Object { $_.Id -eq 'other' })
            }
            $settings.Categories = $categories
        }
    }
    catch {
        try { [IO.File]::Copy($path, ($path + '.broken'), $true) } catch { }
    }
    return $settings
}

function Save-OrganizerSettings($Settings) {
    $path = Join-Path (Get-OrganizerDataDir) 'settings.json'
    $json = ConvertTo-Json -InputObject $Settings -Depth 6
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------------------------------------
#  Classification
# ------------------------------------------------------------------------------------------------
function Format-OrganizerSize([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:0.##} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0.#} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0} KB' -f ($Bytes / 1KB)) }
    return ('{0:0} B' -f $Bytes)
}

function Get-OrganizerContentType([string]$Path) {
    # Looks at the first bytes of a file and returns the extension it really is, or $null.
    $buffer = New-Object byte[] 16
    $read = 0
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $read = $stream.Read($buffer, 0, 16) } finally { $stream.Dispose() }
    }
    catch { return $null }
    if ($read -lt 4) { return $null }
    $hex = -join ($buffer[0..($read - 1)] | ForEach-Object { $_.ToString('X2') })
    $found = switch -Regex ($hex) {
        '^25504446' { 'pdf' }
        '^89504E47' { 'png' }
        '^FFD8FF' { 'jpg' }
        '^47494638' { 'gif' }
        '^504B0304' { 'zip' }
        '^52617221' { 'rar' }
        '^377ABCAF271C' { '7z' }
        '^1F8B' { 'gz' }
        '^4D5A' { 'exe' }
        '^494433' { 'mp3' }
        '^.{8}66747970' { 'mp4' }
        '^1A45DFA3' { 'mkv' }
        '^52494646.{8}57415645' { 'wav' }
        '^52494646.{8}57454250' { 'webp' }
        '^D0CF11E0' { 'doc' }
        '^7B5C727466' { 'rtf' }
    }
    return @($found)[0]
}

function Resolve-OrganizerFolder([string]$Folder, [string]$Source) {
    $text = ([string]$Folder).Trim()
    if (-not $text) { return $null }
    $text = [Environment]::ExpandEnvironmentVariables($text)
    if ($text -match '^[A-Za-z]:\\' -or $text.StartsWith('\\')) { return $text.TrimEnd('\') }
    $parts = @($text -split '[\\/]' | ForEach-Object { ($_ -replace '[<>:"|?*]', '').Trim().TrimEnd('.') } |
            Where-Object { $_ -and $_ -ne '.' -and $_ -ne '..' })
    if ($parts.Count -eq 0) { return $null }
    return [IO.Path]::Combine($Source, ($parts -join '\'))
}

function Get-OrganizerUniquePath([string]$Path) {
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return $Path }
    $dir = [IO.Path]::GetDirectoryName($Path)
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path)
    for ($i = 2; $i -lt 10000; $i++) {
        $candidate = [IO.Path]::Combine($dir, ('{0} ({1}){2}' -f $name, $i, $ext))
        if (-not [IO.File]::Exists($candidate) -and -not [IO.Directory]::Exists($candidate)) { return $candidate }
    }
    throw 'Could not find a free file name.'
}

function Get-OrganizerPlan {
    <#  Reads the folder and decides where every file would go. Moves nothing.  #>
    param($Settings)
    $source = Get-OrganizerSource $Settings
    $plan = [pscustomobject]@{
        Source = $source; Items = @(); Error = $null
        Folders = 0; InProgress = 0; Hidden = 0; Unknown = 0; Protected = @()
    }
    $plan.Error = Test-OrganizerSourceSafe $source
    if ($plan.Error) { return $plan }

    $active = @($Settings.Categories | Where-Object { $_.Enabled })
    $keywordCategories = @($active | Where-Object { $_.Id -ne 'other' -and @($_.Keywords).Count -gt 0 })
    $other = $active | Where-Object { $_.Id -eq 'other' } | Select-Object -First 1
    $byExtension = @{}
    foreach ($category in $active) {
        if ($category.Id -eq 'other' -or @($category.Keywords).Count -gt 0) { continue }
        foreach ($ext in @($category.Extensions)) { if (-not $byExtension.ContainsKey($ext)) { $byExtension[$ext] = $category } }
    }
    $sourceLeaf = [IO.Path]::GetFileName($source)
    $items = New-Object System.Collections.ArrayList

    try {
        $directory = New-Object IO.DirectoryInfo($source)
        $plan.Folders = @($directory.GetDirectories()).Count
        $files = $directory.GetFiles()
    }
    catch { $plan.Error = 'This folder could not be read: ' + $_.Exception.Message; return $plan }

    # Smart guard: loose program files. A program that sits directly in this folder (an .exe with
    # its .dll or settings files next to it) stops working when its parts are sorted apart.
    $componentExtensions = @('dll', 'sys', 'ocx', 'drv', 'pak')
    $companionExtensions = @('config', 'ini', 'dat', 'cfg', 'pdb', 'manifest', 'json')
    $allNames = @{}
    foreach ($file in $files) { $allNames[$file.Name.ToLowerInvariant()] = $true }
    $hasLooseDll = [bool]($files | Where-Object { $_.Extension -ieq '.dll' } | Select-Object -First 1)
    $programs = @{}; $programNames = @{}
    foreach ($file in $files) {
        if ($file.Extension -ine '.exe') { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        $programNames[$base] = $file.Name
        $companion = $allNames.ContainsKey("$base.exe.config") -or $allNames.ContainsKey("$base.runtimeconfig.json") -or $allNames.ContainsKey("$base.deps.json")
        foreach ($ext in ($componentExtensions + $companionExtensions)) { if ($allNames.ContainsKey("$base.$ext")) { $companion = $true } }
        if ($companion) { $programs[$base] = 'Program with its own files next to it - kept together so it keeps working' }
        elseif ($hasLooseDll) { $programs[$base] = 'Program files (.dll) are next to it - it may need them to run' }
    }
    $protected = New-Object System.Collections.ArrayList
    $guard = { param($File, $Reason) [void]$protected.Add([pscustomobject]@{ Name = $File.Name; Reason = $Reason }) }
    $destinationProblems = @{}
    $cloudOnly = 0x1000 -bor 0x40000 -bor 0x400000

    foreach ($file in $files) {
        $ext = $file.Extension.TrimStart('.').ToLowerInvariant()
        $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { & $guard $file 'Link to another location'; continue }
        if (($file.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -or $file.Name -ieq 'desktop.ini') {
            $plan.Hidden++; & $guard $file 'Hidden or system file'; continue
        }
        if ($script:IncompleteExtensions -contains $ext) { $plan.InProgress++; & $guard $file 'Download still in progress'; continue }
        if ($componentExtensions -contains $ext) { & $guard $file 'Program component - moving it could break a program'; continue }
        if ($ext -eq 'exe' -and $programs.ContainsKey($baseName)) { & $guard $file $programs[$baseName]; continue }
        $owner = $null
        if ($companionExtensions -contains $ext) {
            foreach ($candidate in @($baseName, ($baseName -replace '\.(exe|runtimeconfig|deps)$', ''))) {
                if ($programs.ContainsKey($candidate)) { $owner = $candidate }
            }
        }
        if ($owner) { & $guard $file "Belongs to the program $($programNames[$owner])"; continue }
        if ([int]$file.Attributes -band $cloudOnly) { & $guard $file 'Online-only cloud file - not downloaded to this PC'; continue }

        $category = $null; $reason = ''
        foreach ($candidate in $keywordCategories) {
            $extensions = @($candidate.Extensions)
            if ($extensions.Count -gt 0 -and $extensions -notcontains $ext) { continue }
            $hit = @($candidate.Keywords) | Where-Object { $baseName.Contains($_) } | Select-Object -First 1
            if ($hit) { $category = $candidate; $reason = "Name contains `"$hit`""; break }
        }
        if (-not $category -and $ext -and $byExtension.ContainsKey($ext)) {
            $category = $byExtension[$ext]; $reason = ".$ext file"
        }
        if (-not $category -and $Settings.DetectContent) {
            $real = Get-OrganizerContentType $file.FullName
            if ($real -and $byExtension.ContainsKey($real)) {
                $category = $byExtension[$real]; $reason = "Detected as $($real.ToUpperInvariant()) from its content"
            }
        }
        if (-not $category -and $other) {
            $category = $other; $reason = if ($ext) { "Unknown type .$ext" } else { 'No file extension' }
        }
        if (-not $category) { $plan.Unknown++; continue }

        $folder = Resolve-OrganizerFolder $category.Folder $source
        if (-not $folder) { $folder = Resolve-OrganizerFolder $category.Name $source }
        if (-not $folder) { $plan.Unknown++; continue }
        if ($Settings.DateFolders -eq 'Year') { $folder = [IO.Path]::Combine($folder, $file.LastWriteTime.ToString('yyyy')) }
        elseif ($Settings.DateFolders -eq 'Month') {
            $folder = [IO.Path]::Combine($folder, $file.LastWriteTime.ToString('yyyy'), $file.LastWriteTime.ToString('yyyy-MM'))
        }
        if ($folder -ieq $file.DirectoryName.TrimEnd('\')) { continue }
        if (-not $destinationProblems.ContainsKey($folder)) { $destinationProblems[$folder] = Test-OrganizerPathProtected $folder -AsDestination }
        if ($destinationProblems[$folder]) { & $guard $file "The folder of `"$($category.Name)`" is protected: $($destinationProblems[$folder])"; continue }
        if (-not (Test-OrganizerFileFree $file.FullName)) { & $guard $file 'Open in another program right now'; continue }

        $shown = if ($folder.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $sourceLeaf + $folder.Substring($source.Length)
        }
        else { $folder }

        [void]$items.Add([pscustomobject]@{
                Include           = $true
                Name              = $file.Name
                Path              = $file.FullName
                Size              = [long]$file.Length
                SizeText          = Format-OrganizerSize $file.Length
                CategoryId        = $category.Id
                Category          = $category.Name
                Color             = $category.Color
                ColorSoft         = '#33' + $category.Color.Substring(1)
                DestinationFolder = $folder
                DestinationText   = $shown
                Reason            = $reason
            })
    }
    $plan.Items = @($items | Sort-Object Category, Name)
    $plan.Protected = @($protected | Sort-Object Name)
    return $plan
}

# ------------------------------------------------------------------------------------------------
#  Moving files, history and undo
# ------------------------------------------------------------------------------------------------
function Get-OrganizerErrorText($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    return $exception.Message
}

function Save-OrganizerRun($Run) {
    $dir = Join-Path (Get-OrganizerDataDir) 'History'
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $json = ConvertTo-Json -InputObject $Run -Depth 5
    [IO.File]::WriteAllText((Join-Path $dir ($Run.Id + '.json')), $json, (New-Object System.Text.UTF8Encoding($false)))
    # Keep the 30 most recent runs.
    $old = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip 30)
    foreach ($file in $old) { try { $file.Delete() } catch { } }
}

function Invoke-OrganizerPlan {
    <#  Moves the given plan items. Returns what happened and records the run for undo.  #>
    param([object[]]$Items, [string]$Source, [scriptblock]$OnProgress)
    $moves = New-Object System.Collections.ArrayList
    $created = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    $folders = @{}
    $checked = @{}
    [long]$bytes = 0
    $index = 0
    foreach ($item in $Items) {
        $index++
        if ($OnProgress) { & $OnProgress $index $Items.Count $item.Name }
        try {
            if (-not [IO.File]::Exists($item.Path)) { throw 'The file is no longer there.' }
            $dir = $item.DestinationFolder
            if (-not $checked.ContainsKey($dir)) { $checked[$dir] = Test-OrganizerPathProtected $dir -AsDestination }
            if ($checked[$dir]) { throw $checked[$dir] }
            if (-not [IO.Directory]::Exists($dir)) {
                $missing = @(); $walk = $dir
                while ($walk -and -not [IO.Directory]::Exists($walk)) { $missing += $walk; $walk = [IO.Path]::GetDirectoryName($walk) }
                [void][IO.Directory]::CreateDirectory($dir)
                foreach ($m in $missing) { [void]$created.Add($m) }
            }
            $target = Get-OrganizerUniquePath ([IO.Path]::Combine($dir, $item.Name))
            [IO.File]::Move($item.Path, $target)
            [void]$moves.Add([pscustomobject]@{ From = $item.Path; To = $target; Size = $item.Size })
            $folders[$dir] = $true
            $bytes += $item.Size
        }
        catch {
            [void]$failed.Add([pscustomobject]@{ Name = $item.Name; Error = (Get-OrganizerErrorText $_) })
        }
    }
    $run = [pscustomobject]@{
        Id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff'); Time = (Get-Date).ToString('o'); Source = $Source
        Count = $moves.Count; Bytes = $bytes; Undone = $false
        Moves = @($moves); CreatedFolders = @($created)
    }
    if ($moves.Count -gt 0) { Save-OrganizerRun $run }
    [pscustomobject]@{
        Id = $(if ($moves.Count -gt 0) { $run.Id } else { $null })
        Moved = $moves.Count; Bytes = $bytes; Folders = $folders.Count; Failed = @($failed)
    }
}

function Get-OrganizerHistory {
    $dir = Join-Path (Get-OrganizerDataDir) 'History'
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    @(foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' | Sort-Object Name -Descending)) {
            try {
                $run = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                [pscustomobject]@{
                    Id = [string]$run.Id; Time = [datetime]$run.Time; Source = [string]$run.Source
                    Count = [int]$run.Count; Bytes = [long]$run.Bytes; Undone = [bool]$run.Undone
                }
            }
            catch { }
        })
}

function Undo-OrganizerRun {
    <#  Puts the files of one run back where they were.  #>
    param([string]$Id)
    $path = Join-Path (Join-Path (Get-OrganizerDataDir) 'History') ($Id + '.json')
    if (-not [IO.File]::Exists($path)) { throw 'This run is no longer in the history.' }
    $run = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $restored = 0; $missing = 0
    $moves = @($run.Moves | Where-Object { $_ })
    [array]::Reverse($moves)
    foreach ($move in $moves) {
        try {
            if (-not [IO.File]::Exists($move.To)) { $missing++; continue }
            $origin = [IO.Path]::GetDirectoryName($move.From)
            if (-not [IO.Directory]::Exists($origin)) { [void][IO.Directory]::CreateDirectory($origin) }
            [IO.File]::Move($move.To, (Get-OrganizerUniquePath $move.From))
            $restored++
        }
        catch { $missing++ }
    }
    # Remove the folders this run created, but only if they are empty again.
    foreach ($folder in (@($run.CreatedFolders | Where-Object { $_ }) | Sort-Object Length -Descending)) {
        try {
            if ([IO.Directory]::Exists($folder) -and @([IO.Directory]::GetFileSystemEntries($folder)).Count -eq 0) {
                [IO.Directory]::Delete($folder, $false)
            }
        }
        catch { }
    }
    $run.Undone = $true
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $run -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Restored = $restored; Missing = $missing }
}

Export-ModuleMember -Function *-Organizer*
