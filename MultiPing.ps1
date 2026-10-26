#Requires -Version 5.1
<#
.SYNOPSIS
    MultiPing-style GUI: continuously pings multiple hosts and shows live stats and a latency graph.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\MultiPing.ps1
    powershell -ExecutionPolicy Bypass -File .\MultiPing.ps1 -Hosts 8.8.8.8
    powershell -ExecutionPolicy Bypass -File .\MultiPing.ps1 -Hosts 8.8.8.8,1.1.1.1,google.com
    powershell -ExecutionPolicy Bypass -File .\MultiPing.ps1 -CsvPath .\devices.csv
    pwsh -File .\MultiPing.ps1 -CsvPath .\devices.csv -Hosts 10.0.0.1
.NOTES
    CSV: header row with an IP column (IP, IPAddress, Address, Host, HostName) and an optional
    name column (Name, Device, DeviceName, Description). Delimiter ',' or ';' is auto-detected.
    A CSV without header is read as: IP,Name
    Refresh rate, timeout, down threshold and log file are set in Options... and saved to
    MultiPing.settings.json next to the script. -LogPath overrides the log file for this session.
#>
param(
    [string[]]$Hosts,
    [string]$CsvPath,
    [string]$LogPath
)

# $IsWindows only exists in PS 6+; PS 5.1 is always Windows.
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'This application requires Windows (Windows Forms).'
    exit 1
}

# WinForms needs an STA thread; relaunch if the host is MTA.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe  = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Hosts)   { $argList += @('-Hosts', ($Hosts -join ',')) }
    if ($CsvPath) { $argList += @('-CsvPath', "`"$((Resolve-Path $CsvPath).Path)`"") }
    if ($LogPath) { $argList += @('-LogPath', "`"$([System.IO.Path]::GetFullPath($LogPath))`"") }
    Start-Process -FilePath $exe -ArgumentList $argList
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:HostsFile   = Join-Path $PSScriptRoot 'hosts.csv'
$script:ActiveHostsFile = $script:HostsFile
$script:LoadingTargets = $false
$script:LegacyFile  = Join-Path $PSScriptRoot 'hosts.txt'
$script:Targets     = New-Object System.Collections.ArrayList
$script:Running     = $false
$script:HistorySize = 300
$script:SettingsFile = Join-Path $PSScriptRoot 'MultiPing.settings.json'
$script:NextOrder   = 0
$script:ViewDirty   = $false
$script:Updating    = $false
$script:LastSelected = $null
$script:DefaultLog   = Join-Path $PSScriptRoot 'MultiPing.log'

#region Settings
function Get-Clamped($value, [double]$min, [double]$max, [double]$default) {
    $d = 0.0
    if (-not [double]::TryParse("$value", [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $default }
    [math]::Min($max, [math]::Max($min, $d))
}

function Import-Settings {
    $s = [ordered]@{ RefreshSeconds = 1.0; TimeoutMs = 1000; DownAfterLost = 1; LogPath = $script:DefaultLog }
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
            $s.RefreshSeconds = [math]::Round((Get-Clamped $j.RefreshSeconds 0.5 3600 $s.RefreshSeconds) * 2) / 2
            $s.TimeoutMs      = [int](Get-Clamped $j.TimeoutMs 100 10000 $s.TimeoutMs)
            $s.DownAfterLost  = [int](Get-Clamped $j.DownAfterLost 1 100 $s.DownAfterLost)
            if ("$($j.LogPath)".Trim()) { $s.LogPath = "$($j.LogPath)".Trim() }
        } catch {
            Write-Warning "Invalid settings file '$script:SettingsFile', using defaults: $($_.Exception.Message)"
        }
    }
    [pscustomobject]$s
}

function Save-Settings {
    try {
        $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {
        Write-Warning "Cannot save settings '$script:SettingsFile': $($_.Exception.Message)"
    }
}

$script:Settings = Import-Settings
$script:LogFile  = if ($LogPath) { $LogPath } else { $script:Settings.LogPath }
#endregion

#region Logic
function Write-Log([string]$message) {
    try {
        Add-Content -LiteralPath $script:LogFile -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $message" -Encoding UTF8
    } catch {
        Write-Warning "Cannot write log '$script:LogFile': $($_.Exception.Message)"
    }
}
function Start-Resolve($t) {
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($t.Name, [ref]$ip)) {
        $t.Address = $ip
    } else {
        $t.Status  = 'Resolving'
        $t.DnsTask = [System.Net.Dns]::GetHostAddressesAsync($t.Name)
    }
}

# Returns objects with IP and Name properties.
function Read-TargetCsv([string]$path) {
    $lines = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() })
    if (-not $lines) { return }
    $delim = if ($lines[0].Contains(';') -and -not $lines[0].Contains(',')) { ';' } else { ',' }
    $firstField = ($lines[0] -split [regex]::Escape($delim))[0].Trim().Trim('"')
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($firstField, [ref]$ip)) {
        $rows = @($lines | ConvertFrom-Csv -Delimiter $delim -Header 'IP', 'Name')
    } else {
        $rows = @($lines | ConvertFrom-Csv -Delimiter $delim)
    }
    if (-not $rows) { return }
    $props   = @($rows[0].PSObject.Properties.Name)
    $ipCol   = @('IP', 'IPAddress', 'IP Address', 'Address', 'Host', 'HostName') | Where-Object { $props -contains $_ } | Select-Object -First 1
    $nameCol = @('Name', 'Device', 'DeviceName', 'Device Name', 'Description') | Where-Object { $props -contains $_ } | Select-Object -First 1
    if (-not $ipCol) { $ipCol = $props[0]; if (-not $nameCol -and $props.Count -gt 1) { $nameCol = $props[1] } }
    foreach ($r in $rows) {
        [pscustomobject]@{ IP = "$($r.$ipCol)".Trim(); Name = if ($nameCol) { "$($r.$nameCol)".Trim() } else { '' } }
    }
}

