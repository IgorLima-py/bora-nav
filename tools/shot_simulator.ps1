<#
.SYNOPSIS
    Saves a PNG of the Connect IQ simulator screen, with no human click.

.DESCRIPTION
    Why this script exists
    ----------------------
    Seeing the watch screen is the only way to answer "did the corridor draw?" without
    depending on Igor looking. The SDK does not offer this for free:

    * `simulator.exe` has no screenshot flag — the SDK's own `connectiq.bat`
      calls it with no argument at all.
    * The simulator's TCP shell (`shell.exe --transport=tcp
      --transport_args=127.0.0.1:1234`) exposes only `push`, `pull`, `ciq`, `uptime`,
      `fit_parse` and the `NFM_*` flash commands. No screen command.
    * The menu *File -> Save Screen Capture* exists, but it opens a file dialog.

    So the script has three paths, and picks by the window's state:

    1. `native` — fires the menu item through `WM_COMMAND` and fills in the file
       dialog through the API (`WM_SETTEXT` in the name field, a click on the button with ID 1, which
       is `IDOK` in any language). Out comes the PNG of the **device framebuffer**,
       454x454 on the Venu 4 45mm, with no bezel or strap. It is what you want for reading
       the map.
    2. `printwindow` — `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`. Grabs the whole
       window (menu and the watch's box around it) but **does not steal focus** and
       works with the window behind another one.
    3. `bitblt` — `CopyFromScreen`. It is the **only one that works with the simulator
       hung**, because it does not talk to the target process. In exchange it copies the
       desktop, not the window: if something else is on top, the PNG is theirs. In
       testing this produced a Photoshop capture that looked like a success, and that is
       why the script checks who is on top before saving
       (`VisibleFraction`) and prefers to refuse rather than deliver the wrong screen.

    The detail that cost a stuck session: **the first two are synchronous
    calls into the simulator process**. `PrintWindow` sends a
    `WM_PRINT` and waits for the UI thread to answer — if it is hung,
    the wait is **infinite**, there is no timeout. And the simulator really hangs:
    after a *Kill App* with an error dialog open,
    `IsHungAppWindow(main window)` returned `True` and the capture sat still
    for minutes without using CPU.

    That is why the script **probes the window before touching it**
    (`SendMessageTimeout(WM_NULL, SMTO_ABORTIFHUNG)`), and when it does not answer
    it jumps straight to `bitblt`, which reads desktop pixels and does not talk to the target
    process. Precisely the case where the capture matters most: the app froze and we
    want to see what was left on the screen.

    On every path the PNG is measured before being declared good — distinct colors
    and standard deviation of luminance. A black PNG is the classic way for the capture
    to fail without warning, and failing silently is worse than not capturing.

.PARAMETER Out
    PNG path. Default: `shots/simulator-<timestamp>.png` at the repo root.

.PARAMETER Mode
    `auto` (default: `native`, then window), `native` or `window`.

.PARAMETER WindowMethod
    Window mode only: `auto` (default), `printwindow` or `bitblt`.

.PARAMETER Crop
    Window mode only: `"x,y,w,h"` crop in window pixels.

.PARAMETER TitlePattern
    Regex of the window title. Default `CIQ Simulator`.

.PARAMETER ProcessName
    Process that owns the window. Default `simulator`.

.PARAMETER TimeoutSec
    Maximum wait for the `native` mode dialog. Default 8.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/shot_simulator.ps1 -Out C:\tmp\tela.png

.EXAMPLE
    # without touching Igor's focus, even with the simulator behind another window
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/shot_simulator.ps1 -Mode window -Out C:\tmp\janela.png

.NOTES
    A freebie from the same investigation: `shell.exe --transport=tcp
    --transport_args=127.0.0.1:1234 pull <source_on_device> <destination_on_pc>`
    copies files from inside the simulated device — including `CIQ_LOG.YML`, with no
    MTP and no cable.

    The file must stay saved as **UTF-8 with BOM**: Windows PowerShell
    5.1 reads `.ps1` without BOM as ANSI and the accents in these comments become a syntax
    error.
#>
[CmdletBinding()]
param(
    [string]$Out = "",
    [ValidateSet("auto", "native", "window")]
    [string]$Mode = "auto",
    [ValidateSet("auto", "printwindow", "bitblt")]
    [string]$WindowMethod = "auto",
    [string]$Crop = "",
    [string]$TitlePattern = "CIQ Simulator",
    [string]$ProcessName = "simulator",
    [int]$TimeoutSec = 8
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$signature = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class MotoNavWin {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd, uint msg, IntPtr wp, string lp, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int pos);
    [DllImport("user32.dll")] public static extern int GetMenuItemID(IntPtr menu, int pos);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, int id, StringBuilder s, int n, int flags);

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    public class Win { public IntPtr Handle; public string Title; public string Class; public int W; public int H; }

    // How much of the window is actually visible, from 0 to 1. BitBlt copies the desktop:
    // if another window is on top, it returns ITS content with every
    // appearance of success — which is what happened in testing, a Photoshop PNG
    // passing as a simulator capture. Samples a 5x5 grid and asks
    // Windows who is on top at each point.
    public static double VisibleFraction(IntPtr hWnd, RECT r) {
        int hit = 0, total = 0;
        for (int i = 1; i <= 5; i++) {
            for (int j = 1; j <= 5; j++) {
                POINT p;
                p.X = r.Left + (r.Right - r.Left) * i / 6;
                p.Y = r.Top + (r.Bottom - r.Top) * j / 6;
                IntPtr under = GetAncestor(WindowFromPoint(p), 2 /* GA_ROOT */);
                if (under == hWnd) hit++;
                total++;
            }
        }
        return total == 0 ? 0.0 : (double)hit / total;
    }

    private const uint SMTO_ABORTIFHUNG = 0x0002;

    private static string Text(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); return sb.ToString(); }
    private static string Cls(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }

    // The question that avoids the infinite wait: does the thread that owns this window still
    // pump messages? PrintWindow and SendMessage have no timeout; this does.
    public static bool Responsive(IntPtr hWnd, uint ms) {
        if (IsHungAppWindow(hWnd)) return false;
        IntPtr res;
        IntPtr ok = SendMessageTimeoutW(hWnd, 0x0000 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, ms, out res);
        return ok != IntPtr.Zero;
    }

    public static bool SetTextSafe(IntPtr hWnd, string value, uint ms) {
        IntPtr res;
        return SendMessageTimeoutW(hWnd, 0x000C /* WM_SETTEXT */, IntPtr.Zero, value, SMTO_ABORTIFHUNG, ms, out res) != IntPtr.Zero;
    }

    public static bool ClickSafe(IntPtr hWnd, uint ms) {
        IntPtr res;
        return SendMessageTimeoutW(hWnd, 0x00F5 /* BM_CLICK */, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, ms, out res) != IntPtr.Zero;
    }

    // Visible top-level windows of a process, the largest first: the simulator's main one
    // is the largest; the rest are palettes and dialogs.
    public static List<Win> TopLevel(uint wantPid) {
        List<Win> found = new List<Win>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != wantPid || !IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            Win w = new Win();
            w.Handle = h; w.Title = Text(h); w.Class = Cls(h);
            w.W = r.Right - r.Left; w.H = r.Bottom - r.Top;
            found.Add(w);
            return true;
        }, IntPtr.Zero);
        found.Sort(delegate(Win a, Win b) { return (b.W * b.H).CompareTo(a.W * a.H); });
        return found;
    }

    // First child with the requested class and control ID. id < 0 ignores the ID.
    public static IntPtr FindChild(IntPtr parent, string className, int id) {
        IntPtr hit = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
            if (Cls(h) != className) return true;
            if (id >= 0 && GetDlgCtrlID(h) != id) return true;
            hit = h; return false;
        }, IntPtr.Zero);
        return hit;
    }

    // Looks for the menu item by label instead of hardcoding the number: if the SDK
    // renumbers the commands in a new version, this keeps finding it.
    public static int FindMenuCommand(IntPtr hWnd, string pattern) {
        IntPtr bar = GetMenu(hWnd);
        if (bar == IntPtr.Zero) return -1;
        var re = new System.Text.RegularExpressions.Regex(pattern,
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        for (int i = 0; i < GetMenuItemCount(bar); i++) {
            IntPtr sub = GetSubMenu(bar, i);
            if (sub == IntPtr.Zero) continue;
            for (int j = 0; j < GetMenuItemCount(sub); j++) {
                StringBuilder sb = new StringBuilder(256);
                GetMenuStringW(sub, j, sb, 256, 0x400 /* MF_BYPOSITION */);
                if (re.IsMatch(sb.ToString())) {
                    int id = GetMenuItemID(sub, j);
                    if (id > 0) return id;
                }
            }
        }
        return -1;
    }

    public static bool MenuEnabled(IntPtr hWnd, int id) {
        IntPtr bar = GetMenu(hWnd);
        if (bar == IntPtr.Zero) return false;
        for (int i = 0; i < GetMenuItemCount(bar); i++) {
            IntPtr sub = GetSubMenu(bar, i);
            if (sub == IntPtr.Zero) continue;
            uint st = GetMenuState(sub, (uint)id, 0 /* MF_BYCOMMAND */);
            if (st == 0xFFFFFFFF) continue;          // not in this submenu
            return (st & 0x3) == 0;                  // MF_GRAYED | MF_DISABLED
        }
        return false;
    }
}
'@

if (-not ("MotoNavWin" -as [type])) { Add-Type -TypeDefinition $signature }

# Without this, on a monitor with scale != 100% Windows lies about the size of the
# window and the capture comes out cropped.
try { [void][MotoNavWin]::SetProcessDPIAware() } catch { }

$WM_COMMAND = 0x0111
$IDOK       = 1
$IDYES      = 6
$MSG_MS     = 3000

function Get-SimulatorWindow {
    param([string]$Proc, [string]$Pattern)

    $procs = @(Get-Process -Name $Proc -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        throw "process '$Proc' is not running. Open the simulator (connectiq.bat) and load the app with monkeydo."
    }

    # Minimized, the window is ~160x28 and falls out of the size filter below: it was the
    # "runs but has no visible top window" of 2026-09-29, with the simulator
    # only minimized. Restores without activating (4 = SW_SHOWNOACTIVATE), so as not to
    # steal focus from whoever is using the machine.
    $restored = $false
    foreach ($p in $procs) {
        foreach ($w in [MotoNavWin]::TopLevel([uint32]$p.Id)) {
            if ([MotoNavWin]::IsIconic($w.Handle)) {
                [void][MotoNavWin]::ShowWindow($w.Handle, 4)
                $restored = $true
            }
        }
    }
    if ($restored) { Start-Sleep -Milliseconds 500 }

    $all = @()
    foreach ($p in $procs) {
        foreach ($w in [MotoNavWin]::TopLevel([uint32]$p.Id)) {
            if ($w.W -ge 200 -and $w.H -ge 200 -and $w.Class -ne "#32770") { $all += $w }
        }
    }
    if ($all.Count -eq 0) { throw "'$Proc' is running but has no visible top-level window." }

    $match = @($all | Where-Object { $_.Title -match $Pattern })
    if ($match.Count -gt 0) { return $match[0] }

    # The title changes with the loaded device; the largest window of the right process
    # is still the correct bet.
    return $all[0]
}

# A black PNG is the classic way for the capture to fail without warning.
function Measure-Bitmap {
    param([System.Drawing.Bitmap]$Bitmap)

    $rect = New-Object System.Drawing.Rectangle 0, 0, $Bitmap.Width, $Bitmap.Height
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = New-Object byte[] ($data.Stride * $Bitmap.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    } finally {
        $Bitmap.UnlockBits($data)
    }

    $colors = New-Object 'System.Collections.Generic.HashSet[int]'
    $sum = 0.0; $sumSq = 0.0; $n = 0
    # Sample every 4 pixels: 16x less work, same answer.
    for ($y = 0; $y -lt $Bitmap.Height; $y += 4) {
        $row = $y * $data.Stride
        for ($x = 0; $x -lt $Bitmap.Width; $x += 4) {
            $i = $row + $x * 4
            $b = $bytes[$i]; $g = $bytes[$i + 1]; $r = $bytes[$i + 2]
            [void]$colors.Add(($r -shl 16) -bor ($g -shl 8) -bor $b)
            $lum = 0.299 * $r + 0.587 * $g + 0.114 * $b
            $sum += $lum; $sumSq += $lum * $lum; $n++
        }
    }

    $mean = $sum / $n
    $var = ($sumSq / $n) - ($mean * $mean)
    if ($var -lt 0) { $var = 0 }
    $sd = [math]::Sqrt($var)

    return [pscustomobject]@{
        Colors = $colors.Count
        Mean   = [math]::Round($mean, 2)
        StdDev = [math]::Round($sd, 2)
        Blank  = ($colors.Count -le 2 -and $sd -lt 1.0)
    }
}

function Measure-File {
    param([string]$Path)
    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $s = Measure-Bitmap -Bitmap $bmp
        return [pscustomobject]@{
            Colors = $s.Colors; Mean = $s.Mean; StdDev = $s.StdDev
            Blank = $s.Blank; Size = "$($bmp.Width)x$($bmp.Height)"
        }
    } finally { $bmp.Dispose() }
}

# --------------------------------------------------------------------------- #
# native: simulator menu + file dialog driven by message.
# --------------------------------------------------------------------------- #
function Save-NativeScreenshot {
    # $Pid is a PowerShell automatic variable (read-only), hence OwnerPid.
    param([IntPtr]$Handle, [uint32]$OwnerPid, [string]$Path, [int]$Timeout)

    $cmd = [MotoNavWin]::FindMenuCommand($Handle, 'Screen\s*Capture|Screenshot')
    if ($cmd -lt 0) { return "the menu has no screenshot item" }
    if (-not [MotoNavWin]::MenuEnabled($Handle, $cmd)) {
        return "menu item (id $cmd) is grayed out; load an app with monkeydo first"
    }

    if (Test-Path $Path) { Remove-Item $Path -Force }

    $before = @{}
    foreach ($w in [MotoNavWin]::TopLevel($OwnerPid)) { $before[[int64]$w.Handle] = $true }

    [void][MotoNavWin]::PostMessageW($Handle, $WM_COMMAND, [IntPtr]$cmd, [IntPtr]0)

    # Waits for the file dialog. Any dialog will not do: only what counts is what
    # has the name field (Edit with ID 1001). An app error modal is also
    # `#32770`, and canceling it by mistake would touch what is not ours.
    $dialog = [IntPtr]::Zero
    $edit = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in [MotoNavWin]::TopLevel($OwnerPid)) {
            if ($w.Class -ne "#32770" -or $before.ContainsKey([int64]$w.Handle)) { continue }
            $e = [MotoNavWin]::FindChild($w.Handle, "Edit", 1001)
            if ($e -eq [IntPtr]::Zero) { $e = [MotoNavWin]::FindChild($w.Handle, "Edit", 1148) }
            if ($e -ne [IntPtr]::Zero) { $dialog = $w.Handle; $edit = $e; break }
        }
        if ($dialog -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($dialog -eq [IntPtr]::Zero) {
        return "the file dialog did not open within ${Timeout}s (menu blocked by another modal?)"
    }

    if (-not [MotoNavWin]::SetTextSafe($edit, $Path, $MSG_MS)) {
        return "the dialog did not accept the path (thread hung?)"
    }
    Start-Sleep -Milliseconds 250

    # Clicks by control ID (IDOK = 1), not by label: in Portuguese the button
    # is called "Salvar" and a script looking for "Save" never finds it.
    $ok = [MotoNavWin]::FindChild($dialog, "Button", $IDOK)
    if ($ok -ne [IntPtr]::Zero) {
        [void][MotoNavWin]::ClickSafe($ok, $MSG_MS)
    } else {
        [void][MotoNavWin]::PostMessageW($dialog, $WM_COMMAND, [IntPtr]$IDOK, [IntPtr]0)
    }

    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return $null }
        # Overwrite confirmation, if it shows up anyway.
        foreach ($w in [MotoNavWin]::TopLevel($OwnerPid)) {
            if ($w.Class -ne "#32770" -or $w.Handle -eq $dialog -or $before.ContainsKey([int64]$w.Handle)) { continue }
            $yes = [MotoNavWin]::FindChild($w.Handle, "Button", $IDYES)
            if ($yes -ne [IntPtr]::Zero) { [void][MotoNavWin]::ClickSafe($yes, $MSG_MS) }
        }
        Start-Sleep -Milliseconds 200
    }

    return "the dialog accepted the path but the file did not show up"
}

