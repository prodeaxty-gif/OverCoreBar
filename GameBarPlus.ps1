<#
.SYNOPSIS
    GameBarPlus - une Game Bar améliorée : overlay en jeu, enregistrement FFmpeg, captures, stats.

.DESCRIPTION
    Lance-le une fois : il se cache et vit dans la zone de notification (près de l'horloge).
    - Ctrl+Alt+G : ouvrir / fermer la barre (overlay)
    - Ctrl+Alt+R : démarrer / arrêter l'enregistrement
    - Ctrl+Alt+S : capture d'écran
    - Ctrl+Alt+Q : quitter
    Clic droit sur l'icône : menu (réglages, démarrage avec Windows, quitter...).
    Clips rangés par jeu : Vidéos\GameBarPlus\<Jeu>\<Jeu>_date_heure.mp4

.PARAMETER Console
    Reste dans la console au lieu de se cacher (pratique pour déboguer).

.PARAMETER Background
    Usage interne (relance cachée / démarrage automatique).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GameBarPlus.ps1
#>
[CmdletBinding()]
param([switch]$Background, [switch]$Console)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

# ---------------------------------------------------------------------------
# Code natif (C#) : raccourcis globaux, overlay sans prise de focus, processus FFmpeg
# ---------------------------------------------------------------------------
if (-not ('HotkeyWindow' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// Fenêtre invisible qui reçoit les raccourcis clavier globaux
public class HotkeyWindow : NativeWindow, IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private List<int> ids = new List<int>();
    public event Action<int> HotkeyPressed;

    public HotkeyWindow()
    {
        CreateParams cp = new CreateParams();
        cp.Parent = new IntPtr(-3); // HWND_MESSAGE
        CreateHandle(cp);
    }

    public bool Register(int id, uint mods, uint vk)
    {
        bool ok = RegisterHotKey(Handle, id, mods | 0x4000, vk); // MOD_NOREPEAT
        if (ok) ids.Add(id);
        return ok;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) // WM_HOTKEY
        {
            Action<int> h = HotkeyPressed;
            if (h != null) h((int)m.WParam);
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (int id in ids) UnregisterHotKey(Handle, id);
        ids.Clear();
        DestroyHandle();
    }
}

public static class WinInfo
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public static int ForegroundPid()
    {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return (int)pid;
    }
}

// Overlay : ne vole pas le focus au jeu, absent d'Alt+Tab, coins arrondis,
// et exclu des captures d'écran / enregistrements.
public class OverlayForm : Form
{
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; // NOACTIVATE | TOOLWINDOW | TOPMOST
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        try { SetWindowDisplayAffinity(Handle, 0x11); } catch { } // WDA_EXCLUDEFROMCAPTURE
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        this.Region = System.Drawing.Region.FromHrgn(CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 18, 18));
    }
}

// Lance FFmpeg en gardant ses messages d'erreur (utile quand tout est caché)
public class FfProc
{
    public Process P;
    private StringBuilder err = new StringBuilder();
    public string Errors { get { lock (err) { return err.ToString(); } } }

    public static FfProc Start(string file, string args)
    {
        FfProc f = new FfProc();
        ProcessStartInfo psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        f.P = Process.Start(psi);
        f.P.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
        {
            if (e.Data != null) lock (f.err) { if (f.err.Length < 20000) f.err.AppendLine(e.Data); }
        };
        f.P.BeginErrorReadLine();
        return f;
    }
}
'@
}

# ---------------------------------------------------------------------------
# Chemins, log, config
# ---------------------------------------------------------------------------
$AppDir     = Join-Path $env:APPDATA 'GameBarPlus'
$ConfigPath = Join-Path $AppDir 'config.json'
$LogPath    = Join-Path $AppDir 'log.txt'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) { Remove-Item $LogPath -Force }

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $msg) } catch { }
}