function Import-TargetCsv([string]$path, [switch]$Merge) {
    try {
        $rows = @(Read-TargetCsv $path)
        $script:ActiveHostsFile = [System.IO.Path]::GetFullPath($path)
        $script:LoadingTargets = $true
        if (-not $Merge) {
            foreach ($t in $script:Targets) {
                try { $t.Ping.Dispose() } catch { }
            }
            $script:Targets.Clear()
            $grid.Rows.Clear()
            $script:LastSelected = $null
            $script:NextOrder = 0
        }
        foreach ($r in $rows) { Add-Target $r.IP $r.Name }
        [void](Save-HostsCsv)
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Cannot read CSV '$path':`n$($_.Exception.Message)", 'PS MultiPing', 'OK', 'Error')
    } finally {
        $script:LoadingTargets = $false
    }
}

function Save-HostsCsv {
    $tempPath = "$($script:ActiveHostsFile).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $directory = [System.IO.Path]::GetDirectoryName($script:ActiveHostsFile)
        if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
        $script:Targets | ForEach-Object { [pscustomobject]@{ IP = $_.Name; Name = $_.Device } } |
            Export-Csv -LiteralPath $tempPath -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $script:ActiveHostsFile -Force
        return $true
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show("Cannot update host CSV '$script:ActiveHostsFile':`n$($_.Exception.Message)", 'PS MultiPing', 'OK', 'Error')
        return $false
    }
}

function Add-Target([string]$name, [string]$device = '') {
    $name = $name.Trim()
    if (-not $name) { return }
    if ($script:Targets | Where-Object { $_.Name -eq $name }) { return }

    $t = [pscustomobject]@{
        Name = $name; Device = $device; Address = $null; DnsTask = $null; PingTask = $null
        Ping = New-Object System.Net.NetworkInformation.Ping
        LastSent = [datetime]::MinValue
        Sent = 0; Recv = 0; Lost = 0; Total = 0; Last = $null; Min = $null; Max = $null
        History = New-Object 'System.Collections.Generic.List[int]'
        Status = 'Pending'; State = 'Unknown'; Since = Get-Date; Row = $null
        Order = $script:NextOrder++
    }
    Start-Resolve $t
    $idx = $grid.Rows.Add()
    $t.Row = $grid.Rows[$idx]
    $t.Row.Tag = $t
    [void]$script:Targets.Add($t)
    Update-Row $t
    $script:ViewDirty = $true
    if (-not $script:LoadingTargets) { [void](Save-HostsCsv) }
}

function Set-TargetHost($t, [string]$name) {
    $t.Name = $name
    $t.Address = $null; $t.DnsTask = $null; $t.PingTask = $null
    # The old Ping may still have a request in flight; a busy Ping cannot be reused.
    $t.Ping = New-Object System.Net.NetworkInformation.Ping
    $t.LastSent = [datetime]::MinValue
    $t.Lost = 0; $t.Status = 'Pending'; $t.State = 'Unknown'; $t.Since = Get-Date
    Reset-Stats $t
    Start-Resolve $t
}