# --------------------------------------------------------------------------- #
# window: pixels of the whole window.
# --------------------------------------------------------------------------- #
function Copy-WindowPixels {
    param([IntPtr]$Handle, [int]$Width, [int]$Height, [string]$How, [MotoNavWin+RECT]$Rect)

    $bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        if ($How -eq "printwindow") {
            $hdc = $g.GetHdc()
            try {
                # 2 = PW_RENDERFULLCONTENT. Without this flag, what the window draws
                # outside WM_PRINT comes out black.
                $ok = [MotoNavWin]::PrintWindow($Handle, $hdc, 2)
            } finally {
                $g.ReleaseHdc($hdc)
            }
            if (-not $ok) { $g.Dispose(); $bmp.Dispose(); return $null }
        } else {
            $g.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0,
                              (New-Object System.Drawing.Size $Width, $Height),
                              [System.Drawing.CopyPixelOperation]::SourceCopy)
        }
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function Save-WindowScreenshot {
    param([IntPtr]$Handle, [string]$Path, [string]$Prefer, [string]$CropSpec, [bool]$Alive)

    if ([MotoNavWin]::IsIconic($Handle)) {
        [void][MotoNavWin]::ShowWindow($Handle, 9)   # SW_RESTORE
        Start-Sleep -Milliseconds 400
    }

    $rect = New-Object MotoNavWin+RECT
    [void][MotoNavWin]::GetWindowRect($Handle, [ref]$rect)

    $order = switch ($Prefer) {
        "printwindow" { @("printwindow") }
        "bitblt"      { @("bitblt") }
        default       { if ($Alive) { @("printwindow", "bitblt") } else { @("bitblt") } }
    }

    $tried = @()
    foreach ($how in $order) {
        # PrintWindow is synchronous: on a hung window it waits forever.
        if ($how -eq "printwindow" -and -not $Alive) {
            $tried += "printwindow: skipped, the window is hung"
            continue
        }
        if ($how -eq "bitblt") {
            # Only BitBlt needs the window in front; PrintWindow does not.
            [void][MotoNavWin]::SetForegroundWindow($Handle)
            Start-Sleep -Milliseconds 400
            [void][MotoNavWin]::GetWindowRect($Handle, [ref]$rect)

            # And a hung window does not come up: SetForegroundWindow returns
            # success and nothing happens. Without this check the script delivers
            # another program's print as if it were the simulator.
            $vis = [MotoNavWin]::VisibleFraction($Handle, $rect)
            if ($vis -lt 0.9) {
                $tried += ("bitblt: only {0:P0} of the window is visible; another window is on top" -f $vis)
                continue
            }
        }
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top

        # The simulator vanishes out of nowhere (an app crash takes the window down). Without this
        # check the New-Object Bitmap 0x0 blows up with "Parâmetro inválido",
        # which tells nobody what actually happened.
        if (-not [MotoNavWin]::IsWindow($Handle) -or $w -le 0 -or $h -le 0) {
            $tried += "${how}: the window vanished mid-capture (did the simulator crash?)"
            continue
        }

        $bmp = Copy-WindowPixels -Handle $Handle -Width $w -Height $h -How $how -Rect $rect
        if ($null -eq $bmp) { $tried += "${how}: the API refused"; continue }

        $stats = Measure-Bitmap -Bitmap $bmp
        $tried += ("{0}: {1} colors, deviation {2}" -f $how, $stats.Colors, $stats.StdDev)
        if ($stats.Blank) { $bmp.Dispose(); continue }

        if ($CropSpec) {
            $parts = $CropSpec -split '\s*,\s*'
            if ($parts.Count -ne 4) { $bmp.Dispose(); throw "-Crop expects 'x,y,w,h', got '$CropSpec'" }
            $cx = [int]$parts[0]; $cy = [int]$parts[1]; $cw = [int]$parts[2]; $ch = [int]$parts[3]
            if ($cx -lt 0 -or $cy -lt 0 -or $cx + $cw -gt $bmp.Width -or $cy + $ch -gt $bmp.Height) {
                $bmp.Dispose(); throw "-Crop '$CropSpec' falls outside the ${w}x${h} window"
            }
            $box = New-Object System.Drawing.Rectangle $cx, $cy, $cw, $ch
            $cut = $bmp.Clone($box, $bmp.PixelFormat)
            $bmp.Dispose(); $bmp = $cut
        }

        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return @{ Method = $how; Error = $null }
    }

    return @{ Method = $null; Error = ("no method gave useful pixels: " + ($tried -join "; ")) }
}