function Get-Config {
    $cfg = [ordered]@{
        OutputDir        = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'GameBarPlus'
        Fps              = 60
        BitrateMbps      = 20
        AudioDevices     = @()
        HotkeyBar        = 'Ctrl+Alt+G'
        HotkeyRecord     = 'Ctrl+Alt+R'
        HotkeyScreenshot = 'Ctrl+Alt+S'
        HotkeyQuit       = 'Ctrl+Alt+Q'
        Sound            = $true
    }
    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k }
            }
        } catch { Write-Log "config.json illisible, valeurs par défaut utilisées." }
    }
    $cfg.AudioDevices = @($cfg.AudioDevices)
    $cfg
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# FFmpeg : détection / installation
# ---------------------------------------------------------------------------
function Update-PathFromRegistry {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u;$env:Path"
}

function Find-FFmpeg {
    Update-PathFromRegistry
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $AppDir 'bin\ffmpeg.exe'
    if (Test-Path $local) { return $local }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'
    if (Test-Path $link) { return $link }
    $null
}

function Get-FFmpeg([switch]$NoPrompt) {
    $found = Find-FFmpeg
    if ($found) { return $found }
    if ($NoPrompt) { throw 'FFmpeg introuvable.' }

    Write-Host 'FFmpeg est introuvable.' -ForegroundColor Yellow
    $answer = Read-Host "L'installer automatiquement ? (O/n)"
    if ($answer -match '^[nN]') { throw 'FFmpeg est requis pour fonctionner.' }

    # 1) winget (affiche sa progression)
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host 'Installation via winget...' -ForegroundColor Cyan
        try { winget install Gyan.FFmpeg --accept-source-agreements --accept-package-agreements } catch { }
        $found = Find-FFmpeg
        if ($found) { return $found }
    }

    # 2) téléchargement direct
    Write-Host 'Téléchargement direct de FFmpeg (~90 Mo, ça peut prendre quelques minutes, pas de barre de progression)...' -ForegroundColor Cyan
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'ffmpeg_gbp.zip'
    $tmp = Join-Path $env:TEMP 'ffmpeg_gbp'
    Invoke-WebRequest 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $exe   = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    $local = Join-Path $AppDir 'bin\ffmpeg.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $local) | Out-Null
    Copy-Item $exe.FullName $local -Force
    Remove-Item $zip, $tmp -Recurse -Force
    $local
}

function ConvertTo-ArgString([string[]]$list) {
    ($list | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

function Test-FFmpegArgs([string[]]$ffArgs) {
    $p = Start-Process -FilePath $script:FFmpeg -ArgumentList (ConvertTo-ArgString $ffArgs) -Wait -PassThru -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}

# Meilleur encodeur qui fonctionne VRAIMENT sur cette machine
function Get-Encoder {
    foreach ($e in 'h264_nvenc', 'h264_amf', 'h264_qsv') {
        $ok = Test-FFmpegArgs @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'color=size=1280x720:rate=30:duration=0.3', '-c:v', $e, '-pix_fmt', 'yuv420p', '-f', 'null', '-')
        if ($ok) { return $e }
    }
    'libx264'
}

# ddagrab (Desktop Duplication, rapide) si dispo, sinon gdigrab
function Get-CaptureMethod {
    $ok = Test-FFmpegArgs @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
        '-i', 'ddagrab=framerate=30', '-frames:v', '2', '-vf', 'hwdownload,format=bgra', '-f', 'null', '-')
    if ($ok) { 'ddagrab' } else { 'gdigrab' }
}

