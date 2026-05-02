<# : batch portion
@echo off
:: ===========================================================================
::   IITD Proxy Keep-Alive Utility
:: ===========================================================================
::   Author:       Akhil A
::   Version:      3.1
::   Date:         2026-05-02
::   License:      MIT
::   Description:  Automates authentication for IIT Delhi Proxy servers.
::                 Prevents session timeouts and manages system proxy settings.
::                 Most of the code is written by Claude Opus 4.5 and Gemini 3.0.
::   URL:          https://akhilabburu.github.io/iitd/proxy_persistent.html
:: ===========================================================================

:: Check PowerShell version (5.1+ required) before doing anything else
powershell -NoProfile -Command "if($PSVersionTable.PSVersion -lt [Version]'5.1'){exit 1}"
if %errorlevel% neq 0 (
    echo ===================================================
    echo ERROR: PowerShell 5.1 is required.
    echo Your system has an older version.
    echo.
    echo Please install:
    echo   1. .NET Framework 4.5.2+
    echo   2. WMF 5.1
    echo   3. Reboot your PC.
    echo ===================================================
    pause
    exit
)

:: Check for hidden flag. If not present, launch invisible instance and exit.
if "%1"=="h" goto :run
powershell -NoProfile -WindowStyle Hidden -Command "$w=New-Object -ComObject WScript.Shell;$w.Run('cmd /c \""%~f0\"" h',0)"
exit

:run
set SCRIPT_SELF_PATH=%~f0
title IITD Proxy Keep-Alive
cd /d %~dp0
:: Load the PowerShell portion below using Invoke-Expression
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock { iex ((Get-Content '%~f0') -join [Environment]::NewLine) } | Out-Null"
exit /b
: end batch / begin powershell #>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==========================================
# TLS HARDENING
# ==========================================
# PS 5.1 on stock Win10 defaults to TLS 1.0/1.1 which IITD/Google may reject.
# Tls12 has shipped since .NET 4.5; Tls13 only on 4.8+, so guard both.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}

# ==========================================
# SINGLE-INSTANCE GUARD
# ==========================================
# Per-user lock: prevents accidental dual launches. The batch hidden-relauncher
# above means a stray double-click would otherwise spawn two tray icons + timers.
$script:mutexCreated = $false
# Use ::new() rather than New-Object so the [ref] (out bool) binds reliably
$script:mutex = [System.Threading.Mutex]::new($true, "Local\IITDProxyKeepAlive", [ref]$script:mutexCreated)
if (-not $script:mutexCreated) { exit }

