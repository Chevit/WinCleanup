@echo off
:: ============================================================
::  clean-windows.bat - safe cleanup, built-in Windows tools only
::  The cmd part below is pure ASCII: it only elevates and hands
::  the rest of this file (after the marker) to PowerShell, which
::  prints Ukrainian text reliably on any console code page.
::  The script path is passed via %SELF% so paths with ' or spaces work.
:: ============================================================

set "SELF=%~f0"

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:SELF -Verb RunAs -ErrorAction Stop } catch { $UacDenied = 1; $s=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#'+'PS-BEGIN')) }"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#'+'PS-BEGIN'))"
exit /b

#PS-BEGIN
$ErrorActionPreference = 'SilentlyContinue'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'PowerShell у обмеженому режимі (Constrained Language Mode) - потрібен повний. Нічого не змінено.' -ForegroundColor Red
    Read-Host 'Натисніть Enter, щоб закрити' | Out-Null
    exit
}

function Wait-Key {
    Write-Host ''
    Write-Host 'Натисніть будь-яку клавішу, щоб закрити вікно...'
    [void][Console]::ReadKey($true)
}

function Get-FreeBytes {
    try { return [double](New-Object IO.DriveInfo $env:SystemDrive).AvailableFreeSpace } catch { return [double]0 }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($Bytes / 1KB))
}

# Deletes files older than $Cutoff and folders left empty, recursively.
# Never follows junctions/symlinks, so nothing outside the folder is touched.
function Remove-OldItems([string]$Dir, [datetime]$Cutoff, [hashtable]$Stats) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($item.PSIsContainer) {
            Remove-OldItems $item.FullName $Cutoff $Stats
            $left = @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue).Count
            if ($left -eq 0 -and $item.CreationTime -lt $Cutoff) {
                try { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop; $Stats.Removed++ } catch { $Stats.Skipped++ }
            }
        } elseif ($item.LastWriteTime -lt $Cutoff -and $item.CreationTime -lt $Cutoff) {
            $len = $item.Length
            try {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                $Stats.Removed++; $Stats.Bytes += $len
            } catch { $Stats.Skipped++ }
        }
    }
}

# Cleans a temp folder: only items older than 1 hour. Refuses obviously wrong paths.
function Clear-TempFolder([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host '      папку не знайдено, пропускаю' -ForegroundColor DarkGray
        return
    }
    $full = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $forbidden = @($env:SystemDrive, $env:WINDIR, $env:USERPROFILE) | ForEach-Object { "$_".TrimEnd('\') }
    if ($full -match '^[A-Za-z]:$' -or ($forbidden -contains $full)) {
        Write-Host "      небезпечний шлях ($full), пропускаю" -ForegroundColor Red
        return
    }
    $stats = @{ Removed = 0; Skipped = 0; Bytes = [double]0 }
    Remove-OldItems $full (Get-Date).AddHours(-1) $stats
    Write-Host ('      видалено: {0}, пропущено (зайняті): {1}, звільнено: {2}' -f $stats.Removed, $stats.Skipped, (Format-Size $stats.Bytes)) -ForegroundColor DarkGray
}

function Get-MyExplorer {
    $sid = (Get-Process -Id $PID).SessionId
    return @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid })
}

# Explorer normally restarts by itself after being stopped. If not, start it
# as a normal (non-elevated) user; as a last resort tell the user how.
function Start-ExplorerIfNeeded {
    for ($i = 0; $i -lt 10; $i++) {
        if ((Get-MyExplorer).Count -gt 0) { return }
        Start-Sleep -Milliseconds 500
    }
    & runas.exe /trustlevel:0x20000 explorer.exe 2>&1 | Out-Null
    for ($i = 0; $i -lt 10; $i++) {
        if ((Get-MyExplorer).Count -gt 0) { return }
        Start-Sleep -Milliseconds 500
    }
    Write-Host '      Провідник не запустився сам. Натисніть Ctrl+Shift+Esc -> "Запустити нове завдання" -> explorer -> OK.' -ForegroundColor Yellow
}