function Get-AudioDevices {
    $raw = cmd /c "`"$script:FFmpeg`" -hide_banner -list_devices true -f dshow -i dummy 2>&1"
    $names = foreach ($line in $raw) {
        if ($line -match '"([^"]+)"\s+\(audio\)') { $Matches[1] }
    }
    @($names | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
function Rgb([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }

function Get-ForegroundGame {
    try {
        $procId = [WinInfo]::ForegroundPid()
        $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
    } catch { return 'Desktop' }

    $ignore = 'explorer', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost', 'cmd',
              'ApplicationFrameHost', 'SearchHost', 'ShellExperienceHost'
    if ($ignore -contains $name) { return 'Desktop' }
    $name -replace '[^\w\.\- ]', '_'
}

function Get-OutputBase {
    $game  = Get-ForegroundGame
    $dir   = Join-Path $script:Cfg.OutputDir $game
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    Join-Path $dir "${game}_$stamp"
}

function Invoke-Beep([int]$freq, [int]$ms) {
    if ($script:Cfg.Sound) { try { [Console]::Beep($freq, $ms) } catch { } }
}

function Show-Notice([string]$title, [string]$text, [string]$kind = 'Info') {
    Write-Host "$title - $text"
    try { $script:Tray.ShowBalloonTip(3000, $title, $text, [System.Windows.Forms.ToolTipIcon]$kind) } catch { }
}

function ConvertTo-Hotkey([string]$text) {
    $mods = 0; $key = 0
    foreach ($part in ($text -split '\+')) {
        switch ($part.Trim().ToLower()) {
            'ctrl'  { $mods = $mods -bor 2 }
            'alt'   { $mods = $mods -bor 1 }
            'shift' { $mods = $mods -bor 4 }
            'win'   { $mods = $mods -bor 8 }
            default { $key = [int][Enum]::Parse([System.Windows.Forms.Keys], $part.Trim(), $true) }
        }
    }
    [pscustomobject]@{ Mods = [uint32]$mods; Key = [uint32]$key }
}

function Open-ClipFolder {
    New-Item -ItemType Directory -Force -Path $script:Cfg.OutputDir | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $script:Cfg.OutputDir + '"')
}

# ---------------------------------------------------------------------------
# Démarrage automatique avec Windows (un petit .vbs = aucune fenêtre qui clignote)
# ---------------------------------------------------------------------------
function Get-StartupFile { Join-Path ([Environment]::GetFolderPath('Startup')) 'GameBarPlus.vbs' }

function Set-AutoStart([bool]$on) {
    $vbs = Get-StartupFile
    if ($on) {
        $dest = Join-Path $AppDir 'GameBarPlus.ps1'
        if ($PSCommandPath -ne $dest) { Copy-Item $PSCommandPath $dest -Force }
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ""{0}"" -Background' -f $dest
        Set-Content -Path $vbs -Value ('CreateObject("WScript.Shell").Run "' + $cmd + '", 0, False') -Encoding Unicode
    } else {
        Remove-Item $vbs -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Enregistrement
# ---------------------------------------------------------------------------
$script:Rec = $null

function Start-Recording {
    $base = Get-OutputBase
    $mkv  = "$base.mkv"
    $mp4  = "$base.mp4"
    $fps  = [int]$script:Cfg.Fps
    $br   = [int]$script:Cfg.BitrateMbps

    $a = @('-y', '-hide_banner', '-loglevel', 'error', '-nostats')

    if ($script:Capture -eq 'ddagrab') {
        $a += @('-f', 'lavfi', '-i', "ddagrab=output_idx=0:framerate=${fps}:draw_mouse=1")
    } else {
        $a += @('-f', 'gdigrab', '-framerate', "$fps", '-draw_mouse', '1', '-i', 'desktop')
    }

    $i = 0
    foreach ($dev in $script:Cfg.AudioDevices) {
        $a += @('-thread_queue_size', '1024', '-f', 'dshow', '-i', "audio=$dev")
        $i++
    }

    $a += @('-map', '0:v')
    for ($n = 1; $n -le $i; $n++) { $a += @('-map', "${n}:a") }

    if ($script:Capture -eq 'ddagrab') { $a += @('-vf', 'hwdownload,format=bgra') }

    $a += @('-c:v', $script:Encoder)
    switch ($script:Encoder) {
        'h264_nvenc' { $a += @('-preset', 'p4') }
        'h264_amf'   { $a += @('-quality', 'speed') }
        'h264_qsv'   { $a += @('-preset', 'medium') }
        default      { $a += @('-preset', 'veryfast') }
    }
    $a += @('-b:v', "${br}M", '-maxrate', "$([int]($br * 1.5))M", '-bufsize', "$($br * 2)M",
            '-pix_fmt', 'yuv420p', '-g', "$($fps * 2)")

    if ($i -gt 0) { $a += @('-c:a', 'aac', '-b:a', '192k') }
    $a += $mkv

    $ff = [FfProc]::Start($script:FFmpeg, (ConvertTo-ArgString $a))
    $script:Rec = @{ Ff = $ff; Mkv = $mkv; Mp4 = $mp4; Started = Get-Date }
    Invoke-Beep 880 120
    Update-Ui
}

function Stop-Recording {
    $r = $script:Rec
    if (-not $r) { return }
    $script:Rec = $null
    $p = $r.Ff.P
    $crashed = $p.HasExited

    if (-not $crashed) {
        try { $p.StandardInput.Write('q'); $p.StandardInput.Flush() } catch { }
        if (-not $p.WaitForExit(10000)) { $p.Kill(); $p.WaitForExit() }
    }
    Invoke-Beep 520 120

    if ($crashed) {
        $errText = $r.Ff.Errors.Trim()
        Write-Log "FFmpeg s'est arrêté tout seul (code $($p.ExitCode)) : $errText"
        $last = ($errText -split "`n" | Select-Object -Last 1)
        Show-Notice 'Enregistrement interrompu' "FFmpeg s'est arrêté. $last" 'Error'
    }

    if (Test-Path $r.Mkv) {
        if ((Get-Item $r.Mkv).Length -gt 0) {
            $ok = Test-FFmpegArgs @('-y', '-hide_banner', '-loglevel', 'error', '-i', $r.Mkv,
                                    '-c', 'copy', '-movflags', '+faststart', $r.Mp4)
            if ($ok) {
                Remove-Item $r.Mkv -Force
                $dur = (Get-Date) - $r.Started
                Show-Notice 'Clip enregistré' ("{0}  ({1:mm\:ss})" -f (Split-Path $r.Mp4 -Leaf), $dur)
            } else {
                Show-Notice 'Conversion MP4 échouée' "Clip gardé en MKV : $($r.Mkv)" 'Warning'
            }
        } else {
            Remove-Item $r.Mkv -Force
        }
    }
    Update-Ui
}