function Reset-Stats($t) {
    $t.Sent = 0; $t.Recv = 0; $t.Total = 0; $t.Last = $null; $t.Min = $null; $t.Max = $null
    $t.History.Clear()
    Update-Row $t
}

function Complete-Ping($t) {
    $task = $t.PingTask
    $t.PingTask = $null
    $t.Sent++
    $rtt = -1
    if ($task.Status -eq 'RanToCompletion' -and $task.Result.Status -eq 'Success') {
        $rtt = [int]$task.Result.RoundtripTime
        $t.Recv++; $t.Lost = 0; $t.Total += $rtt; $t.Last = $rtt
        if ($null -eq $t.Min -or $rtt -lt $t.Min) { $t.Min = $rtt }
        if ($null -eq $t.Max -or $rtt -gt $t.Max) { $t.Max = $rtt }
        $t.Status = 'OK'
    } elseif ($task.Status -eq 'RanToCompletion') {
        $t.Lost++; $t.Last = $null; $t.Status = [string]$task.Result.Status
    } else {
        $t.Lost++; $t.Last = $null; $t.Status = 'Error'
    }
    $t.History.Add($rtt)
    if ($t.History.Count -gt $script:HistorySize) { $t.History.RemoveAt(0) }
    Update-Row $t
}

function Update-Row($t) {
    $c = $t.Row.Cells
    # Don't overwrite a cell the user is currently editing.
    $editing = $grid.IsCurrentCellInEditMode -and $grid.CurrentCell.RowIndex -eq $t.Row.Index
    if (-not $editing) {
        $c['Device'].Value = $t.Device
        $c['Host'].Value   = $t.Name
    }
    $c['Address'].Value = if ("$($t.Address)" -ne $t.Name) { "$($t.Address)" } else { '' }
    $c['Status'].Value  = $t.Status
    $c['Last'].Value    = $t.Last
    $c['Avg'].Value     = if ($t.Recv) { [math]::Round($t.Total / $t.Recv, 1) } else { $null }
    $c['Min'].Value     = $t.Min
    $c['Max'].Value     = $t.Max
    $c['Sent'].Value    = $t.Sent
    $c['Recv'].Value    = $t.Recv
    $c['Loss'].Value    = if ($t.Sent) { [math]::Round(100 * ($t.Sent - $t.Recv) / $t.Sent, 1) } else { 0 }
    $state = switch ($t.Status) {
        'OK'                            { 'Up' }
        { $_ -in 'Pending', 'Resolving' } { 'Unknown' }
        'DNS failed'                    { 'Down' }
        default { if ($t.Lost -ge $script:Settings.DownAfterLost) { 'Down' } else { $t.State } }
    }
    $t.Row.DefaultCellStyle.BackColor = switch ($state) {
        'Up'    { [System.Drawing.Color]::FromArgb(200, 255, 200) }
        'Down'  { [System.Drawing.Color]::FromArgb(255, 190, 190) }
        default { [System.Drawing.Color]::White }
    }
    if ($state -ne $t.State) {
        if ($state -ne 'Unknown') {
            $label = if ($t.Device) { "$($t.Name) ($($t.Device))" } else { $t.Name }
            $prev  = if ($t.State -eq 'Unknown') { 'first check' } else { "was $($t.State) for $(((Get-Date) - $t.Since).ToString('d\.hh\:mm\:ss'))" }
            Write-Log ("{0,-4}  {1}  status={2}  [{3}]" -f $state.ToUpper(), $label, $t.Status, $prev)
        }
        $t.State = $state
        $t.Since = Get-Date
        $script:ViewDirty = $true
    }
}

function Get-SettingsSummary {
    $s = $script:Settings
    "refresh $($s.RefreshSeconds)s, timeout $($s.TimeoutMs)ms, down after $($s.DownAfterLost) lost ping(s)"
}

function Update-Title {
    $form.Text = "PS MultiPing - refresh $($script:Settings.RefreshSeconds)s"
}

