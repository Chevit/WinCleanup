@echo off
:: ============================================================
::  clean-shell-history.bat - clears Explorer "activity" traces for privacy:
::  Run box (RunMRU), typed paths, Explorer search (WordWheelQuery), recent
::  documents (RecentDocs), folder-view history (ShellBags), the UserAssist
::  program-launch counters and the Jump Lists (taskbar icon menus: recent and
::  pinned-in-menu items). Built-in tools only. Per-user (HKCU / %APPDATA%).
::  Explorer is restarted so cleared lists are not written back from memory.
::  Option 1 = clean + backup to %LOCALAPPDATA%\Shell-history-backup-<date>
::             (local, not synced to OneDrive/iCloud).
::  Option 5 = clean WITHOUT backup (irreversible).
::  The cmd part is pure ASCII; the logic runs in PowerShell below.
:: ============================================================

:: These lists are per-user, so admin rights are NOT required. Run as the
:: current user so HKCU points at the right profile.

set "SELF=%~f0"

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

function Get-Key([Microsoft.Win32.RegistryKey]$Hive, [string]$Path, [bool]$Writable = $false) {
    try { return $Hive.OpenSubKey($Path, $Writable) } catch { return $null }
}

$HKCU = [Microsoft.Win32.Registry]::CurrentUser

$RunMRU     = 'Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
$TypedPaths = 'Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths'
$WordWheel  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery'
$RecentDocs = 'Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs'
$UserAssist = 'Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
$BagMRU1    = 'Software\Microsoft\Windows\Shell\BagMRU'
$Bags1      = 'Software\Microsoft\Windows\Shell\Bags'
$BagMRU2    = 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'
$Bags2      = 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
$JumpAuto   = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'
$JumpCustom = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations'

# --- Explorer stop/start (these lists are cached in memory and rewritten on exit) ---
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

# Counts history entries (named values + subkeys) in a branch; -1 if absent.
function Measure-Branch([string]$Path) {
    $k = Get-Key $HKCU $Path
    if (-not $k) { return -1 }
    $n = @($k.GetValueNames() | Where-Object { $_ -ne '' }).Count + @($k.GetSubKeyNames()).Count
    $k.Close()
    return $n
}

# UserAssist: count the values under every {GUID}\Count subkey.
function Measure-UserAssist([string]$Path) {
    $root = Get-Key $HKCU $Path
    if (-not $root) { return -1 }
    $n = 0
    foreach ($g in @($root.GetSubKeyNames())) {
        $c = Get-Key $HKCU "$Path\$g\Count"
        if ($c) { $n += @($c.GetValueNames() | Where-Object { $_ -ne '' }).Count; $c.Close() }
    }
    $root.Close()
    return $n
}

# Counts files in a folder (Jump Lists); -1 if the folder is absent.
function Measure-Files([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return -1 }
    return @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue).Count
}

function Measure-Target($T) {
    if ($T.Type -eq 'files') { return Measure-Files $T.Path }
    if ($T.Type -eq 'userassist') { return Measure-UserAssist $T.Path }
    return Measure-Branch $T.Path
}

# Deletes every named value and every subkey under a branch, leaving the now
# empty branch so Explorer simply repopulates it. Returns $true on full success.
function Clear-Branch([string]$Path) {
    $k = Get-Key $HKCU $Path $true
    if (-not $k) { return $true }
    $ok = $true
    foreach ($n in @($k.GetValueNames() | Where-Object { $_ -ne '' })) {
        try { $k.DeleteValue($n) } catch { $ok = $false }
    }
    foreach ($n in @($k.GetSubKeyNames())) {
        try { $k.DeleteSubKeyTree($n) } catch { $ok = $false }
    }
    $k.Close()
    return $ok
}

# UserAssist: only the Count values are history; the {GUID} keys themselves stay.
function Clear-UserAssist([string]$Path) {
    $root = Get-Key $HKCU $Path
    if (-not $root) { return $true }
    $ok = $true
    foreach ($g in @($root.GetSubKeyNames())) {
        $ok = (Clear-Branch "$Path\$g\Count") -and $ok
    }
    $root.Close()
    return $ok
}

# Deletes every file in a folder (Jump Lists), keeps the folder itself.
function Clear-Files([string]$Dir) {
    $ok = $true
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $ok = $false }
    }
    return $ok
}