function Switch-Recording {
    if ($script:Rec) { Stop-Recording } else { Start-Recording }
}

function Save-Screenshot {
    $file   = (Get-OutputBase) + '.png'
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Invoke-Beep 1200 60
    Show-Notice 'Capture enregistrée' (Split-Path $file -Leaf)
}

# ---------------------------------------------------------------------------
# Interface : overlay
# ---------------------------------------------------------------------------
$script:UI = $null
$script:Overlay = $null

function New-FlatButton([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $back) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $back
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TabStop = $false
    $b
}

function New-StatCard([string]$caption, [int]$x) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, 44)
    $p.Size = New-Object System.Drawing.Size(104, 62)
    $p.BackColor = Rgb 42 42 52

    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $caption
    $cap.AutoSize = $true
    $cap.Location = New-Object System.Drawing.Point(10, 8)
    $cap.ForeColor = Rgb 150 150 165
    $cap.BackColor = [System.Drawing.Color]::Transparent
    $cap.Font = New-Object System.Drawing.Font('Segoe UI', 8)

    $val = New-Object System.Windows.Forms.Label
    $val.Text = '--'
    $val.AutoSize = $true
    $val.Location = New-Object System.Drawing.Point(8, 26)
    $val.ForeColor = [System.Drawing.Color]::White
    $val.BackColor = [System.Drawing.Color]::Transparent
    $val.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)

    $p.Controls.Add($cap); $p.Controls.Add($val)
    [pscustomobject]@{ Panel = $p; Caption = $cap; Value = $val }
}