# ==========================================
# CONFIGURATION & WININET INTEROP
# ==========================================
# P/Invoke signature to refresh system proxy settings immediately without a reboot
$sig = @'
[DllImport("wininet.dll", SetLastError = true, CharSet=CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
$wininet = Add-Type -MemberDefinition $sig -Name WinInet -Namespace Win32 -PassThru

$script:Constants = @{
    INTERNET_OPTION_SETTINGS_CHANGED = 39
    INTERNET_OPTION_REFRESH          = 37
}

$script:Config = @{
    ConfigFile        = ".\proxy_config.json"
    KeepAliveInterval = 120
    RequestTimeout    = 30
    MaxLogLines       = 2000
    UserAgent         = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/141.0"
}

$script:StartupRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:StartupRegName = "IITDProxy"

# IITD Proxy mapping (Category -> Server Port)
$script:ProxyMap = @{
    'btech'=22; 'dual'=62; 'diit'=21; 'faculty'=82; 'integrated'=21; 'mtech'=62; 
    'phd'=61; 'retfaculty'=82; 'staff'=21; 'irdstaff'=21; 'mba'=21; 'mdes'=21; 
    'msc'=21; 'msr'=21; 'pgdip'=21
}

# Global State
$script:proxySession = $null
$script:sessionId    = $null
$script:targetUrl    = $null
$script:headers      = $null
$script:creds        = $null
$script:notifyIcon   = $null
$script:timer        = $null
$script:logForm      = $null
$script:txtLogBox    = $null
$global:logHistory   = New-Object System.Text.StringBuilder

# Cached GDI+ Icons
$script:iconGood     = $null
$script:iconBad      = $null
$script:iconNeutral  = [System.Drawing.Icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")

# ==========================================
# LOGGING & IO
# ==========================================
function Get-LogColor {
    param([string]$Type)
    switch ($Type) {
        "ERROR"   { return [System.Drawing.Color]::FromArgb(200,  35,  35) }
        "WARN"    { return [System.Drawing.Color]::FromArgb(180, 100,   0) }
        "SERVER"  { return [System.Drawing.Color]::FromArgb(160,  20,  80) }
        "SUCCESS" { return [System.Drawing.Color]::FromArgb(  0, 130,  50) }
        "SYSTEM"  { return [System.Drawing.Color]::FromArgb(  0,  90, 160) }
        default   { return [System.Drawing.Color]::Black }
    }
}

function Append-LogLine {
    # Appends one line to the RichTextBox in $Type's color. Caller is on UI thread.
    param($Rtb, [string]$Line, [string]$Type)
    $start = $Rtb.TextLength
    $Rtb.AppendText($Line + "`r`n")
    $Rtb.Select($start, $Line.Length)
    $Rtb.SelectionColor = Get-LogColor $Type
    $Rtb.Select($Rtb.TextLength, 0)
    $Rtb.SelectionColor = [System.Drawing.Color]::Black
    $Rtb.ScrollToCaret()
}

function Write-Log {
    param($Msg, $Type="INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] [$Type] $Msg"

    # Simple circular buffer logic to prevent memory bloat
    if ($global:logHistory.Length -gt 50000) {
        $global:logHistory.Remove(0, 10000) | Out-Null
    }
    $global:logHistory.AppendLine($line) | Out-Null

    # Thread-safe UI update with color
    if ($script:txtLogBox -and -not $script:txtLogBox.IsDisposed) {
        if ($script:txtLogBox.InvokeRequired) {
            $script:txtLogBox.Invoke([Action]{ Append-LogLine $script:txtLogBox $line $Type }) | Out-Null
        } else {
            Append-LogLine $script:txtLogBox $line $Type
        }
    }
}

function Import-ProxyConfig {
    if (-not (Test-Path $script:Config.ConfigFile)) { return $null }
    try {
        $data = Get-Content $script:Config.ConfigFile -Force -Raw | ConvertFrom-Json

        # Decrypt password if present
        $plainPass = $null
        if ($data.Password) {
            try {
                $secure   = ConvertTo-SecureString $data.Password   # DPAPI decrypt
                $plainPass = [System.Net.NetworkCredential]::new("", $secure).Password
            } catch {
                Write-Log "Could not decrypt saved password (wrong user/machine?)" "WARN"
            }
        }

        return @{
            Username       = $data.Username
            Category       = $data.Category
            Password       = $plainPass
            AutoLogin      = [bool]$data.AutoLogin
            StartOnStartup = [bool]$data.StartOnStartup
            UpdateSysProxy = $(if ($null -eq $data.UpdateSysProxy) { $true } else { [bool]$data.UpdateSysProxy })
        }
    } catch {
        Write-Log "Config read error: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Export-ProxyConfig {
    param($User, $Pass, $Category, $AutoLogin, $StartOnStartup, $UpdateSys)

    $encPass = $null
    if ($Pass) {
        # DPAPI: encrypted blob is tied to current Windows user account on this machine
        $encPass = ConvertFrom-SecureString (ConvertTo-SecureString $Pass -AsPlainText -Force)
    }

    @{
        Username        = $User
        Category        = $Category
        Password        = $encPass
        AutoLogin       = $AutoLogin
        StartOnStartup  = $StartOnStartup
        UpdateSysProxy  = $UpdateSys
    } | ConvertTo-Json | Set-Content $script:Config.ConfigFile -Force

    # Hide the config file so users don't accidentally delete it
    try { (Get-Item $script:Config.ConfigFile -Force).Attributes = "Hidden" } catch {}
}

function Clear-SavedPassword {
    # Called when an auto-login attempt with the saved DPAPI password fails
    # (typically because the user changed their IITD password). Wipes the
    # password + AutoLogin flag while keeping username/category/preferences,
    # so the next manual login can re-save a working password cleanly.
    if (-not (Test-Path $script:Config.ConfigFile)) { return }
    try {
        $data = Get-Content $script:Config.ConfigFile -Force -Raw | ConvertFrom-Json
        @{
            Username        = $data.Username
            Category        = $data.Category
            Password        = $null
            AutoLogin       = $false
            StartOnStartup  = [bool]$data.StartOnStartup
            UpdateSysProxy  = $(if ($null -eq $data.UpdateSysProxy) { $true } else { [bool]$data.UpdateSysProxy })
        } | ConvertTo-Json | Set-Content $script:Config.ConfigFile -Force
        try { (Get-Item $script:Config.ConfigFile -Force).Attributes = "Hidden" } catch {}
        Write-Log "Saved password cleared (auto-login rejected)" "WARN"
    } catch {
        Write-Log "Could not clear saved password: $($_.Exception.Message)" "WARN"
    }
}

function Set-StartupEntry {
    $target = if ($env:SCRIPT_SELF_PATH) { $env:SCRIPT_SELF_PATH } else { $MyInvocation.ScriptName }
    $value  = "`"cmd.exe`" /c `"`"$target`"`""
    Set-ItemProperty -Path $script:StartupRegPath -Name $script:StartupRegName -Value $value
    Write-Log "Startup entry added to registry" "SYSTEM"
}

function Remove-StartupEntry {
    Remove-ItemProperty -Path $script:StartupRegPath -Name $script:StartupRegName -ErrorAction SilentlyContinue
    Write-Log "Startup entry removed from registry" "SYSTEM"
}

function Test-StartupEntry {
    return (Get-ItemProperty -Path $script:StartupRegPath -Name $script:StartupRegName -ErrorAction SilentlyContinue) -ne $null
}

# ==========================================
# GRAPHICS & HEALTH CHECKS
# ==========================================
# Generates dynamic tray icons using GDI+ to avoid external asset dependencies.
# Rendered at 32x32 with high-quality AA so Windows can downscale crisply on
# both standard (16px) and high-DPI (24/32px) taskbars. A glyph is drawn inside
# the shape so status is readable at a glance, not just by colour.
function New-StatusIcon {
    param([System.Drawing.Color]$Color, [string]$Shape)
    $size = 32
    $bmp  = New-Object System.Drawing.Bitmap $size, $size
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    $brush = New-Object System.Drawing.SolidBrush $Color

    if ($Shape -eq "Circle") {
        # Filled circle + white check mark
        $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 4
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawLines($pen, [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point 8, 17),
            (New-Object System.Drawing.Point 14, 23),
            (New-Object System.Drawing.Point 24, 10)
        ))
        $pen.Dispose()
    } else {
        # Stop-sign octagon + white exclamation mark
        $o = 9
        $g.FillPolygon($brush, [System.Drawing.Point[]]@(
            (New-Object System.Drawing.Point $o,         0),
            (New-Object System.Drawing.Point ($size-$o), 0),
            (New-Object System.Drawing.Point ($size-1),  $o),
            (New-Object System.Drawing.Point ($size-1),  ($size-$o)),
            (New-Object System.Drawing.Point ($size-$o), ($size-1)),
            (New-Object System.Drawing.Point $o,         ($size-1)),
            (New-Object System.Drawing.Point 0,          ($size-$o)),
            (New-Object System.Drawing.Point 0,          $o)
        ))
        $whiteBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillRectangle($whiteBrush, 14, 7, 4, 13)
        $g.FillEllipse($whiteBrush, 13, 23, 6, 6)
        $whiteBrush.Dispose()
    }

    $brush.Dispose()
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Test-ProxyHealth {
    try {
        $r = Invoke-WebRequest -Uri "https://www.google.com" -TimeoutSec 5 -UseBasicParsing
        return $r.StatusCode -eq 200
    } catch { return $false }
}

function Update-TrayStatus {
    param([string]$Status, [string]$State="Neutral")
    if ($script:notifyIcon) {
        $script:notifyIcon.Text = "IITD Proxy: $Status`nLast Check: $(Get-Date -Format 'HH:mm:ss')"
        switch ($State) {
            "Good"    { $script:notifyIcon.Icon = $script:iconGood }
            "Bad"     { $script:notifyIcon.Icon = $script:iconBad }
            "Neutral" { $script:notifyIcon.Icon = $script:iconNeutral }
        }
    }
}

# ==========================================
# CORE PROXY LOGIC
# ==========================================
function Initialize-ProxyEnvironment {
    param($Category)
    $pNum = $script:ProxyMap[$Category]
    $baseUrl = "https://proxy$pNum.iitd.ac.in"
    $script:targetUrl = "$baseUrl/cgi-bin/proxy.cgi"
    $script:headers = @{ 
        "Referer"    = $script:targetUrl
        "Origin"     = $baseUrl
        "User-Agent" = $script:Config.UserAgent 
    }
    Write-Log "Target set to: Proxy$pNum ($Category)"
}

$script:OriginalAutoConfigURL    = $null
$script:OriginalAutoConfigURLSet = $false   # was the value present before we touched it?
$script:SnapshotTaken            = $false

function Save-OriginalSystemProxy {
    if ($script:SnapshotTaken) { return }
    $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $existing = Get-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue
    if ($existing -and $existing.AutoConfigURL) {
        $script:OriginalAutoConfigURL    = $existing.AutoConfigURL
        $script:OriginalAutoConfigURLSet = $true
    } else {
        $script:OriginalAutoConfigURLSet = $false
    }
    $script:SnapshotTaken = $true
}

function Initialize-SystemProxy {
    param($Category)
    try {
        Save-OriginalSystemProxy
        $pacUrl = "http://www.cc.iitd.ac.in/cgi-bin/proxy.$Category"
        $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regKey -Name AutoConfigURL -Value $pacUrl

        # Force Windows to refresh connection settings immediately
        $wininet::InternetSetOption([IntPtr]::Zero, $script:Constants.INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0)
        $wininet::InternetSetOption([IntPtr]::Zero, $script:Constants.INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0)
        Write-Log "Windows System Proxy updated to: $pacUrl" "SYSTEM"
    } catch {
        Write-Log "Failed to set Windows Proxy: $($_.Exception.Message)" "ERROR"
    }
}

function Restore-SystemProxy {
    if (-not $script:SnapshotTaken) { return }
    try {
        $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        if ($script:OriginalAutoConfigURLSet) {
            Set-ItemProperty -Path $regKey -Name AutoConfigURL -Value $script:OriginalAutoConfigURL
            Write-Log "Windows System Proxy restored to: $($script:OriginalAutoConfigURL)" "SYSTEM"
        } else {
            Remove-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue
            Write-Log "Windows System Proxy cleared (was not set before launch)" "SYSTEM"
        }
        $wininet::InternetSetOption([IntPtr]::Zero, $script:Constants.INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0)
        $wininet::InternetSetOption([IntPtr]::Zero, $script:Constants.INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0)
    } catch {
        Write-Log "Failed to restore Windows Proxy: $($_.Exception.Message)" "ERROR"
    }
}

function Connect-ProxySession {
    try {
        # 1. Get Session ID
        $p = Invoke-WebRequest -Uri $script:targetUrl -SessionVariable script:proxySession -Headers $script:headers -UseBasicParsing -TimeoutSec $script:Config.RequestTimeout
        
        if ($p.Content -match 'name="sessionid".*?value="([^"]+)"') { $script:sessionId = $matches[1] }
        elseif ($p.Content -match 'sessionid.*?value="([^"]+)"') { $script:sessionId = $matches[1] }
        else { Write-Log "Could not parse Session ID" "ERROR"; return $false }

        # 2. Post Credentials
        $formData = @{ "sessionid"=$script:sessionId; "action"="Validate"; "userid"=$script:creds.User; "pass"=$script:creds.Pass; "logon"="Log+on" }
        $res = Invoke-WebRequest -Uri $script:targetUrl -WebSession $script:proxySession -Method Post -Body $formData -ContentType "application/x-www-form-urlencoded" -Headers $script:headers -UseBasicParsing -TimeoutSec $script:Config.RequestTimeout

        if ($res.Content -like "*successful*" -or ($res.StatusCode -eq 200 -and $res.Content -notlike "*error*")) {
            Update-TrayStatus "Connected" "Good"
            return $true
        }
        
        # Improved Regex to catch multi-line errors and different ending tags
        if ($res.Content -match "<h1>Error</h1>([\s\S]*?)(?:<p>|</center>)") {
            # 1. Capture the text
            $rawError = $matches[1]
            # 2. Remove HTML tags (like <br>, <a>) so it looks clean in the popup
            $cleanError = $rawError -replace '<[^>]+>', ' '
            # 3. Collapse multiple spaces into one
            $cleanError = $cleanError.Trim() -replace '\s+', ' '
            
            Write-Log $cleanError "SERVER"
        } else { 
            Write-Log "Login failed (Unknown response)" "ERROR" 
        }
        return $false

    } catch { Write-Log $_.Exception.Message "ERROR"; return $false }
}

function Disconnect-ProxySession {
    if ($script:sessionId) {
        try {
            $data = @{ "sessionid"=$script:sessionId; "action"="logout" }
            Invoke-WebRequest -Uri $script:targetUrl -WebSession $script:proxySession -Method Post -Body $data -ContentType "application/x-www-form-urlencoded" -Headers $script:headers -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Logged out." "INFO"
        } catch { Write-Log "Logout warning: $($_.Exception.Message)" "WARN" }
    }
}

function Send-KeepAlive {
    try {
        $data = @{ "sessionid"=$script:sessionId; "action"="Refresh" }
        $res = Invoke-WebRequest -Uri $script:targetUrl -WebSession $script:proxySession -Method Post -Body $data -ContentType "application/x-www-form-urlencoded" -Headers $script:headers -UseBasicParsing -TimeoutSec $script:Config.RequestTimeout
        
        if ($res.Content -like "*successful*") {
            Write-Log "Keep-alive OK"
            if (Test-ProxyHealth) {
                 Update-TrayStatus "Active & Healthy" "Good"
            } else {
                 Write-Log "Keep-alive OK but Internet Check Failed" "WARN"
                 Update-TrayStatus "Active (No Internet)" "Bad"
            }
        } else {
            Write-Log "Session lost. Re-authenticating..." "WARN"
            Update-TrayStatus "Reconnecting..." "Bad"
            
            if (Connect-ProxySession) {
                Write-Log "Re-auth Successful" "SUCCESS"
            } else {
                Write-Log "Re-auth Failed" "ERROR"
                $script:notifyIcon.ShowBalloonTip(3000, "IITD Proxy", "Reconnection Failed!", [System.Windows.Forms.ToolTipIcon]::Error)
            }
        }
    } catch {
        Write-Log "Network Error: $($_.Exception.Message)" "ERROR"
        Update-TrayStatus "Network Error" "Bad"
    }
}

# ==========================================
# GUI & INTERACTION
# ==========================================
function Show-LoginDialog {
    param($SavedConfig)
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $segoe = New-Object System.Drawing.Font("Segoe UI", 9)

    $form = New-Object System.Windows.Forms.Form
    $form.Text                = "IITD Proxy Login"
    $form.Font                = $segoe
    $form.StartPosition       = "CenterScreen"
    $form.FormBorderStyle     = 'FixedSingle'
    $form.MaximizeBox         = $false
    $form.MinimizeBox         = $false
    $form.AutoSize            = $true
    $form.AutoSizeMode        = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.TopMost             = $true
    $form.Padding             = New-Object System.Windows.Forms.Padding(12)
    $form.Icon                = [System.Drawing.Icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")

    # Outer 1-column TableLayoutPanel: rows are added in document order
    $tlp = New-Object System.Windows.Forms.TableLayoutPanel
    $tlp.Dock         = 'Fill'
    $tlp.ColumnCount  = 1
    $tlp.AutoSize     = $true
    $tlp.AutoSizeMode = 'GrowAndShrink'
    [void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($tlp)

    $addPair = {
        param($labelText, $control)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText
        $lbl.AutoSize = $true
        $lbl.Margin = New-Object System.Windows.Forms.Padding(2, 6, 2, 0)
        [void]$tlp.Controls.Add($lbl)

        $control.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 6)
        $control.Width  = 280
        [void]$tlp.Controls.Add($control)
    }

    # Category
    $cbCategory = New-Object System.Windows.Forms.ComboBox
    $cbCategory.DropDownStyle = "DropDownList"
    $script:ProxyMap.Keys | Sort-Object | ForEach-Object { [void]$cbCategory.Items.Add($_) }
    if ($SavedConfig -and $script:ProxyMap.ContainsKey($SavedConfig.Category)) { $cbCategory.SelectedItem = $SavedConfig.Category }
    elseif ($cbCategory.Items.Count -gt 0) { $cbCategory.SelectedIndex = 0 }
    & $addPair "Category:" $cbCategory

    # Username
    $txtUser = New-Object System.Windows.Forms.TextBox
    if ($SavedConfig) { $txtUser.Text = $SavedConfig.Username }
    & $addPair "Username:" $txtUser

    # Password (system bullet glyph instead of plain '*')
    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.UseSystemPasswordChar = $true
    & $addPair "Password:" $txtPass

    # Options group
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text         = "Options"
    $grp.AutoSize     = $true
    $grp.AutoSizeMode = 'GrowAndShrink'
    $grp.Padding      = New-Object System.Windows.Forms.Padding(8, 4, 8, 8)
    $grp.Margin       = New-Object System.Windows.Forms.Padding(2, 8, 2, 8)
    $grp.Width        = 280   # match textbox width above so right edges align

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock          = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents  = $false
    $flow.AutoSize      = $true
    $flow.AutoSizeMode  = 'GrowAndShrink'
    $grp.Controls.Add($flow)

    $chkSave = New-Object System.Windows.Forms.CheckBox
    $chkSave.Text     = "Remember category and username"
    $chkSave.AutoSize = $true
    $chkSave.Checked  = ($null -ne $SavedConfig)
    $flow.Controls.Add($chkSave)

    $chkSystemProxy = New-Object System.Windows.Forms.CheckBox
    $chkSystemProxy.Text     = "Update Windows Proxy settings"
    $chkSystemProxy.AutoSize = $true
    $chkSystemProxy.Checked  = $(if ($SavedConfig) { $SavedConfig.UpdateSysProxy } else { $true })
    $flow.Controls.Add($chkSystemProxy)

    $chkAutoLogin = New-Object System.Windows.Forms.CheckBox
    $chkAutoLogin.Text     = "Auto-login on next launch"
    $chkAutoLogin.AutoSize = $true
    $chkAutoLogin.Checked  = ($SavedConfig -and $SavedConfig.AutoLogin)
    $flow.Controls.Add($chkAutoLogin)

    $chkStartup = New-Object System.Windows.Forms.CheckBox
    $chkStartup.Text     = "Start on Windows login"
    $chkStartup.AutoSize = $true
    $chkStartup.Checked  = (Test-StartupEntry)
    $flow.Controls.Add($chkStartup)

    [void]$tlp.Controls.Add($grp)

    # Tooltips on every input - explains the "what" and "why" without crowding the form
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000
    $tt.InitialDelay = 400
    $tt.ReshowDelay  = 200
    $tt.SetToolTip($cbCategory,    "Your IITD account category. Selects which proxy server is used.")
    $tt.SetToolTip($txtUser,       "Your IITD LDAP/Kerberos username (without @iitd.ac.in).")
    $tt.SetToolTip($txtPass,       "Your IITD password. Stored encrypted with Windows DPAPI only if you tick Auto-login.")
    $tt.SetToolTip($chkSave,       "Remember category and username (not the password) for next launch.")
    $tt.SetToolTip($chkSystemProxy,"Configure Windows so all browsers route through the IITD proxy. Restored when you choose Logout && Exit.")
    $tt.SetToolTip($chkAutoLogin,  "Save your password (encrypted per Windows user via DPAPI) and skip this dialog on future launches.")
    $tt.SetToolTip($chkStartup,    "Run this app automatically when you sign in to Windows.")

    # Bottom row: About link (left) | spacer | Login + Cancel (right)
    $btnRow = New-Object System.Windows.Forms.TableLayoutPanel
    $btnRow.ColumnCount  = 3
    $btnRow.RowCount     = 1
    $btnRow.Dock         = 'Fill'
    $btnRow.AutoSize     = $true
    $btnRow.AutoSizeMode = 'GrowAndShrink'
    $btnRow.Margin       = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    [void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.Text   = "&About"
    $btnAbout.Width  = 80
    $btnAbout.Height = 28
    $btnAbout.Margin = New-Object System.Windows.Forms.Padding(0)
    $btnAbout.add_Click({
        $abt = New-Object System.Windows.Forms.Form
        $abt.Text            = "About"
        $abt.Font            = $segoe
        $abt.ClientSize      = New-Object System.Drawing.Size(420, 150)
        $abt.StartPosition   = "CenterParent"
        $abt.FormBorderStyle = 'FixedToolWindow'
        $abt.TopMost         = $true
        $abt.MaximizeBox     = $false
        $abt.MinimizeBox     = $false

        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(20, 20)
        $txt.Size     = New-Object System.Drawing.Size(380, 40)
        $txt.Text     = "IITD Proxy Keep-Alive v3.1`r`nAuthor: Akhil"
        $abt.Controls.Add($txt)

        $lnk = New-Object System.Windows.Forms.LinkLabel
        $lnk.Location = New-Object System.Drawing.Point(20, 60)
        $lnk.Size     = New-Object System.Drawing.Size(380, 20)
        $lnk.Text     = "https://akhilabburu.github.io/iitd/proxy_persistent.html"
        $lnk.add_LinkClicked({ [System.Diagnostics.Process]::Start("https://akhilabburu.github.io/iitd/proxy_persistent.html") | Out-Null })
        $abt.Controls.Add($lnk)

        $btnAbtOk = New-Object System.Windows.Forms.Button
        $btnAbtOk.Text         = "OK"
        $btnAbtOk.DialogResult = "OK"
        $btnAbtOk.Location     = New-Object System.Drawing.Point(170, 100)
        $abt.Controls.Add($btnAbtOk)
        $abt.AcceptButton = $btnAbtOk

        $abt.ShowDialog($form) | Out-Null
    })
    [void]$btnRow.Controls.Add($btnAbout, 0, 0)

    # Spacer to push buttons to the right
    $spacer = New-Object System.Windows.Forms.Label
    $spacer.AutoSize = $false
    $spacer.Width    = 1
    [void]$btnRow.Controls.Add($spacer, 1, 0)

    $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnPanel.FlowDirection = 'LeftToRight'
    $btnPanel.AutoSize      = $true
    $btnPanel.AutoSizeMode  = 'GrowAndShrink'
    $btnPanel.Margin        = New-Object System.Windows.Forms.Padding(0)

    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text   = "&Login"
    $btnLogin.Width  = 80
    $btnLogin.Height = 28
    $btnPanel.Controls.Add($btnLogin)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = "&Cancel"
    $btnCancel.Width        = 80
    $btnCancel.Height       = 28
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Margin       = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $btnPanel.Controls.Add($btnCancel)

    [void]$btnRow.Controls.Add($btnPanel, 2, 0)
    [void]$tlp.Controls.Add($btnRow)

    $form.AcceptButton = $btnLogin
    $form.CancelButton = $btnCancel

    $script:guiResult = $null
    $btnLogin.Add_Click({
        if ($txtUser.Text -and $txtPass.Text -and $cbCategory.SelectedItem) {
            $script:guiResult = @{
                User           = $txtUser.Text.Trim()
                Pass           = $txtPass.Text
                Cat            = $cbCategory.SelectedItem
                UpdateSys      = $chkSystemProxy.Checked
                AutoLogin      = $chkAutoLogin.Checked
                StartOnStartup = $chkStartup.Checked
            }

            if ($chkSave.Checked -or $chkAutoLogin.Checked) {
                Export-ProxyConfig `
                    -User           $script:guiResult.User `
                    -Pass           $(if ($chkAutoLogin.Checked) { $script:guiResult.Pass } else { $null }) `
                    -Category       $script:guiResult.Cat `
                    -AutoLogin      $chkAutoLogin.Checked `
                    -StartOnStartup $chkStartup.Checked `
                    -UpdateSys      $chkSystemProxy.Checked
            } else {
                if (Test-Path $script:Config.ConfigFile) { Remove-Item $script:Config.ConfigFile -Force -ErrorAction SilentlyContinue }
            }

            if ($chkStartup.Checked) { Set-StartupEntry } else { Remove-StartupEntry }

            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("All fields required.", "IITD Proxy Login", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })

    $form.Add_Shown({ $form.Activate(); if ($txtUser.Text) { $txtPass.Select() } })
    $form.ShowDialog() | Out-Null
    return $script:guiResult
}

function Show-LogViewer {
    if ($script:logForm -and -not $script:logForm.IsDisposed) {
        $script:logForm.Visible = $true
        $script:logForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:logForm.Activate()
        return
    }

    $script:logForm = New-Object System.Windows.Forms.Form
    $script:logForm.Text          = "Proxy Activity Log"
    $script:logForm.Size          = New-Object System.Drawing.Size(640, 420)
    $script:logForm.MinimumSize   = New-Object System.Drawing.Size(420, 260)
    $script:logForm.StartPosition = "CenterScreen"
    $script:logForm.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:logForm.Icon          = [System.Drawing.Icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")

    $script:txtLogBox = New-Object System.Windows.Forms.RichTextBox
    $script:txtLogBox.ReadOnly      = $true
    $script:txtLogBox.Dock          = "Fill"
    $script:txtLogBox.BorderStyle   = [System.Windows.Forms.BorderStyle]::None
    $script:txtLogBox.Font          = New-Object System.Drawing.Font("Consolas", 9)
    $script:txtLogBox.BackColor     = [System.Drawing.Color]::White
    $script:txtLogBox.WordWrap      = $false
    $script:txtLogBox.DetectUrls    = $false
    $script:txtLogBox.HideSelection = $false

    # Replay history with colour. Each line is "[HH:MM:SS] [TYPE] message".
    $rtb = $script:txtLogBox
    $tagRegex = [regex]'^\[\d{2}:\d{2}:\d{2}\] \[([A-Z]+)\] '
    foreach ($line in ($global:logHistory.ToString() -split "`r?`n")) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $m = $tagRegex.Match($line)
        $type = if ($m.Success) { $m.Groups[1].Value } else { "INFO" }
        Append-LogLine $rtb $line $type
    }

    $script:logForm.Controls.Add($script:txtLogBox)
    $script:logForm.Show()
}

# ==========================================
# ENTRY POINT HELPERS
# ==========================================
function Invoke-LoginFlow {
    # Uses $script:creds (set by caller). Returns $true on success.
    if ($script:creds.UpdateSys) {
        Initialize-SystemProxy -Category $script:creds.Cat
    } else {
        Write-Log "Skipping Windows Proxy Update (User Opt-out)" "INFO"
    }
    Initialize-ProxyEnvironment -Category $script:creds.Cat
    return (Connect-ProxySession)
}

function Show-LoginErrorAndExit {
    $lastLog = $global:logHistory.ToString().Trim()
    $lastLines = $lastLog -split "`r`n"
    $errorReason = $(if ($lastLines) { $lastLines[-1] } else { "Unknown Error" })
    [System.Windows.Forms.MessageBox]::Show("Login Failed.`n$errorReason", "Error")
    exit
}

# ==========================================
# ENTRY POINT
# ==========================================
# Initialize Icons
$script:iconGood = New-StatusIcon -Color ([System.Drawing.Color]::LimeGreen) -Shape "Circle"
$script:iconBad  = New-StatusIcon -Color ([System.Drawing.Color]::Red)       -Shape "Octagon"

# Snapshot Windows proxy state up front so Restore-SystemProxy can put it back on exit
Save-OriginalSystemProxy

# Load saved config
$saved = Import-ProxyConfig

# Auto-login path: skip GUI entirely if creds are fully saved
$didAutoLogin = $false
if ($saved -and $saved.AutoLogin -and $saved.Password -and $saved.Username -and $saved.Category) {
    Write-Log "Auto-login: using saved credentials for $($saved.Username)" "INFO"
    $script:creds = @{
        User      = $saved.Username
        Pass      = $saved.Password
        Cat       = $saved.Category
        UpdateSys = $saved.UpdateSysProxy
    }
    $didAutoLogin = $true
} else {
    $script:creds = Show-LoginDialog -SavedConfig $saved
}

if (-not $script:creds) { exit }

$loginOk = Invoke-LoginFlow

# Auto-login failed -> assume saved password is stale; clear it and fall back to manual login
if (-not $loginOk -and $didAutoLogin) {
    Write-Log "Auto-login failed, falling back to manual login" "WARN"
    Clear-SavedPassword
    $saved = Import-ProxyConfig
    $script:creds = Show-LoginDialog -SavedConfig $saved
    if (-not $script:creds) { exit }
    $didAutoLogin = $false  # don't tag the success log line as [auto]
    $loginOk = Invoke-LoginFlow
}

if (-not $loginOk) { Show-LoginErrorAndExit }

Write-Log "Login Successful as $($script:creds.User)$(if($didAutoLogin){' [auto]'})" "SUCCESS"

# ==========================================
# TRAY ICON + MENU
# ==========================================
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Visible = $true
Update-TrayStatus "Connected" "Good"
$script:notifyIcon.ShowBalloonTip(5000, "IITD Proxy", "Proxy Login Successful.`nSystem Tray Active. Right-click for menu.", [System.Windows.Forms.ToolTipIcon]::Info)
$script:notifyIcon.add_DoubleClick({ Show-LogViewer })

# Modern themed context menu (replaces deprecated ContextMenu)
$cms = New-Object System.Windows.Forms.ContextMenuStrip
$cms.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Disabled header item: at-a-glance "you are here" indicator
$miHeader = New-Object System.Windows.Forms.ToolStripMenuItem
$miHeader.Text = "$($script:creds.User)  ($($script:creds.Cat))"
$miHeader.Enabled = $false
$miHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
[void]$cms.Items.Add($miHeader)
[void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miReconnect = New-Object System.Windows.Forms.ToolStripMenuItem
$miReconnect.Text = "&Reconnect Now"
$miReconnect.add_Click({
    Write-Log "Manual reconnect requested" "INFO"
    Update-TrayStatus "Reconnecting..." "Bad"
    if (Connect-ProxySession) {
        Write-Log "Manual reconnect successful" "SUCCESS"
        Update-TrayStatus "Connected" "Good"
    } else {
        Write-Log "Manual reconnect failed" "ERROR"
    }
})
[void]$cms.Items.Add($miReconnect)

$miLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miLog.Text = "&View Logs"
$miLog.add_Click({ Show-LogViewer })
[void]$cms.Items.Add($miLog)

[void]$cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = "&Logout && Exit"   # `&&` renders as a literal '&'
$miExit.add_Click({
    Disconnect-ProxySession
    Restore-SystemProxy
    if ($script:netHandler) {
        try { [System.Net.NetworkInformation.NetworkChange]::remove_NetworkAvailabilityChanged($script:netHandler) } catch {}
    }
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose() }
    if ($script:invisibleHost -and -not $script:invisibleHost.IsDisposed) { $script:invisibleHost.Dispose() }
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch {}; $script:mutex.Dispose() }
    [System.Windows.Forms.Application]::Exit()
})
[void]$cms.Items.Add($miExit)

$script:notifyIcon.ContextMenuStrip = $cms

# ==========================================
# CROSS-THREAD MARSHALING + NETWORK CHANGE
# ==========================================
# Invisible host form gives us a UI-thread BeginInvoke target for events
# raised on background threads (e.g. NetworkChange).
$script:invisibleHost = New-Object System.Windows.Forms.Form
$script:invisibleHost.ShowInTaskbar  = $false
$script:invisibleHost.WindowState    = [System.Windows.Forms.FormWindowState]::Minimized
$script:invisibleHost.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:invisibleHost.Opacity        = 0
$null = $script:invisibleHost.Handle  # force handle creation on the UI thread

# Network availability change -> trigger an immediate keep-alive instead of
# waiting up to 2 minutes for the next timer tick. Common after Wi-Fi reconnect
# or wake-from-sleep.
$script:netHandler = [System.Net.NetworkInformation.NetworkAvailabilityChangedEventHandler]{
    param($eventSender, $e)
    if ($e.IsAvailable -and $script:invisibleHost -and -not $script:invisibleHost.IsDisposed) {
        try {
            $script:invisibleHost.BeginInvoke([Action]{
                Write-Log "Network reconnected - running keep-alive" "INFO"
                Send-KeepAlive
            }) | Out-Null
        } catch {}
    }
}
[System.Net.NetworkInformation.NetworkChange]::add_NetworkAvailabilityChanged($script:netHandler)

# ==========================================
# KEEP-ALIVE TIMER + MESSAGE LOOP
# ==========================================
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:Config.KeepAliveInterval * 1000
$script:timer.Add_Tick({ Send-KeepAlive })
$script:timer.Start()

[System.Windows.Forms.Application]::Run()