# Recent: delete shortcut files and the Quick Access "recent files" list.
# Explorer is stopped first, otherwise it keeps the list in memory and writes it back.
# AutomaticDestinations / CustomDestinations are NOT wiped entirely, because
# they also hold taskbar jump lists with pinned items.
function Clear-RecentHistory {
    $recent = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
    $wasRunning = (Get-MyExplorer).Count -gt 0
    if ($wasRunning) {
        Get-MyExplorer | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $recent -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {}
    }
    Remove-Item -LiteralPath (Join-Path $recent 'AutomaticDestinations\5f7b5f1e01b83767.automaticDestinations-ms') -Force -ErrorAction SilentlyContinue
    Write-Host "      видалено ярликів: $n" -ForegroundColor DarkGray
    if ($wasRunning) { Start-ExplorerIfNeeded }
}

# Profile 42 for cleanmgr: ONLY the safe categories are on (2), every other
# category is explicitly off (0), so leftovers from earlier /sageset:42 runs
# can never clean Downloads, Recycle Bin or previous Windows installations.
function Set-CleanupProfile {
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $safe = @(
        'Temporary Files'
        'Temporary Setup Files'
        'Update Cleanup'
        'Delivery Optimization Files'
        'Thumbnail Cache'
        'Windows Error Reporting Files'
        'Setup Log Files'
    )
    foreach ($k in @(Get-ChildItem -LiteralPath $vc -ErrorAction SilentlyContinue)) {
        $flag = 0
        if ($safe -contains $k.PSChildName) { $flag = 2 }
        Set-ItemProperty -LiteralPath $k.PSPath -Name 'StateFlags0042' -Value $flag -Type DWord
    }
}

function Main {
    Write-Host 'Цей скрипт очистить тимчасові файли, історію нещодавніх файлів і запустить очищення диска.' -ForegroundColor Cyan
    Write-Host 'Провідник буде перезапущено (відкриті вікна Провідника закриються).' -ForegroundColor DarkGray
    $go = ("$(Read-Host 'Enter - почати, 0 - скасувати')").Trim()
    if ($go -eq '0') {
        Write-Host 'Скасовано. Нічого не змінено.' -ForegroundColor Yellow
        return
    }
    Write-Host ''

    $freeBefore = Get-FreeBytes

    Write-Host "[1/5] Тимчасові файли користувача (старші за 1 годину): $env:TEMP" -ForegroundColor Cyan
    Clear-TempFolder $env:TEMP

    Write-Host "[2/5] Тимчасові файли Windows (старші за 1 годину): $env:WINDIR\Temp" -ForegroundColor Cyan
    Clear-TempFolder "$env:WINDIR\Temp"

    Write-Host '[3/5] Історія нещодавніх файлів (Recent)...' -ForegroundColor Cyan
    Write-Host '      Провідник буде перезапущено: відкриті вікна Провідника закриються.' -ForegroundColor DarkGray
    Clear-RecentHistory

    Write-Host '[4/5] Очищення диска (лише безпечні категорії)...' -ForegroundColor Cyan
    Set-CleanupProfile
    Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:42' -Wait

    Write-Host '[5/5] Очищення сховища компонентів (DISM), це може зайняти кілька хвилин...' -ForegroundColor Cyan
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      DISM завершився з кодом $LASTEXITCODE (сховище компонентів не очищено)." -ForegroundColor Yellow
    }

    $freed = (Get-FreeBytes) - $freeBefore
    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    if ($freed -ge 1MB) {
        Write-Host "Звільнено на диску ${env:SystemDrive}: $(Format-Size $freed)" -ForegroundColor Green
    } else {
        Write-Host "Вільне місце на диску ${env:SystemDrive} практично не змінилося." -ForegroundColor Green
    }
    Write-Host 'Файли, що зараз використовуються або свіжіші за 1 годину, було пропущено.' -ForegroundColor DarkGray
}

if ($UacDenied) {
    Write-Host 'Права адміністратора не надано. Нічого не змінено.' -ForegroundColor Yellow
} else {
    Main
}
Wait-Key