function Show-OptionsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Options'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 200)

    $y = 15
    foreach ($text in 'Refresh rate (seconds):', 'Ping timeout (ms):', 'Down after N lost pings:', 'Log file:') {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point(12, ($y + 3))
        $dlg.Controls.Add($l)
        $y += 32
    }

    $numRefresh = New-Object System.Windows.Forms.NumericUpDown
    $numRefresh.DecimalPlaces = 1; $numRefresh.Minimum = 0.5; $numRefresh.Maximum = 3600; $numRefresh.Increment = 0.5
    $numRefresh.Value = [decimal]$script:Settings.RefreshSeconds
    $numRefresh.Location = New-Object System.Drawing.Point(170, 15); $numRefresh.Width = 80

    $numTimeout = New-Object System.Windows.Forms.NumericUpDown
    $numTimeout.Minimum = 100; $numTimeout.Maximum = 10000; $numTimeout.Increment = 100
    $numTimeout.Value = $script:Settings.TimeoutMs
    $numTimeout.Location = New-Object System.Drawing.Point(170, 47); $numTimeout.Width = 80

    $numDown = New-Object System.Windows.Forms.NumericUpDown
    $numDown.Minimum = 1; $numDown.Maximum = 100
    $numDown.Value = $script:Settings.DownAfterLost
    $numDown.Location = New-Object System.Drawing.Point(170, 79); $numDown.Width = 80

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Text = $script:LogFile
    $txtLog.Location = New-Object System.Drawing.Point(170, 111); $txtLog.Width = 195

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(372, 110); $btnBrowse.Width = 75
    $btnBrowse.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = 'Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $sfd.OverwritePrompt = $false
        $sfd.FileName = $txtLog.Text
        if ($sfd.ShowDialog($dlg) -eq 'OK') { $txtLog.Text = $sfd.FileName }
        $sfd.Dispose()
    })

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'; $btnOk.DialogResult = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(290, 160)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.DialogResult = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(372, 160)

    $dlg.Controls.AddRange(@($numRefresh, $numTimeout, $numDown, $txtLog, $btnBrowse, $btnOk, $btnCancel))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:Settings.RefreshSeconds = [double]$numRefresh.Value
        $script:Settings.TimeoutMs      = [int]$numTimeout.Value
        $script:Settings.DownAfterLost  = [int]$numDown.Value
        if ($txtLog.Text.Trim()) {
            $script:Settings.LogPath = $txtLog.Text.Trim()
            $script:LogFile = $script:Settings.LogPath
        }
        Save-Settings
        Update-Title
        Write-Log "----  Settings changed: $(Get-SettingsSummary)"
    }
    $dlg.Dispose()
}

function Get-SelectedTarget {
    if ($grid.SelectedRows.Count) { return $grid.SelectedRows[0].Tag }
    if ($grid.SelectedCells.Count) { return $grid.SelectedCells[0].OwningRow.Tag }
}

