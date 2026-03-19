<# : batch portion
@echo off
:: ===========================================================================
::   IITD Proxy Keep-Alive Utility
:: ===========================================================================
::   Author:       Akhil A
::   Version:      2.8
::   Date:         2025-12-10
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
title IITD Proxy Keep-Alive
cd /d %~dp0
:: Load the PowerShell portion below using Invoke-Expression
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock { iex ((Get-Content '%~f0') -join [Environment]::NewLine) } | Out-Null"
exit /b
: end batch / begin powershell #>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
function Write-Log {
    param($Msg, $Type="INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] [$Type] $Msg"
    
    # Simple circular buffer logic to prevent memory bloat
    if ($global:logHistory.Length -gt 50000) {
        $global:logHistory.Remove(0, 10000) | Out-Null
    }

    $global:logHistory.AppendLine($line) | Out-Null
    
    # Thread-safe UI update
    if ($script:txtLogBox -and -not $script:txtLogBox.IsDisposed) {
        if ($script:txtLogBox.InvokeRequired) {
            $script:txtLogBox.Invoke([Action]{ $script:txtLogBox.AppendText($line + "`r`n") })
        } else {
            $script:txtLogBox.AppendText($line + "`r`n")
        }
    }
}

function Import-ProxyConfig {
    if (Test-Path $script:Config.ConfigFile) { 
        try { Get-Content $script:Config.ConfigFile -Force -Raw | ConvertFrom-Json } catch { $null } 
    }
}

function Export-ProxyConfig {
    param($User, $Category)
    @{ Username=$User; Category=$Category } | ConvertTo-Json | Set-Content $script:Config.ConfigFile -Force
    # Hide the config file so users don't accidentally delete it
    try { (Get-Item $script:Config.ConfigFile -Force).Attributes = "Hidden" } catch {}
}

# ==========================================
# GRAPHICS & HEALTH CHECKS
# ==========================================
# Generates dynamic tray icons using GDI+ to avoid external asset dependencies
function Create-StatusIcon {
    param([System.Drawing.Color]$Color, [string]$Shape)
    $size = 16
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    $brush = New-Object System.Drawing.SolidBrush $Color
    
    if ($Shape -eq "Circle") {
        $g.FillEllipse($brush, 1, 1, $size-2, $size-2)
    } else {
        # Draw Octagon manually
        $p = @(
            (New-Object System.Drawing.Point 5,0), (New-Object System.Drawing.Point 10,0),
            (New-Object System.Drawing.Point 15,5), (New-Object System.Drawing.Point 15,10),
            (New-Object System.Drawing.Point 10,15), (New-Object System.Drawing.Point 5,15),
            (New-Object System.Drawing.Point 0,10), (New-Object System.Drawing.Point 0,5)
        )
        $g.FillPolygon($brush, $p)
    }
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

function Initialize-SystemProxy {
    param($Category)
    try {
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
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "IITD Proxy Login"
    $form.Size = New-Object System.Drawing.Size(320, 350)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.TopMost = $true 

    # Version/About Label
    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text = "?"
    $lblVer.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
    $lblVer.ForeColor = [System.Drawing.Color]::Gray
    $lblVer.Cursor = [System.Windows.Forms.Cursors]::Hand
    $lblVer.Location = "290, 5"
    $lblVer.Size = "20, 20"
    
    # CLICKABLE ABOUT BOX WITH LINK
    $lblVer.Add_Click({ 
        $abt = New-Object System.Windows.Forms.Form
        $abt.Text = "About"
        $abt.Size = New-Object System.Drawing.Size(420, 180)
        $abt.StartPosition = "CenterScreen"
        $abt.FormBorderStyle = 'FixedToolWindow'
        $abt.TopMost = $true # Ensures it sits ON TOP of the Login Window

        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = "20, 20"
        $txt.Size = "360, 40"
        $txt.Text = "IITD Proxy Keep-Alive v2.8`nAuthor: Akhil"
        $abt.Controls.Add($txt)

        $lnk = New-Object System.Windows.Forms.LinkLabel
        $lnk.Location = "20, 60"
        $lnk.Size = "360, 20"
        $lnk.Text = "https://akhilabburu.github.io/iitd/proxy_persistent.html"
        $lnk.LinkColor = [System.Drawing.Color]::Blue
        $lnk.Add_Click({ [System.Diagnostics.Process]::Start("https://akhilabburu.github.io/iitd/proxy_persistent.html") })
        $abt.Controls.Add($lnk)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Location = "160, 100"
        $btn.Text = "OK"
        $btn.DialogResult = "OK"
        $abt.Controls.Add($btn)
        $abt.AcceptButton = $btn

        $abt.ShowDialog()
    })
    $form.Controls.Add($lblVer)

    # Input Fields
    $lblCat = New-Object System.Windows.Forms.Label; $lblCat.Location = "10, 15"; $lblCat.Size = "280, 20"; $lblCat.Text = "Category:"; $form.Controls.Add($lblCat)
    
    $cbCategory = New-Object System.Windows.Forms.ComboBox; $cbCategory.Location = "10, 35"; $cbCategory.Size = "280, 21"; $cbCategory.DropDownStyle = "DropDownList"
    $script:ProxyMap.Keys | Sort-Object | ForEach-Object { [void]$cbCategory.Items.Add($_) }
    if ($SavedConfig -and $script:ProxyMap.ContainsKey($SavedConfig.Category)) { $cbCategory.SelectedItem = $SavedConfig.Category }
    elseif ($cbCategory.Items.Count -gt 0) { $cbCategory.SelectedIndex = 0 }
    $form.Controls.Add($cbCategory)

    $lblUser = New-Object System.Windows.Forms.Label; $lblUser.Location = "10, 70"; $lblUser.Size = "280, 20"; $lblUser.Text = "Username:"; $form.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox; $txtUser.Location = "10, 90"; $txtUser.Size = "280, 20"; if ($SavedConfig) { $txtUser.Text = $SavedConfig.Username }; $form.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label; $lblPass.Location = "10, 125"; $lblPass.Size = "280, 20"; $lblPass.Text = "Password:"; $form.Controls.Add($lblPass)
    $txtPass = New-Object System.Windows.Forms.TextBox; $txtPass.Location = "10, 145"; $txtPass.Size = "280, 20"; $txtPass.PasswordChar = '*'; $form.Controls.Add($txtPass)

    # Options
    $chkSave = New-Object System.Windows.Forms.CheckBox; $chkSave.Location = "10, 175"; $chkSave.Size = "290, 20"; $chkSave.Text = "Remember my Category and Username"; 
    $chkSave.Checked = ($SavedConfig -ne $null); # Auto-check if config existed
    $form.Controls.Add($chkSave)

    $chkSystemProxy = New-Object System.Windows.Forms.CheckBox; $chkSystemProxy.Location = "10, 200"; $chkSystemProxy.Size = "290, 20"; $chkSystemProxy.Text = "Update Windows Proxy Settings"; $chkSystemProxy.Checked = $true; $form.Controls.Add($chkSystemProxy)

    # Buttons
    $btnLogin = New-Object System.Windows.Forms.Button; $btnLogin.Location = "110, 235"; $btnLogin.Size = "80, 30"; $btnLogin.Text = "Login"
    $form.Controls.Add($btnLogin)
    
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Location = "200, 235"; $btnCancel.Size = "80, 30"; $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnLogin
    $form.CancelButton = $btnCancel

    $script:guiResult = $null
    $btnLogin.Add_Click({
        if ($txtUser.Text -and $txtPass.Text -and $cbCategory.SelectedItem) {
            $script:guiResult = @{ User=$txtUser.Text.Trim(); Pass=$txtPass.Text; Cat=$cbCategory.SelectedItem; UpdateSys=$chkSystemProxy.Checked }
            
            # Handle config persistence based on user choice
            if ($chkSave.Checked) {
                Export-ProxyConfig -User $script:guiResult.User -Category $script:guiResult.Cat
            } else {
                if (Test-Path $script:Config.ConfigFile) { Remove-Item $script:Config.ConfigFile -Force -ErrorAction SilentlyContinue }
            }

            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else { [System.Windows.Forms.MessageBox]::Show("All fields required.") }
    })
    
    $form.Add_Shown({ $form.Activate(); if($txtUser.Text){$txtPass.Select()} })
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
    $script:logForm.Text = "Proxy Activity Log"
    $script:logForm.Size = New-Object System.Drawing.Size(600, 400)
    $script:logForm.StartPosition = "CenterScreen"
    $script:logForm.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")

    $script:txtLogBox = New-Object System.Windows.Forms.TextBox
    $script:txtLogBox.Multiline = $true
    $script:txtLogBox.ScrollBars = "Vertical"
    $script:txtLogBox.ReadOnly = $true
    $script:txtLogBox.Dock = "Fill"
    $script:txtLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:txtLogBox.Text = $global:logHistory.ToString()
    
    $script:txtLogBox.SelectionStart = $script:txtLogBox.Text.Length
    $script:txtLogBox.ScrollToCaret()

    $script:logForm.Controls.Add($script:txtLogBox)
    $script:logForm.Show()
}

# ==========================================
# ENTRY POINT
# ==========================================
# Initialize Icons
$script:iconGood = Create-StatusIcon -Color ([System.Drawing.Color]::LimeGreen) -Shape "Circle"
$script:iconBad  = Create-StatusIcon -Color ([System.Drawing.Color]::Red) -Shape "Octagon"

# Load Config & Show GUI
$saved = Import-ProxyConfig
$script:creds = Show-LoginDialog -SavedConfig $saved

if (-not $script:creds) { exit }

if ($script:creds.UpdateSys) {
    Initialize-SystemProxy -Category $script:creds.Cat
} else {
    Write-Log "Skipping Windows Proxy Update (User Opt-out)" "INFO"
}

Initialize-ProxyEnvironment -Category $script:creds.Cat

if (Connect-ProxySession) {
    Write-Log "Initial Login Successful as $($script:creds.User)" "SUCCESS"
} else {
    $lastLog = $global:logHistory.ToString().Trim()
    $lastLines = $lastLog -split "`r`n"
    $errorReason = if ($lastLines) { $lastLines[-1] } else { "Unknown Error" }
    [System.Windows.Forms.MessageBox]::Show("Login Failed.`n$errorReason", "Error")
    exit
}

# Setup Tray Icon
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Visible = $true
Update-TrayStatus "Connected" "Good"
$script:notifyIcon.ShowBalloonTip(5000, "IITD Proxy", "Proxy Login Successful.`nSystem Tray Active. Right-click to Logout & Exit.", [System.Windows.Forms.ToolTipIcon]::Info)

$script:notifyIcon.add_DoubleClick({ Show-LogViewer })

$contextMenu = New-Object System.Windows.Forms.ContextMenu
$menuItemLog = $contextMenu.MenuItems.Add("View Logs")
$menuItemLog.add_Click({ Show-LogViewer })

$contextMenu.MenuItems.Add("-")

$menuItemExit = $contextMenu.MenuItems.Add("Logout & Exit")
$menuItemExit.add_Click({ 
    Disconnect-ProxySession
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose() }
    [System.Windows.Forms.Application]::Exit() 
})
$script:notifyIcon.ContextMenu = $contextMenu

# Start Keep-Alive Loop
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:Config.KeepAliveInterval * 1000
$script:timer.Add_Tick({ Send-KeepAlive })
$script:timer.Start()

[System.Windows.Forms.Application]::Run()