function New-Overlay {
    $f = New-Object OverlayForm
    $script:Overlay = $f
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Opacity = 0.96
    $f.BackColor = Rgb 28 28 34
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.ClientSize = New-Object System.Drawing.Size(360, 214)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - 360) / 2)), ($wa.Top + 40))

    # Titre (sert aussi de poignée pour déplacer la barre)
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'GameBarPlus'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(14, 10)
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)

    $close = New-FlatButton '×' 322 6 30 26 (Rgb 28 28 34)
    $close.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $close.FlatAppearance.MouseOverBackColor = Rgb 200 50 60

    $cpu = New-StatCard 'CPU' 12
    $ram = New-StatCard 'RAM' 124
    $gpu = New-StatCard 'GPU' 236
    if (-not $script:NvSmi) { $gpu.Value.Text = 'n/a'; $gpu.Value.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11) }

    $rec    = New-FlatButton '' 12 118 336 44 (Rgb 60 110 220)
    $rec.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $shot   = New-FlatButton 'Capture'  12  172 106 30 (Rgb 52 52 64)
    $folder = New-FlatButton 'Dossier'  127 172 106 30 (Rgb 52 52 64)
    $set    = New-FlatButton 'Réglages' 242 172 106 30 (Rgb 52 52 64)
    foreach ($b in $shot, $folder, $set) { $b.FlatAppearance.MouseOverBackColor = Rgb 70 70 86 }

    # Déplacement à la souris
    $dragDown = { param($s, $e)
        if ($e.Button -eq 'Left') { $script:DragMouse = [System.Windows.Forms.Cursor]::Position; $script:DragForm = $script:Overlay.Location }
    }
    $dragMove = { param($s, $e)
        if ($e.Button -eq 'Left' -and $script:DragMouse) {
            $pos = [System.Windows.Forms.Cursor]::Position
            $script:Overlay.Location = New-Object System.Drawing.Point(
                ($script:DragForm.X + $pos.X - $script:DragMouse.X), ($script:DragForm.Y + $pos.Y - $script:DragMouse.Y))
        }
    }
    foreach ($c in $f, $title) { $c.Add_MouseDown($dragDown); $c.Add_MouseMove($dragMove) }

    $close.Add_Click({ Hide-Overlay })
    $rec.Add_Click({ Switch-Recording })
    $shot.Add_Click({ Save-Screenshot })
    $folder.Add_Click({ Open-ClipFolder })
    $set.Add_Click({ Show-Settings })

    $f.Controls.AddRange(@($title, $close, $cpu.Panel, $ram.Panel, $gpu.Panel, $rec, $shot, $folder, $set))
    $script:UI = @{ Cpu = $cpu; Ram = $ram; Gpu = $gpu; Rec = $rec }
    Update-Ui
}

function Show-Overlay {
    $f = $script:Overlay
    $f.TopMost = $false; $f.TopMost = $true
    $f.Show()
    Update-Stats
}
function Hide-Overlay   { $script:Overlay.Hide() }
function Switch-Overlay { if ($script:Overlay.Visible) { Hide-Overlay } else { Show-Overlay } }

function Update-Ui {
    if ($script:Rec) {
        $span = (Get-Date) - $script:Rec.Started
        $t = if ($span.TotalHours -ge 1) { $span.ToString('hh\:mm\:ss') } else { $span.ToString('mm\:ss') }
        if ($script:UI) {
            $script:UI.Rec.Text = "■  Arrêter    $t"
            $script:UI.Rec.BackColor = Rgb 205 45 55
        }
        if ($script:Tray) { $script:Tray.Icon = $script:IconRec; $script:Tray.Text = "GameBarPlus - REC $t" }
    } else {
        if ($script:UI) {
            $script:UI.Rec.Text = "●  Enregistrer    ($($script:Cfg.HotkeyRecord))"
            $script:UI.Rec.BackColor = Rgb 60 110 220
        }
        if ($script:Tray) { $script:Tray.Icon = $script:IconIdle; $script:Tray.Text = 'GameBarPlus' }
    }
}