function Clear-Target($T) {
    if ($T.Type -eq 'files') { return Clear-Files $T.Path }
    if ($T.Type -eq 'userassist') { return Clear-UserAssist $T.Path }
    return Clear-Branch $T.Path
}

# Exports every active branch and writes the restore guide.
# Returns the folder path, or $null on any failure (then nothing is cleaned).
function New-Backup([object[]]$Active) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:LOCALAPPDATA "Shell-history-backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-Host 'Не вдалося створити папку для резервної копії.' -ForegroundColor Red
        return $null
    }
    $i = 0
    foreach ($t in $Active) {
        if ($t.Type -eq 'files') {
            $dest = Join-Path $backup ('JumpLists\' + (Split-Path -Leaf $t.Path))
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $src = @(Get-ChildItem -LiteralPath $t.Path -File -Force -ErrorAction SilentlyContinue)
            foreach ($f in $src) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
            $copied = @(Get-ChildItem -LiteralPath $dest -File -Force -ErrorAction SilentlyContinue).Count
            if ($copied -lt $src.Count) {
                Write-Host "Не вдалося скопіювати файли з $($t.Path)." -ForegroundColor Red
                return $null
            }
            continue
        }
        $i++
        $file = Join-Path $backup ("branch_{0:D2}.reg" -f $i)
        & reg.exe export "HKCU\$($t.Path)" $file /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) {
            Write-Host "Не вдалося експортувати HKCU\$($t.Path)." -ForegroundColor Red
            return $null
        }
    }
    $readme = @'
ЯК ВІДНОВИТИ СЛІДИ АКТИВНОСТІ ПІСЛЯ clean-shell-history.bat
==========================================================

Скрипт очистив історію Провідника: вікно "Виконати" (Win+R), введені
шляхи, історію пошуку, нещодавні документи, історію вигляду папок
(ShellBags), лічильники запусків програм (UserAssist) і меню іконок на
панелі задач (Jump Lists). Самі файли й налаштування програм не чіпалися.

ВІДНОВЛЕННЯ
1. Двічі клацніть кожен branch_XX.reg у цій папці -> підтвердіть -> "Так".
   Імпорт лише ДОДАЄ записи назад.
2. Jump Lists: скопіюйте файли з папок JumpLists\AutomaticDestinations
   і JumpLists\CustomDestinations назад у
   %APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations та
   %APPDATA%\Microsoft\Windows\Recent\CustomDestinations
   (вставте шлях в адресний рядок Провідника).
3. Перезавантажте комп'ютер, щоб Провідник перечитав відновлене.

ПРО ЩО ЙДЕТЬСЯ
   branch_XX.reg - це гілки HKCU\...\Explorer\{RunMRU, TypedPaths,
   WordWheelQuery, RecentDocs, UserAssist} та ...\Shell\{BagMRU, Bags}.

ДЕ ЛЕЖИТЬ ЦЯ ПАПКА
   У %LOCALAPPDATA% - вона НЕ синхронізується з OneDrive чи iCloud.
   Відкрити: Win+R -> %LOCALAPPDATA% -> Enter.

КОЛИ ВИДАЛЯТИ ЦЮ ПАПКУ
   Усе гаразд -> видаліть одразу: вона містить ті самі записи, які
   скрипт прибрав.
   Треба повернути -> спершу відновіть, потім видаляйте.