# Fixed-width hex of the address bytes sorts each octet numerically (10.0.0.9 < 10.0.0.10).
function Get-IpSortKey($t) {
    $ip = $null
    $text = if ($t.Address) { "$($t.Address)" } else { $t.Name }
    if ([System.Net.IPAddress]::TryParse($text, [ref]$ip)) {
        $family = if ($ip.AddressFamily -eq 'InterNetwork') { 0 } else { 1 }
        return "$family-" + (($ip.GetAddressBytes() | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    "2-$($t.Name.ToLowerInvariant())"
}

function Update-View {
    # Re-ordering rows would cancel an edit in progress; retry on a later tick.
    if ($grid.IsCurrentCellInEditMode) { return }
    $script:ViewDirty = $false
    $script:Updating  = $true
    $selected = if ($script:Targets.Contains($script:LastSelected)) { $script:LastSelected } else { $null }
    $rank = @{ Down = 0; Unknown = 1; Up = 2 }
    $ordered = switch ($cboSort.SelectedItem) {
        'Down first' { $script:Targets | Sort-Object @{ Expression = { $rank[$_.State] } }, @{ Expression = { Get-IpSortKey $_ } }, Order }
        'IP address' { $script:Targets | Sort-Object @{ Expression = { Get-IpSortKey $_ } }, Order }
        default      { $script:Targets | Sort-Object Order }
    }
    # A hidden row cannot stay current, so release it before re-ordering/filtering.
    $grid.CurrentCell = $null
    $i = 0
    $shown = 0
    foreach ($t in @($ordered)) {
        if ($t.Row.Index -ne $i) {
            $grid.Rows.Remove($t.Row)
            $grid.Rows.Insert($i, $t.Row)
        }
        $t.Row.Visible = switch ($cboFilter.SelectedItem) {
            'Up only'   { $t.State -eq 'Up' }
            'Down only' { $t.State -eq 'Down' }
            default     { $true }
        }
        if ($t.Row.Visible) { $shown++ }
        $i++
    }
    $grid.ClearSelection()
    if ($selected -and $selected.Row.Visible) {
        $grid.CurrentCell = $selected.Row.Cells[0]
        $selected.Row.Selected = $true
    }
    $up   = @($script:Targets | Where-Object { $_.State -eq 'Up' }).Count
    $down = @($script:Targets | Where-Object { $_.State -eq 'Down' }).Count
    $lblView.Text = "Showing $shown of $($script:Targets.Count)   (Up $up / Down $down)"
    $script:Updating = $false
    $graph.Invalidate()
}
#endregion

#region UI
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PS MultiPing'
$form.Size = New-Object System.Drawing.Size(1100, 680)
$form.StartPosition = 'CenterScreen'

$top = New-Object System.Windows.Forms.FlowLayoutPanel
$top.Dock = 'Top'; $top.AutoSize = $true; $top.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)

# Properties are applied in order (NumericUpDown needs Maximum before Value).
function New-Ctl($type, [System.Collections.Specialized.OrderedDictionary]$props) {
    $c = New-Object "System.Windows.Forms.$type"
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    [void]$top.Controls.Add($c)
    $c
}
$lblMargin = New-Object System.Windows.Forms.Padding(3, 7, 0, 0)
$lblHost  = New-Ctl Label   ([ordered]@{ Text = 'Host(s):'; AutoSize = $true; Margin = $lblMargin })
$txtHost  = New-Ctl TextBox ([ordered]@{ Width = 220 })
$btnAdd   = New-Ctl Button  ([ordered]@{ Text = 'Add' })
$btnDel   = New-Ctl Button  ([ordered]@{ Text = 'Remove' })
$btnRun   = New-Ctl Button  ([ordered]@{ Text = 'Start'; Width = 80 })
$btnReset = New-Ctl Button  ([ordered]@{ Text = 'Reset stats'; Width = 85 })
$btnCsv   = New-Ctl Button  ([ordered]@{ Text = 'Import CSV...'; Width = 90 })
$btnOpt   = New-Ctl Button  ([ordered]@{ Text = 'Options...'; Width = 80 })
$sepMargin = New-Object System.Windows.Forms.Padding(14, 7, 0, 0)
$lblFilter = New-Ctl Label  ([ordered]@{ Text = 'Show:'; AutoSize = $true; Margin = $sepMargin })
$cboFilter = New-Ctl ComboBox ([ordered]@{ DropDownStyle = 'DropDownList'; Width = 90 })
$cboFilter.Items.AddRange([object[]]@('All', 'Up only', 'Down only'))
$cboFilter.SelectedIndex = 0
$lblSort   = New-Ctl Label  ([ordered]@{ Text = 'Sort:'; AutoSize = $true; Margin = $lblMargin })
$cboSort   = New-Ctl ComboBox ([ordered]@{ DropDownStyle = 'DropDownList'; Width = 100 })
$cboSort.Items.AddRange([object[]]@('Added order', 'Down first', 'IP address'))
$cboSort.SelectedIndex = 0
$lblView   = New-Ctl Label  ([ordered]@{ AutoSize = $true; Margin = $sepMargin; ForeColor = [System.Drawing.Color]::DimGray })

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $true
$grid.SelectionMode = 'RowHeaderSelect'
$grid.MultiSelect = $false
$grid.ClipboardCopyMode = 'EnableWithoutHeaderText'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [System.Drawing.Color]::White
foreach ($col in @('Device','Host','Address','Status','Last','Avg','Min','Max','Sent','Recv','Loss')) {
    $header = switch ($col) { 'Host' {'Host / IP'} 'Address' {'Resolved IP'} 'Last' {'Last (ms)'} 'Avg' {'Avg (ms)'} 'Min' {'Min (ms)'} 'Max' {'Max (ms)'} 'Loss' {'Loss %'} default { $col } }
    [void]$grid.Columns.Add($col, $header)
    $grid.Columns[$col].SortMode = 'NotSortable'
    $grid.Columns[$col].ReadOnly = $col -notin 'Device', 'Host'
}
$grid.Columns['Device'].ToolTipText  = 'Double-click or F2 to edit'
$grid.Columns['Host'].ToolTipText    = 'IP or host name to ping. Double-click or F2 to edit'
$grid.Columns['Address'].ToolTipText = 'IP address resolved from the host name (empty when you entered an IP)'
$grid.Columns['Device'].FillWeight = 200
$grid.Columns['Host'].FillWeight = 180
$grid.Columns['Address'].FillWeight = 160
$grid.Columns['Status'].FillWeight = 140
$split.Panel1.Controls.Add($grid)

$graph = New-Object System.Windows.Forms.PictureBox
$graph.Dock = 'Fill'
$graph.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$split.Panel2.Controls.Add($graph)

# Shared GDI objects for the chart, created once to avoid leaking handles on every repaint.
$accent = [System.Drawing.Color]::FromArgb(46, 204, 113)
$script:Gfx = @{
    Back      = [System.Drawing.Color]::FromArgb(30, 30, 30)
    Accent    = $accent
    PlotBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(37, 37, 38))
    GridPen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(58, 58, 62)), 1
    LinePen   = New-Object System.Drawing.Pen $accent, 2
    AvgPen    = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 255, 193, 7)), 1
    DotBrush  = New-Object System.Drawing.SolidBrush $accent
    LossBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 231, 76, 60))
    UpBrush   = New-Object System.Drawing.SolidBrush $accent
    DownBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(231, 76, 60))
    IdleBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Gray)
    AvgBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 193, 7))
    TextBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Gainsboro)
    DimBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 150, 150))
    Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
    TitleFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
}
$script:Gfx.LinePen.LineJoin = 'Round'
$script:Gfx.AvgPen.DashStyle = 'Dash'