function Set-StatValue($card, [double]$pct, [string]$text) {
    $card.Value.Text = $text
    $card.Value.ForeColor = if ($pct -ge 90) { Rgb 255 90 90 } elseif ($pct -ge 70) { Rgb 255 190 80 } else { Rgb 255 255 255 }
}

$script:StatTick = 0
function Update-Stats {
    $ui = $script:UI
    try {
        $cpu = if ($script:CpuCounter) { [math]::Round($script:CpuCounter.NextValue()) } else { 0 }
        Set-StatValue $ui.Cpu $cpu "$cpu %"
    } catch { }
    try {
        $ci  = $script:CompInfo
        $ram = [math]::Round(100 * (1 - ($ci.AvailablePhysicalMemory / $ci.TotalPhysicalMemory)))
        Set-StatValue $ui.Ram $ram "$ram %"
    } catch { }
    $script:StatTick++
    if ($script:NvSmi -and ($script:StatTick % 2 -eq 0)) {
        try {
            $line  = @(& $script:NvSmi '--query-gpu=utilization.gpu,temperature.gpu' '--format=csv,noheader,nounits')[0]
            $parts = $line -split ','
            $g = [int]$parts[0].Trim()
            $ui.Gpu.Caption.Text = 'GPU  ' + $parts[1].Trim() + '°C'
            Set-StatValue $ui.Gpu $g "$g %"
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Interface : fenêtre de réglages
# ---------------------------------------------------------------------------
$script:SettingsOpen = $false
function Show-Settings {
    if ($script:SettingsOpen) { return }
    $script:SettingsOpen = $true
    try {
        $cfg  = $script:Cfg
        $devs = Get-AudioDevices

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'GameBarPlus - Réglages'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.StartPosition = 'CenterScreen'
        $dlg.TopMost = $true
        $dlg.ClientSize = New-Object System.Drawing.Size(400, 440)
        $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lb = New-Object System.Windows.Forms.Label
        $lb.Text = 'Sources audio (une piste séparée par source) :'
        $lb.AutoSize = $true; $lb.Location = New-Object System.Drawing.Point(12, 12)

        $clb = New-Object System.Windows.Forms.CheckedListBox
        $clb.Location = New-Object System.Drawing.Point(12, 34)
        $clb.Size = New-Object System.Drawing.Size(376, 150)
        $clb.CheckOnClick = $true
        foreach ($d in $devs) { [void]$clb.Items.Add($d, ($cfg.AudioDevices -contains $d)) }

        $lf = New-Object System.Windows.Forms.Label
        $lf.Text = 'Images par seconde :'; $lf.AutoSize = $true; $lf.Location = New-Object System.Drawing.Point(12, 200)
        $combo = New-Object System.Windows.Forms.ComboBox
        $combo.DropDownStyle = 'DropDownList'
        $combo.Location = New-Object System.Drawing.Point(170, 196); $combo.Width = 80
        [void]$combo.Items.Add('30'); [void]$combo.Items.Add('60')
        $combo.SelectedItem = "$($cfg.Fps)"
        if ($combo.SelectedIndex -lt 0) { $combo.SelectedItem = '60' }

        $lbr = New-Object System.Windows.Forms.Label
        $lbr.Text = 'Débit vidéo (Mb/s) :'; $lbr.AutoSize = $true; $lbr.Location = New-Object System.Drawing.Point(12, 236)
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Location = New-Object System.Drawing.Point(170, 232); $num.Width = 80
        $num.Minimum = 5; $num.Maximum = 100
        $num.Value = [decimal][math]::Min(100, [math]::Max(5, [int]$cfg.BitrateMbps))

        $ld = New-Object System.Windows.Forms.Label
        $ld.Text = 'Dossier des clips :'; $ld.AutoSize = $true; $ld.Location = New-Object System.Drawing.Point(12, 272)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(12, 294); $tb.Width = 296
        $tb.Text = [string]$cfg.OutputDir
        $browse = New-Object System.Windows.Forms.Button
        $browse.Text = 'Parcourir...'
        $browse.Location = New-Object System.Drawing.Point(314, 292); $browse.Size = New-Object System.Drawing.Size(74, 26)
        $browse.Tag = $tb
        $browse.Add_Click({ param($s, $e)
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $s.Tag.Text = $fb.SelectedPath }
        })

        $snd = New-Object System.Windows.Forms.CheckBox
        $snd.Text = 'Bips sonores au début / à la fin'
        $snd.AutoSize = $true; $snd.Location = New-Object System.Drawing.Point(12, 332)
        $snd.Checked = [bool]$cfg.Sound

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = "Pour enregistrer le son du jeu : active « Mixage stéréo » dans les paramètres son de Windows (périphériques d'enregistrement), ou installe VB-Cable. Les réglages s'appliquent au prochain enregistrement."
        $hint.ForeColor = Rgb 110 110 120
        $hint.Location = New-Object System.Drawing.Point(12, 362); $hint.Size = New-Object System.Drawing.Size(376, 44)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'Enregistrer'; $ok.DialogResult = 'OK'
        $ok.Location = New-Object System.Drawing.Point(206, 406); $ok.Size = New-Object System.Drawing.Size(90, 26)
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Annuler'; $cancel.DialogResult = 'Cancel'
        $cancel.Location = New-Object System.Drawing.Point(302, 406); $cancel.Size = New-Object System.Drawing.Size(86, 26)
        $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

        $dlg.Controls.AddRange(@($lb, $clb, $lf, $combo, $lbr, $num, $ld, $tb, $browse, $snd, $hint, $ok, $cancel))

        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $cfg.AudioDevices = @($clb.CheckedItems | ForEach-Object { [string]$_ })
            $cfg.Fps          = [int]$combo.SelectedItem
            $cfg.BitrateMbps  = [int]$num.Value
            if ($tb.Text.Trim()) { $cfg.OutputDir = $tb.Text.Trim() }
            $cfg.Sound        = $snd.Checked
            Save-Config $cfg
            Show-Notice 'Réglages enregistrés' 'Ils seront appliqués au prochain enregistrement.'
        }
        $dlg.Dispose()
    } finally {
        $script:SettingsOpen = $false
    }
}

# ---------------------------------------------------------------------------
# Icône de la zone de notification
# ---------------------------------------------------------------------------
function New-DotIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $g.Dispose(); $brush.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Add-MenuItem($menu, [string]$text, [scriptblock]$action) {
    if ($text -eq '-') { [void]$menu.Items.Add('-'); return $null }
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $mi.Add_Click($action)
    [void]$menu.Items.Add($mi)
    $mi
}

function Quit-App { [System.Windows.Forms.Application]::ExitThread() }

# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------
[WinInfo]::SetProcessDPIAware() | Out-Null   # évite les captures décalées avec la mise à l'échelle Windows

$script:Cfg    = Get-Config
$script:FFmpeg = Get-FFmpeg -NoPrompt:$Background
$firstRun      = -not (Test-Path $ConfigPath)
if ($firstRun) { Save-Config $script:Cfg }

# --- Phase 1 : lancement normal -> on se relance caché puis on quitte
if (-not $Background -and -not $Console) {
    $existing = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\GameBarPlus', [ref]$existing)) {
        $existing.Dispose()
        Write-Host 'GameBarPlus est déjà lancé : cherche son icône près de l''horloge.' -ForegroundColor Yellow
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $PSCommandPath + '" -Background'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Write-Host 'GameBarPlus est lancé en arrière-plan.' -ForegroundColor Green
    Write-Host 'Cherche son icône (point bleu) près de l''horloge, ou appuie sur' $script:Cfg.HotkeyBar
    Write-Host 'Tu peux fermer cette fenêtre.'
    return
}

# --- Phase 2 : l'instance qui tourne vraiment
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\GameBarPlus', [ref]$created)
if (-not $created) { return }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
    param($s, $e)
    Write-Log ('Erreur : ' + $e.Exception.ToString())
    Show-Notice 'GameBarPlus - erreur' $e.Exception.Message 'Error'
})

