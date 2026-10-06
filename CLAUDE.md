# WinCleanup

Standalone `.bat` scripts that clean specific areas of Windows (temp/disk, USB history, Office history).
Each script is a single file the user double-clicks. No installers, no third-party tools — built-in Windows tooling only
(PowerShell 5.1, `reg.exe`, `pnputil.exe`, `wevtutil.exe`, `cleanmgr.exe`, `Dism.exe`).

The repo is edited on macOS; scripts run on Windows 10 2004+ / Windows 11. They can't be executed here — review by reading.

## Scripts

| File | Scope | Admin | Destructive? | Backup |
|---|---|---|---|---|
| `clean-windows.bat` | `%TEMP%`, `%WINDIR%\Temp` (items older than 1 h), Explorer Recent + Quick Access recent jump list, `cleanmgr /sagerun:42` (safe categories only), `DISM /StartComponentCleanup` | yes | low, no prompt | no |
| `clean-usb-history.bat` | Disconnected USB flash drives (USBSTOR) + disconnected portable devices (WPD): PnP records, `MountedDevices`, `MountPoints2`, `Windows Portable Devices`, `EMDMgmt`, `setupapi.dev*.log` sections, 4 device-connection event logs | yes | high | option `1` = backup, `5` = no backup |
| `clean-office-history.bat` | Word/Excel/PowerPoint MRU for every Office version and account: File/Place MRU, Recent Templates, TrustRecords, Word Reading Locations, `%APPDATA%\Microsoft\Office\Recent` | **no** (HKCU, must run as current user) | medium | option `1` = backup, `5` = no backup |

## File format — hard rules

- **UTF-8 without BOM, CRLF line endings.** A BOM breaks the first `@echo off` line in cmd.
- **The cmd part (above `#PS-BEGIN`) must be pure ASCII.** It only elevates and hands the rest of the file to PowerShell.
- Everything after the `#PS-BEGIN` marker is PowerShell, loaded via
  `[IO.File]::ReadAllText(<path>, UTF8)` + `iex $s.Substring($s.IndexOf('#'+'PS-BEGIN'))`.
  The marker is built as `'#'+'PS-BEGIN'` so the launcher line itself doesn't match.
- Ukrainian user-facing text lives only in the PowerShell part (prints correctly on any console code page).
- Code comments are English; all user-facing strings (prompts, results, `ЯК-ВІДНОВИТИ.txt`) are Ukrainian.

## Canonical launcher (use `clean-windows.bat` as the reference)

```bat
set "SELF=%~f0"

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:SELF -Verb RunAs -ErrorAction Stop } catch { $UacDenied = 1; $s=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#'+'PS-BEGIN')) }"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#'+'PS-BEGIN'))"
exit /b
```

- Pass the path via `%SELF%` / `$env:SELF`, never `'%~f0'` inside a PS string — a `'` in the path breaks it.
- On UAC denial the PS part runs non-elevated with `$UacDenied = 1` and must print "nothing changed" and exit cleanly.
- Non-admin scripts (Office) skip the `net session` block entirely.
- All three scripts now share this launcher (Office without the `net session`/elevation block). `check.sh` enforces it.

## PowerShell conventions

- `$ErrorActionPreference = 'SilentlyContinue'` globally; anything whose failure matters uses `-ErrorAction Stop` inside `try/catch` and is counted (`$ok` / `$fail`).
- Always `-LiteralPath`. Never follow reparse points (junctions/symlinks) when deleting.
- Registry via .NET (`[Microsoft.Win32.Registry]` + `Get-Key` helper), not the `HKCU:` provider, for exact subkey/value control.
- Every script ends with `Wait-Key` so the window stays open.
- Output style: `[n/N] step...` in Cyan, details in DarkGray, warnings Yellow, errors Red, final `Готово.` in Green with counts.
- First statement of every PS body guards Constrained Language Mode: `if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage')` → message + `exit` (AppLocker/WDAC machines would otherwise fail on the first `[IO.File]` call).

## Safety model (do not weaken)

1. **Scan → preview → choose → act.** Destructive scripts show what was found and change nothing until the user picks an option.
2. Menu: `1` = clean + backup, `5` = clean without backup (irreversible), anything else = cancel. `5` is deliberately not adjacent to `1`.
3. Backup goes to `%LOCALAPPDATA%\<Name>-backup-<yyyyMMdd-HHmmss>` (not synced to OneDrive/iCloud), with `ЯК-ВІДНОВИТИ.txt` (UTF-8 **with** BOM, CRLF — it's opened in Notepad). The readme must say the backup contains the same traces and should be deleted once verified.
4. **If any part of the backup fails, stop before changing anything.**
5. Never touch currently connected devices, Downloads, Recycle Bin, previous Windows installs, main System/Application event logs, or Bluetooth.
6. `cleanmgr` profile 42: every `VolumeCaches` key gets `StateFlags0042` explicitly set — `2` for the safe list, `0` for the rest.
7. Processes that rewrite state on exit (Explorer, Office) are closed before cleaning; Office force-close only after an explicit `9`.

## Adding a new script

Copy `clean-windows.bat`'s launcher, keep the safety model above, add a row to the table, update the header comment block (scope, requirements, options).
Run `./check.sh` before committing: it verifies no BOM, CRLF endings, pure-ASCII cmd part, and `%SELF%` launcher across every `.bat`. It never modifies files.

## Known issues / backlog

Fixed 2026-10-06:
- `%SELF%` launcher + UAC-denied handling ported to USB and Office scripts (paths with `'` no longer break).
- `clean-usb-history.bat` `New-Backup` now verifies every `reg export` / log copy and returns `$null` (aborting the clean) on failure; absent branches like EMDMgmt are skipped, not treated as errors.
- `clean-windows.bat`: Enter/0 confirmation before acting; `Dism.exe` exit code checked.
- Constrained Language Mode guard added to all three.
- Added `check.sh` (format guard, Mac-side only).
- `clean-usb-history.bat`: setupapi filter now also removes sections of disconnected WPD devices (phones/cameras), not just flash drives (`$wpdKeysId` folded into `Invoke-LogFilter` `$Extra`; preview count updated).

Open:
- `clean-office-history.bat`: `Recent Templates` root is treated as a value MRU — any non-whitelisted setting value there would be deleted. Verify on a real profile or drop that target.
- Not covered yet (candidates): `HKLM\SOFTWARE\Microsoft\Windows Search\VolumeInfoCache` (drive letters + volume labels), ShellBags, Office app jump lists in `AutomaticDestinations`, Office roaming MRU for signed-in accounts (list can come back from the cloud).

## Testing

No PowerShell on the dev Mac — scripts are reviewed by reading and tested manually on a real Windows machine (snapshot/restore-point first). Threat model: ordinary inspection via Explorer/Word plus common free tools (USBDeview, ShellBags Explorer); full forensic recovery (VSS snapshots, $UsnJrnl, free-space carving) is out of scope and can't be addressed with built-in tools alone.
