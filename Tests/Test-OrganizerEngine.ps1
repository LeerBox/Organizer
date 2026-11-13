#requires -Version 5.1
<#  Engine test. Works only inside a temporary folder; never touches the real Downloads.  #>
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot ('_work-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$source = Join-Path $root 'Downloads'
$custom = Join-Path $root 'Finance'
[void](New-Item -ItemType Directory -Path $source, (Join-Path $source 'Existing Folder') -Force)
$env:ORGANIZER_DATA_DIR = Join-Path $root 'Data'
Import-Module (Join-Path $PSScriptRoot '..\OrganizerEngine.psm1') -Force -DisableNameChecking

$script:Failures = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  ok    $Name" } else { $script:Failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

try {
    foreach ($name in 'photo.JPG', 'movie.mp4', 'song.mp3', 'report.pdf', 'budget.xlsx', 'setup.exe', 'data [1].zip',
        'Screenshot 2026-11-01.png', 'invoice-2026-10.pdf', 'weird.xyz', 'half.crdownload') {
        Set-Content -LiteralPath (Join-Path $source $name) -Value 'sample'
    }
    [IO.File]::WriteAllBytes((Join-Path $source 'mystery'), [byte[]](0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37))
    Set-Content -LiteralPath (Join-Path $source 'secret.txt') -Value 'x'
    (Get-Item -LiteralPath (Join-Path $source 'secret.txt')).Attributes = 'Hidden'
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'Documents'))
    Set-Content -LiteralPath (Join-Path $source 'Documents\report.pdf') -Value 'already here'

    $settings = Get-OrganizerDefaultSettings
    $settings.SourceFolder = $source
    $settings.Categories = @(New-OrganizerCategory -Name 'Invoices' -Folder $custom -Extensions 'pdf' -Keywords 'invoice, rechnung' -Color '#FF8800') + $settings.Categories
    Save-OrganizerSettings $settings
    $settings = Read-OrganizerSettings

    Check 'settings round-trip keeps custom category' ($settings.Categories[0].Name -eq 'Invoices' -and $settings.Categories[0].Keywords.Count -eq 2)

    $plan = Get-OrganizerPlan $settings
    $map = @{}; foreach ($i in $plan.Items) { $map[$i.Name] = $i }
    Check 'no error' (-not $plan.Error)
    Check 'plans 11 files' ($plan.Items.Count -eq 11)
    Check 'jpg -> Images' ($map['photo.JPG'].Category -eq 'Images')
    Check 'screenshot keyword wins over Images' ($map['Screenshot 2026-11-01.png'].Category -eq 'Screenshots')
    Check 'invoice -> custom folder outside Downloads' ($map['invoice-2026-10.pdf'].DestinationFolder -eq $custom)
    Check 'plain pdf -> Documents' ($map['report.pdf'].Category -eq 'Documents')
    Check 'content detection finds PDF' ($map['mystery'].Category -eq 'Documents')
    Check 'unknown -> Other' ($map['weird.xyz'].Category -eq 'Other')
    Check 'unfinished download skipped' ($plan.InProgress -eq 1 -and -not $map.ContainsKey('half.crdownload'))
    Check 'hidden file skipped' ($plan.Hidden -eq 1)
    Check 'folders counted, not planned' ($plan.Folders -eq 2)

    $script:Ticks = 0
    $result = Invoke-OrganizerPlan -Items $plan.Items -Source $plan.Source -OnProgress { $script:Ticks++ }
    Check 'moved 11' ($result.Moved -eq 11 -and $result.Failed.Count -eq 0)
    Check 'progress reported' ($script:Ticks -eq 11)
    Check 'custom folder received invoice' (Test-Path -LiteralPath (Join-Path $custom 'invoice-2026-10.pdf'))
    Check 'name clash renamed, nothing overwritten' ((Test-Path -LiteralPath (Join-Path $source 'Documents\report (2).pdf')) -and
        (Get-Content -LiteralPath (Join-Path $source 'Documents\report.pdf')) -eq 'already here')
    Check 'brackets in name handled' (Test-Path -LiteralPath (Join-Path $source 'Archives\data [1].zip'))
    Check 'existing folder untouched' (Test-Path -LiteralPath (Join-Path $source 'Existing Folder'))
    Check 'second scan finds nothing' ((Get-OrganizerPlan $settings).Items.Count -eq 0)

    $history = @(Get-OrganizerHistory)
    Check 'history has the run' ($history.Count -eq 1 -and $history[0].Count -eq 11 -and -not $history[0].Undone)

    $undo = Undo-OrganizerRun -Id $result.Id
    Check 'undo restored 11' ($undo.Restored -eq 11 -and $undo.Missing -eq 0)
    Check 'files are back' ((Test-Path -LiteralPath (Join-Path $source 'photo.JPG')) -and (Test-Path -LiteralPath (Join-Path $source 'report.pdf')))
    Check 'created folders removed' (-not (Test-Path -LiteralPath (Join-Path $source 'Images')) -and -not (Test-Path -LiteralPath $custom))
    Check 'pre-existing Documents kept' (Test-Path -LiteralPath (Join-Path $source 'Documents\report.pdf'))
    Check 'history marked undone' (@(Get-OrganizerHistory)[0].Undone)

    # ---- Smart safety guards ----
    foreach ($name in 'tool.exe', 'tool.dll', 'tool.ini', 'helper.dll') { Set-Content -LiteralPath (Join-Path $source $name) -Value 'x' }
    $openPath = Join-Path $source 'open.pdf'
    Set-Content -LiteralPath $openPath -Value 'x'
    $lock = [IO.File]::Open($openPath, 'Open', 'Read', 'Read')
    $settings.Categories[0].Folder = Join-Path $env:SystemRoot 'Invoices'
    $guarded = Get-OrganizerPlan $settings
    $lock.Dispose()
    $reasons = @{}; foreach ($entry in $guarded.Protected) { $reasons[$entry.Name] = $entry.Reason }
    Check 'loose .dll is protected' ($reasons['helper.dll'] -like 'Program component*')
    Check 'program kept together with its files' ($reasons['tool.exe'] -like 'Program with*' -and $reasons['tool.ini'] -like 'Belongs to*')
    Check 'other .exe next to .dll files protected' ($reasons['setup.exe'] -like 'Program files*')
    Check 'file open in another program protected' ($reasons['open.pdf'] -like 'Open in another*')
    Check 'category pointing into Windows refused' ($reasons['invoice-2026-10.pdf'] -like '*protected*')
    Check 'protected files are not in the plan' (-not ($guarded.Items | Where-Object { $reasons.ContainsKey($_.Name) }))
    Check 'normal files still planned' ([bool]($guarded.Items | Where-Object Name -eq 'photo.JPG'))

    $forged = [pscustomobject]@{ Name = 'report.pdf'; Path = (Join-Path $source 'report.pdf'); Size = 1; DestinationFolder = (Join-Path $env:ProgramFiles 'OrganizerTest') }
    $blocked = Invoke-OrganizerPlan -Items @($forged) -Source $source
    Check 'move into Program Files blocked at move time' ($blocked.Moved -eq 0 -and $blocked.Failed.Count -eq 1 -and (Test-Path -LiteralPath $forged.Path) -and
        -not (Test-Path -LiteralPath $forged.DestinationFolder))

    foreach ($name in 'tool.exe', 'tool.dll', 'tool.ini', 'helper.dll', 'open.pdf') { Remove-Item -LiteralPath (Join-Path $source $name) }
    $settings.Categories[0].Folder = $custom

    Check 'Program Files subfolder protected' ([bool](Test-OrganizerPathProtected (Join-Path $env:ProgramFiles 'Some App')))
    Check 'AppData protected' ([bool](Test-OrganizerPathProtected $env:APPDATA -AsDestination))
    Check 'drive root refused as destination' ([bool](Test-OrganizerPathProtected 'D:\' -AsDestination))
    Check 'Recycle Bin protected' ([bool](Test-OrganizerPathProtected ($env:SystemDrive + '\$Recycle.Bin\x')))
    Check 'another user account protected' ([bool](Test-OrganizerPathProtected ((Split-Path $env:USERPROFILE -Parent) + '\SomeoneElse\Downloads')))
    Check 'normal folder allowed' (-not (Test-OrganizerPathProtected $source) -and -not (Test-OrganizerPathProtected 'D:\Finance\Invoices' -AsDestination))
    $repo = Join-Path $root 'Repo'; [void](New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force)
    Check 'code project refused as source' ((Test-OrganizerSourceSafe $repo) -like '*code project*')
    $app = Join-Path $root 'App'; [void](New-Item -ItemType Directory -Path $app -Force); Set-Content -LiteralPath (Join-Path $app 'unins000.exe') -Value 'x'
    Check 'installed program refused as source' ((Test-OrganizerSourceSafe $app) -like '*installed program*')
    Check 'own folder refused as source' ([bool](Test-OrganizerSourceSafe (Join-Path $PSScriptRoot '..')))

    $settings.DateFolders = 'Month'
    $dated = (Get-OrganizerPlan $settings).Items | Where-Object Name -eq 'movie.mp4'
    Check 'date folders' ($dated.DestinationFolder -eq (Join-Path $source ('Videos\{0:yyyy}\{0:yyyy-MM}' -f (Get-Date))))

    Check 'drive root refused' ([bool](Test-OrganizerSourceSafe 'C:\'))
    Check 'Windows folder refused' ([bool](Test-OrganizerSourceSafe $env:SystemRoot))
    Check 'user profile refused' ([bool](Test-OrganizerSourceSafe $env:USERPROFILE))
}
finally {
    Remove-Item Env:\ORGANIZER_DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:Failures) { Write-Host "`n$($script:Failures) check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed."