# Compteurs de stats
try { $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); [void]$script:CpuCounter.NextValue() } catch { $script:CpuCounter = $null }
try { $script:CompInfo = New-Object Microsoft.VisualBasic.Devices.ComputerInfo } catch { $script:CompInfo = $null }
$nv = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($nv) { $script:NvSmi = $nv.Source }
elseif (Test-Path "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") { $script:NvSmi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
else { $script:NvSmi = $null }

# Icône + menu
$script:IconIdle = New-DotIcon (Rgb 80 140 255)
$script:IconRec  = New-DotIcon (Rgb 230 50 60)
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:IconIdle
$script:Tray.Text = 'GameBarPlus'
$script:Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void](Add-MenuItem $menu "Ouvrir / fermer la barre    ($($script:Cfg.HotkeyBar))" { Switch-Overlay })
[void](Add-MenuItem $menu "Démarrer / arrêter l'enregistrement    ($($script:Cfg.HotkeyRecord))" { Switch-Recording })
[void](Add-MenuItem $menu "Capture d'écran    ($($script:Cfg.HotkeyScreenshot))" { Save-Screenshot })
[void](Add-MenuItem $menu '-' { })
[void](Add-MenuItem $menu 'Ouvrir le dossier des clips' { Open-ClipFolder })
[void](Add-MenuItem $menu 'Réglages...' { Show-Settings })
$script:MiAuto = Add-MenuItem $menu 'Lancer au démarrage de Windows' {
    Set-AutoStart (-not (Test-Path (Get-StartupFile)))
}
[void](Add-MenuItem $menu '-' { })
[void](Add-MenuItem $menu 'Quitter' { Quit-App })
$menu.Add_Opening({ $script:MiAuto.Checked = Test-Path (Get-StartupFile) })
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Switch-Overlay } })

