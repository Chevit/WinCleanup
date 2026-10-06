@echo off
:: ============================================================
::  clean-windows.bat - safe cleanup, built-in Windows tools only
::  The cmd part below is pure ASCII: it only elevates and hands
::  the rest of this file (after the marker) to PowerShell, which
::  prints Ukrainian text reliably on any console code page.
:: ============================================================

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8); $i=$s.IndexOf('#'+'PS-BEGIN'); iex $s.Substring($i)"
exit /b

#PS-BEGIN
$ErrorActionPreference = 'SilentlyContinue'

function Clear-Folder([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Get-ChildItem -LiteralPath $Path -Force |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[1/5] Очищення тимчасових файлів користувача: $env:TEMP" -ForegroundColor Cyan
Clear-Folder $env:TEMP

Write-Host "[2/5] Очищення тимчасових файлів Windows: $env:WINDIR\Temp" -ForegroundColor Cyan
Clear-Folder "$env:WINDIR\Temp"

# Recent: delete only shortcut files and the Quick Access "recent files" list.
# AutomaticDestinations / CustomDestinations are NOT wiped entirely, because
# they also hold taskbar jump lists with pinned items.
Write-Host "[3/5] Очищення історії нещодавніх файлів (Recent)..." -ForegroundColor Cyan
$recent = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
Get-ChildItem -LiteralPath $recent -Filter '*.lnk' -File -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $recent 'AutomaticDestinations\5f7b5f1e01b83767.automaticDestinations-ms') -Force -ErrorAction SilentlyContinue

Write-Host "[4/5] Очищення диска (лише безпечні категорії)..." -ForegroundColor Cyan
$vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
@(
    'Temporary Files'
    'Temporary Setup Files'
    'Update Cleanup'
    'Delivery Optimization Files'
    'Thumbnail Cache'
    'Windows Error Reporting Files'
    'Setup Log Files'
) | ForEach-Object {
    $key = Join-Path $vc $_
    if (Test-Path $key) {
        Set-ItemProperty -Path $key -Name 'StateFlags0042' -Value 2 -Type DWord
    }
}
Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:42' -Wait

Write-Host "[5/5] Очищення сховища компонентів (DISM), це може зайняти кілька хвилин..." -ForegroundColor Cyan
Dism.exe /Online /Cleanup-Image /StartComponentCleanup

Write-Host ""
Write-Host "Готово. Файли, що зараз використовуються, було автоматично пропущено." -ForegroundColor Green
Write-Host "Натисніть будь-яку клавішу, щоб закрити вікно..."
[void][Console]::ReadKey($true)