'@
    [IO.File]::WriteAllText((Join-Path $backup 'ЯК-ВІДНОВИТИ.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    return $backup
}

function Main {
    Write-Host '=== Очищення слідів активності Провідника ===' -ForegroundColor Cyan
    Write-Host ''

    $targets = @(
        [pscustomobject]@{ Label = 'Вікно "Виконати" (Win+R)';         Path = $RunMRU;     Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Введені шляхи в адресному рядку';  Path = $TypedPaths; Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Історія пошуку в Провіднику';      Path = $WordWheel;  Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Нещодавні документи (RecentDocs)'; Path = $RecentDocs; Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Вигляд папок: ShellBags (MRU)';    Path = $BagMRU1;    Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Вигляд папок: ShellBags (дані)';   Path = $Bags1;      Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Вигляд папок: Classes (MRU)';      Path = $BagMRU2;    Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Вигляд папок: Classes (дані)';     Path = $Bags2;      Type = 'branch';     Items = 0 }
        [pscustomobject]@{ Label = 'Лічильники запусків (UserAssist)'; Path = $UserAssist; Type = 'userassist'; Items = 0 }
        [pscustomobject]@{ Label = 'Jump Lists: нещодавні (авто)';     Path = $JumpAuto;   Type = 'files';      Items = 0 }
        [pscustomobject]@{ Label = 'Jump Lists: власні програм';       Path = $JumpCustom; Type = 'files';      Items = 0 }
    )

    foreach ($t in $targets) { $t.Items = Measure-Target $t }
    $active = @($targets | Where-Object { $_.Items -gt 0 })

    if ($active.Count -eq 0) {
        Write-Host 'Слідів не знайдено. Нічого видаляти.' -ForegroundColor Green
        return
    }

    # --- Preview ---
    Write-Host 'Знайдено записів:' -ForegroundColor Yellow
    foreach ($t in $active) {
        Write-Host ('  {0,-34} {1}' -f $t.Label, $t.Items)
    }
    Write-Host ''
    Write-Host 'Провідник буде перезапущено: відкриті вікна Провідника закриються.' -ForegroundColor DarkGray
    Write-Host 'ShellBags: скинеться збережений вигляд папок (розмір вікна, сортування).' -ForegroundColor DarkGray
    Write-Host 'UserAssist: скинеться список "найчастіше використовувані" в меню Пуск.' -ForegroundColor DarkGray
    Write-Host 'Jump Lists: зникне закріплене всередині меню іконок на панелі задач (самі іконки лишаться).' -ForegroundColor DarkGray
    Write-Host ''

    # --- Choose action ---
    Write-Host 'Виберіть дію та натисніть Enter:' -ForegroundColor Cyan
    Write-Host '  1 - очистити ТА зберегти резервну копію (можна відновити)'
    Write-Host '  5 - очистити БЕЗ резервної копії (відновлення неможливе)'
    Write-Host '  будь-що інше - скасувати'
    $ans = ("$(Read-Host 'Ваш вибір')").Trim()
    if ($ans -ne '1' -and $ans -ne '5') {
        Write-Host 'Скасовано. Нічого не змінено.' -ForegroundColor Yellow
        return
    }
    $doBackup = ($ans -eq '1')

    # --- Backup (option 1 only), verified ---
    $backup = $null
    if ($doBackup) {
        $backup = New-Backup $active
        if (-not $backup) {
            Write-Host 'Резервну копію не створено повністю. Зупиняюсь, нічого не змінено.' -ForegroundColor Red
            return
        }
        Write-Host "Резервну копію збережено: $backup" -ForegroundColor Cyan
        Write-Host 'Інструкція з відновлення: ЯК-ВІДНОВИТИ.txt у цій папці.' -ForegroundColor Cyan
    } else {
        Write-Host 'Режим без резервної копії: зміни будуть НЕЗВОРОТНІ.' -ForegroundColor Red
    }
    Write-Host ''

    # --- Clear (Explorer stopped so it can't write the lists back) ---
    Write-Host 'Очищення...' -ForegroundColor Cyan
    $wasRunning = (Get-MyExplorer).Count -gt 0
    if ($wasRunning) {
        Get-MyExplorer | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    $ok = 0; $fail = 0
    foreach ($t in $active) {
        if (Clear-Target $t) { $ok++ } else { $fail++ }
    }
    if ($wasRunning) { Start-ExplorerIfNeeded }

    # --- Result ---
    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    Write-Host "  Очищено гілок:  $ok"
    if ($fail -gt 0) {
        Write-Host "  Не вдалося:     $fail" -ForegroundColor Yellow
    }
    Write-Host ''
    if ($doBackup) {
        Write-Host 'Резервна копія лежить у %LOCALAPPDATA% (не синхронізується з хмарою):' -ForegroundColor Yellow
        Write-Host "  $backup" -ForegroundColor Yellow
        Write-Host 'Вона містить ті самі записи. Коли переконаєтесь, що все гаразд, видаліть її.' -ForegroundColor Yellow
    } else {
        Write-Host 'Резервну копію не створювали - відновити не вийде.' -ForegroundColor Yellow
    }
}

Main
Wait-Key