# Détection du matériel (quelques secondes)
$script:Encoder = Get-Encoder
$script:Capture = Get-CaptureMethod
Write-Log "Démarrage - encodeur $script:Encoder, capture $script:Capture, GPU stats : $(if ($script:NvSmi) { 'nvidia-smi' } else { 'non' })"

New-Overlay

# Raccourcis globaux
$win = New-Object HotkeyWindow
$failed = @()
foreach ($h in @(
    @{ Id = 1; Text = $script:Cfg.HotkeyRecord },
    @{ Id = 2; Text = $script:Cfg.HotkeyScreenshot },
    @{ Id = 3; Text = $script:Cfg.HotkeyQuit },
    @{ Id = 4; Text = $script:Cfg.HotkeyBar })) {
    $hk = ConvertTo-Hotkey $h.Text
    if (-not $win.Register($h.Id, $hk.Mods, $hk.Key)) { $failed += $h.Text }
}
$win.add_HotkeyPressed([Action[int]]{
    param($id)
    switch ($id) {
        1 { Switch-Recording }
        2 { Save-Screenshot }
        3 { Quit-App }
        4 { Switch-Overlay }
    }
})

# Minuteur : chrono REC, détection d'un FFmpeg planté, stats quand la barre est visible
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.Add_Tick({
    if ($script:Rec -and $script:Rec.Ff.P.HasExited) { Stop-Recording }
    Update-Ui
    if ($script:Overlay.Visible) { Update-Stats }
})
$script:Timer.Start()

if ($failed.Count -gt 0) {
    Show-Notice 'Raccourci déjà utilisé' ("Impossible d'enregistrer : " + ($failed -join ', ') + '. Change-le dans config.json.') 'Warning'
} else {
    Show-Notice 'GameBarPlus est prêt' "$($script:Cfg.HotkeyBar) : barre   |   $($script:Cfg.HotkeyRecord) : enregistrer"
}
if ($firstRun) { Show-Overlay }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:Timer.Stop()
    if ($script:Rec) { Stop-Recording }
    $win.Dispose()
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    try { $script:Mutex.ReleaseMutex() } catch { }
}