$form.Controls.Add($split)
$form.Controls.Add($top)
$split.BringToFront()
$form.AcceptButton = $btnAdd
Update-Title
#endregion

#region Events
$btnAdd.Add_Click({
    foreach ($h in ($txtHost.Text -split '[,;\s]+')) { Add-Target $h }
    $txtHost.Clear()
})

$btnDel.Add_Click({
    $t = Get-SelectedTarget
    if ($t) {
        $grid.Rows.Remove($t.Row)
        [void]$script:Targets.Remove($t)
        [void](Save-HostsCsv)
        $script:ViewDirty = $true
        $graph.Invalidate()
    }
})

$btnRun.Add_Click({
    $script:Running = -not $script:Running
    $btnRun.Text = if ($script:Running) { 'Stop' } else { 'Start' }
    Write-Log $(if ($script:Running) { "----  Monitoring started ($(Get-SettingsSummary))" } else { '----  Monitoring stopped' })
    if ($script:Running) {
        foreach ($t in $script:Targets) { if (-not $t.Address -and -not $t.DnsTask) { Start-Resolve $t; Update-Row $t } }
    }
})

$btnReset.Add_Click({ foreach ($t in $script:Targets) { Reset-Stats $t }; $graph.Invalidate() })

$btnCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $merge = $false
        if ($script:Targets.Count) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Merge the imported devices into the current list?`n`nYes: merge`nNo: replace the current list`nCancel: do nothing",
                'Import devices', 'YesNoCancel', 'Question', 'Button2'
            )
            if ($choice -eq 'Cancel') { $dlg.Dispose(); return }
            $merge = $choice -eq 'Yes'
        }
        Import-TargetCsv $dlg.FileName -Merge:$merge
    }
    $dlg.Dispose()
})

$btnOpt.Add_Click({ Show-OptionsDialog })

$grid.Add_SelectionChanged({
    # Remember the user's choice so it comes back when a filter hides and re-shows the row.
    if (-not $script:Updating) { $t = Get-SelectedTarget; if ($t) { $script:LastSelected = $t } }
    $graph.Invalidate()
})
$cboFilter.Add_SelectedIndexChanged({ Update-View })

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -ge 0 -and -not $grid.Columns[$e.ColumnIndex].ReadOnly) { [void]$grid.BeginEdit($true) }
})

$grid.Add_CellEndEdit({
    param($s, $e)
    $row = $grid.Rows[$e.RowIndex]
    $t   = $row.Tag
    $col = $grid.Columns[$e.ColumnIndex].Name
    $v   = "$($row.Cells[$col].Value)".Trim()
    if ($col -eq 'Device' -and $v -ne $t.Device) {
        Write-Log "EDIT  $($t.Name)  device '$($t.Device)' -> '$v'"
        $t.Device = $v
        [void](Save-HostsCsv)
    } elseif ($col -eq 'Host' -and $v -ne $t.Name) {
        $err = if (-not $v) { 'Host / IP cannot be empty.' }
               elseif ([System.Uri]::CheckHostName($v) -eq 'Unknown') { "'$v' is not a valid IP address or host name." }
               elseif ($script:Targets | Where-Object { -not [object]::ReferenceEquals($_, $t) -and $_.Name -eq $v }) { "'$v' is already in the list." }
        if ($err) {
            $row.Cells['Host'].Value = $t.Name
            [void][System.Windows.Forms.MessageBox]::Show($err, 'PS MultiPing', 'OK', 'Warning')
            return
        }
        Write-Log "EDIT  $($t.Name) -> $v$(if ($t.Device) { "  ($($t.Device))" })  (stats reset)"
        Set-TargetHost $t $v
        [void](Save-HostsCsv)
    }
    Update-Row $t
    $script:ViewDirty = $true
    $graph.Invalidate()
})
$cboSort.Add_SelectedIndexChanged({ Update-View })
$graph.Add_Resize({ $graph.Invalidate() })