# --------------------------------------------------------------------------- #

if (-not $Out) {
    $root = Split-Path -Parent $PSScriptRoot
    $Out = Join-Path (Join-Path $root "shots") ("simulator-{0}.png" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$win = Get-SimulatorWindow -Proc $ProcessName -Pattern $TitlePattern
$simPid = 0
[void][MotoNavWin]::GetWindowThreadProcessId($win.Handle, [ref]$simPid)

# The measurement that decides everything: if the UI thread does not pump messages, any
# synchronous path hangs with no timeout.
$alive = [MotoNavWin]::Responsive($win.Handle, 2000)

$used = $null
$notes = @()
if (-not $alive) { $notes += "window hung (IsHungAppWindow): only bitblt works" }

if ($Mode -ne "window" -and $alive) {
    $err = Save-NativeScreenshot -Handle $win.Handle -OwnerPid ([uint32]$simPid) -Path $Out -Timeout $TimeoutSec
    if ($null -eq $err) { $used = "native" } else { $notes += "native: $err" }
} elseif ($Mode -eq "native" -and -not $alive) {
    Write-Error "native mode impossible: the simulator window is hung. Use -Mode window."
    exit 4
}

if (-not $used -and $Mode -ne "native") {
    $res = Save-WindowScreenshot -Handle $win.Handle -Path $Out -Prefer $WindowMethod -CropSpec $Crop -Alive $alive
    if ($res.Method) { $used = $res.Method } else { $notes += "window: $($res.Error)" }
}

if (-not $used) {
    Write-Error ("could not capture:`n  " + ($notes -join "`n  "))
    exit 2
}

$stats = Measure-File -Path $Out
if ($stats.Blank) {
    Write-Error "the PNG came out blank/black ($($stats.Colors) colors) — useless capture: $Out"
    exit 3
}

[pscustomobject]@{
    Path   = $Out
    Size   = $stats.Size
    Bytes  = (Get-Item $Out).Length
    Method = $used
    Colors = $stats.Colors
    Mean   = $stats.Mean
    StdDev = $stats.StdDev
    Window = $win.Title
    Notes  = ($notes -join " | ")
}