$graph.Add_Paint({
    param($s, $e)
    $g  = $e.Graphics
    $gx = $script:Gfx
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.Clear($gx.Back)

    $t = Get-SelectedTarget
    if (-not $t) {
        $msg = 'Select a host to view its latency curve'
        $sz  = $g.MeasureString($msg, $gx.TitleFont)
        $g.DrawString($msg, $gx.TitleFont, $gx.DimBrush, [single](($s.ClientSize.Width - $sz.Width) / 2), [single](($s.ClientSize.Height - $sz.Height) / 2))
        return
    }

    # Header: status dot, name, stats
    $dot = switch ($t.State) { 'Up' { $gx.UpBrush } 'Down' { $gx.DownBrush } default { $gx.IdleBrush } }
    $g.FillEllipse($dot, [single]12, [single]9, [single]10, [single]10)
    $title = if ($t.Device) { "$($t.Device)  -  $($t.Name)" } else { $t.Name }
    if ($t.Address -and "$($t.Address)" -ne $t.Name) { $title += "  [$($t.Address)]" }
    $g.DrawString($title, $gx.TitleFont, $gx.TextBrush, [single]28, [single]5)
    $avg   = if ($t.Recv) { [math]::Round($t.Total / $t.Recv, 1) } else { $null }
    $fmtMs = { param($v) if ($null -eq $v) { '-' } else { "$v ms" } }
    $stats = "Last $(& $fmtMs $t.Last)    Avg $(& $fmtMs $avg)    Min $(& $fmtMs $t.Min)    Max $(& $fmtMs $t.Max)    Loss $($t.Row.Cells['Loss'].Value)%"
    $sz = $g.MeasureString($stats, $gx.Font)
    $g.DrawString($stats, $gx.Font, $gx.DimBrush, [single]($s.ClientSize.Width - $sz.Width - 12), [single]8)

    $plot = New-Object System.Drawing.RectangleF([single]58, [single]32, [single]($s.ClientSize.Width - 74), [single]($s.ClientSize.Height - 58))
    if ($plot.Width -lt 60 -or $plot.Height -lt 40) { return }
    $g.FillRectangle($gx.PlotBrush, $plot)

    # Y scale rounded to a 1/2/5 step
    $hist   = $t.History.ToArray()
    $valid  = @($hist | Where-Object { $_ -ge 0 })
    $maxVal = if ($valid.Count) { [double]($valid | Measure-Object -Maximum).Maximum } else { 0 }
    $span   = [math]::Max(5, $maxVal * 1.15)
    $raw    = $span / 4
    $mag    = [math]::Pow(10, [math]::Floor([math]::Log10($raw)))
    $n      = $raw / $mag
    $step   = $(if ($n -le 1) { 1 } elseif ($n -le 2) { 2 } elseif ($n -le 5) { 5 } else { 10 }) * $mag
    $top    = [math]::Ceiling($span / $step) * $step
    $toY    = { param($v) [single]($plot.Bottom - $v / $top * $plot.Height) }

    for ($v = 0; $v -le $top + 0.001; $v += $step) {
        $y = & $toY $v
        $g.DrawLine($gx.GridPen, $plot.Left, $y, $plot.Right, $y)
        $lbl = "$v ms"
        $sz  = $g.MeasureString($lbl, $gx.Font)
        $g.DrawString($lbl, $gx.Font, $gx.DimBrush, [single]($plot.Left - $sz.Width - 4), [single]($y - $sz.Height / 2))
    }

    # X axis: time ago, based on the current refresh rate
    $dx = $plot.Width / ($script:HistorySize - 1)
    for ($k = 0; $k -lt $script:HistorySize; $k += 60) {
        $x = [single]($plot.Right - $k * $dx)
        $g.DrawLine($gx.GridPen, $x, $plot.Top, $x, $plot.Bottom)
        $secs = $k * $script:Settings.RefreshSeconds
        $lbl  = if ($k -eq 0) { 'now' } elseif ($secs -lt 120) { "-$($secs)s" } else { "-$([math]::Round($secs / 60, 1))m" }
        $sz   = $g.MeasureString($lbl, $gx.Font)
        $g.DrawString($lbl, $gx.Font, $gx.DimBrush, [single]($x - $sz.Width / 2), [single]($plot.Bottom + 4))
    }

    # Build curve segments, split at lost pings (drawn as red bands)
    $g.SetClip($plot)
    $count    = $hist.Count
    $segments = New-Object System.Collections.ArrayList
    $segment  = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $bandW    = [single][math]::Max(2, $dx)
    for ($i = 0; $i -lt $count; $i++) {
        $x = [single]($plot.Right - ($count - 1 - $i) * $dx)
        if ($hist[$i] -lt 0) {
            $g.FillRectangle($gx.LossBrush, [single]($x - $bandW / 2), $plot.Top, $bandW, $plot.Height)
            if ($segment.Count) { [void]$segments.Add($segment.ToArray()); $segment.Clear() }
        } else {
            $segment.Add((New-Object System.Drawing.PointF($x, (& $toY $hist[$i]))))
        }
    }
    if ($segment.Count) { [void]$segments.Add($segment.ToArray()) }

    $area = New-Object System.Drawing.Drawing2D.LinearGradientBrush($plot,
        [System.Drawing.Color]::FromArgb(120, $gx.Accent), [System.Drawing.Color]::FromArgb(5, $gx.Accent),
        [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    foreach ($pts in $segments) {
        if ($pts.Count -eq 1) {
            $g.FillEllipse($gx.DotBrush, [single]($pts[0].X - 2.5), [single]($pts[0].Y - 2.5), [single]5, [single]5)
            continue
        }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddCurve($pts, [single]0.3)
        $path.AddLine($pts[-1].X, $plot.Bottom, $pts[0].X, $plot.Bottom)
        $path.CloseFigure()
        $g.FillPath($area, $path)
        $path.Dispose()
        $g.DrawCurve($gx.LinePen, $pts, [single]0.3)
    }
    $area.Dispose()

    if ($null -ne $avg) {
        $y = & $toY $avg
        $g.DrawLine($gx.AvgPen, $plot.Left, $y, $plot.Right, $y)
        $g.DrawString("avg $avg ms", $gx.Font, $gx.AvgBrush, [single]($plot.Left + 4), [single]($y - 16))
    }

    $g.ResetClip()

    # Highlight the latest sample
    if ($count -and $hist[-1] -ge 0) {
        $y = & $toY $hist[-1]
        $g.FillEllipse($gx.TextBrush, [single]($plot.Right - 5), [single]($y - 5), [single]10, [single]10)
        $g.FillEllipse($gx.DotBrush, [single]($plot.Right - 3.5), [single]($y - 3.5), [single]7, [single]7)
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $now      = Get-Date
    $interval = $script:Settings.RefreshSeconds * 1000
    $timeout  = $script:Settings.TimeoutMs
    $changed  = $false
    foreach ($t in @($script:Targets)) {
        if ($t.DnsTask) {
            if ($t.DnsTask.IsCompleted) {
                if ($t.DnsTask.Status -eq 'RanToCompletion' -and $t.DnsTask.Result.Count) {
                    $addr = $t.DnsTask.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                    $t.Address = if ($addr) { $addr } else { $t.DnsTask.Result[0] }
                    $t.Status = 'Pending'
                } else {
                    $t.Status = 'DNS failed'
                }
                $t.DnsTask = $null
                $script:ViewDirty = $true
                Update-Row $t
            }
            continue
        }
        if ($t.PingTask -and $t.PingTask.IsCompleted) { Complete-Ping $t; $changed = $true }
        if ($script:Running -and $t.Address -and -not $t.PingTask -and ($now - $t.LastSent).TotalMilliseconds -ge $interval) {
            $t.LastSent = $now
            $t.PingTask = $t.Ping.SendPingAsync($t.Address, $timeout)
        }
    }
    if ($changed) { $graph.Invalidate() }
    if ($script:ViewDirty) { Update-View }
})

$form.Add_Shown({
    $split.SplitterDistance = [int]($split.Height * 0.55)
    if ($Hosts -or $CsvPath) {
        if ($CsvPath) { Import-TargetCsv $CsvPath }
        # "-File" passes "a,b" as one string, so split each entry as well.
        foreach ($h in ($Hosts -split '[,;\s]+')) { Add-Target $h }
    } elseif (Test-Path $script:HostsFile) {
        Import-TargetCsv $script:HostsFile
    } elseif (Test-Path $script:LegacyFile) {
        foreach ($h in Get-Content $script:LegacyFile) { Add-Target $h }
    }
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    Write-Log '----  Application closed'
    [void](Save-HostsCsv)
})
#endregion

[void]$form.ShowDialog()
$form.Dispose()
