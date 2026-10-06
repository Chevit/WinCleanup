@echo off
:: ============================================================
::  clean-office-history.bat - clears the "recent files/folders" traces
::  of Word, Excel and PowerPoint for privacy.
::  Walks EVERY installed Office version (no hard-coded 16.0) and
::  EVERY account subkey. Built-in tools only. Per-user (HKCU).
::  Option 1 = clean + backup to %LOCALAPPDATA%\Office-history-backup-<date>
::             (local, not synced to OneDrive/iCloud).
::  Option 5 = clean WITHOUT backup (irreversible).
::  The cmd part is pure ASCII; the logic runs in PowerShell below.
:: ============================================================

:: MRU is per-user, so admin rights are NOT required. Run as the
:: current user so HKCU points at the right profile.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8); $i=$s.IndexOf('#'+'PS-BEGIN'); iex $s.Substring($i)"
exit /b

#PS-BEGIN
$ErrorActionPreference = 'SilentlyContinue'

function Wait-Key {
    Write-Host ''
    Write-Host 'Натисніть будь-яку клавішу, щоб закрити вікно...'
    [void][Console]::ReadKey($true)
}

function Get-Key([Microsoft.Win32.RegistryKey]$Hive, [string]$Path, [bool]$Writable = $false) {
    try { return $Hive.OpenSubKey($Path, $Writable) } catch { return $null }
}

$HKCU = [Microsoft.Win32.Registry]::CurrentUser

# Values that are settings, not traces - never removed.
$KeepValues = @('', 'Max Display', 'HashAlgorithm')

# Entry value names to remove from an MRU/Trust key: everything except settings.
# Catches every naming scheme (Item N, FOLDERID_*, ...).
function Get-EntryNames([Microsoft.Win32.RegistryKey]$Key) {
    return @($Key.GetValueNames() | Where-Object { $KeepValues -notcontains $_ })
}

# Target for a VALUE-based key (File MRU, Place MRU, TrustRecords).
function Get-MruTarget([string]$RelPath, [string]$Kind) {
    $k = Get-Key $HKCU $RelPath
    if (-not $k) { return $null }
    $items = (Get-EntryNames $k).Count
    $k.Close()
    if ($items -le 0) { return $null }
    return [pscustomobject]@{ Path = $RelPath; Kind = $Kind; Mode = 'Values'; Items = $items }
}

# Target for a SUBKEY-based key (Reading Locations -> Document 0, Document 1, ...).
function Get-SubkeyTarget([string]$RelPath, [string]$Kind) {
    $k = Get-Key $HKCU $RelPath
    if (-not $k) { return $null }
    $items = @($k.GetSubKeyNames()).Count
    $k.Close()
    if ($items -le 0) { return $null }
    return [pscustomobject]@{ Path = $RelPath; Kind = $Kind; Mode = 'Subkeys'; Items = $items }
}

# Target for a FOLDER of shortcut files (%APPDATA%\Microsoft\Office\Recent).
function Get-FolderTarget([string]$Dir, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $Dir -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })
    if ($files.Count -le 0) { return $null }
    return [pscustomobject]@{ Path = $Dir; Kind = $Kind; Mode = 'Files'; Items = $files.Count }
}

# Account-based layout: <Parent>\<account>\{File MRU, Place MRU}.
# Used for "User MRU" and "Recent Templates". Skips the service "Change" subkey.
function Get-AccountTargets([string]$ParentPath, [string]$FileKind, [string]$PlaceKind) {
    $res = @()
    $pk = Get-Key $HKCU $ParentPath
    if (-not $pk) { return $res }
    foreach ($acct in $pk.GetSubKeyNames()) {
        if ($acct -eq 'Change') { continue }
        $t = Get-MruTarget "$ParentPath\$acct\File MRU" $FileKind
        if ($t) { $res += $t }
        $t = Get-MruTarget "$ParentPath\$acct\Place MRU" $PlaceKind
        if ($t) { $res += $t }
    }
    $pk.Close()
    return $res
}

# Clears one target according to its Mode. Returns $true on success.
function Clear-Target([pscustomobject]$T) {
    $ok = $true
    if ($T.Mode -eq 'Files') {
        foreach ($f in @(Get-ChildItem -LiteralPath $T.Path -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $ok = $false }
        }
        return $ok
    }
    $k = Get-Key $HKCU $T.Path $true
    if (-not $k) { return $false }
    if ($T.Mode -eq 'Subkeys') {
        foreach ($n in @($k.GetSubKeyNames())) { try { $k.DeleteSubKeyTree($n) } catch { $ok = $false } }
    } else {
        foreach ($n in (Get-EntryNames $k)) { try { $k.DeleteValue($n) } catch { $ok = $false } }
    }
    $k.Close()
    return $ok
}

# Waits until Word/Excel/PowerPoint are closed. Returns $false if the user cancels.
function Get-OfficeProcs {
    return @(Get-Process -Name winword, excel, powerpnt -ErrorAction SilentlyContinue)
}

# Force-closes Word/Excel/PowerPoint and waits up to ~10 s for them to exit.
function Stop-Office {
    Get-OfficeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-OfficeProcs).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return ((Get-OfficeProcs).Count -eq 0)
}

# Makes sure Word/Excel/PowerPoint are closed. Returns $false if the user cancels.
#   Enter - user closes them manually, then re-check
#   9     - force-close (unsaved changes are LOST)
#   0     - cancel
function Wait-OfficeClosed {
    while ($true) {
        $p = Get-OfficeProcs
        if ($p.Count -eq 0) { return $true }
        $names = (@($p | Select-Object -ExpandProperty ProcessName -Unique)) -join ', '
        Write-Host ''
        Write-Host "Зараз відкриті: $names" -ForegroundColor Red
        Write-Host 'Відкритий Office перезапише списки при закритті, тож спершу його треба закрити.' -ForegroundColor Red
        Write-Host '  Enter - я закрию сам (збережу документи), перевірити ще раз'
        Write-Host '  9     - закрити ПРИМУСОВО (незбережені зміни буде ВТРАЧЕНО)'
        Write-Host '  0     - скасувати'
        $a = ("$(Read-Host 'Ваш вибір')").Trim()
        if ($a -eq '0') { return $false }
        if ($a -eq '9') {
            if (Stop-Office) {
                Write-Host 'Office закрито примусово.' -ForegroundColor Yellow
            } else {
                Write-Host 'Не вдалося закрити всі програми Office.' -ForegroundColor Red
            }
        }
    }
}

# Creates the backup and VERIFIES every part. Returns the folder path, or $null on any failure.
function New-Backup([pscustomobject[]]$Targets) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:LOCALAPPDATA "Office-history-backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-Host 'Не вдалося створити папку для резервної копії.' -ForegroundColor Red
        return $null
    }
    $i = 0
    foreach ($t in $Targets) {
        if ($t.Mode -eq 'Files') {
            $dest = Join-Path $backup 'Office-Recent'
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $src = @(Get-ChildItem -LiteralPath $t.Path -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })
            foreach ($f in $src) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
            $copied = @(Get-ChildItem -LiteralPath $dest -File -Force).Count
            if ($copied -lt $src.Count) {
                Write-Host "Не вдалося скопіювати файли з $($t.Path)." -ForegroundColor Red
                return $null
            }
            continue
        }
        $i++
        $file = Join-Path $backup ("mru_{0:D3}.reg" -f $i)
        & reg.exe export "HKCU\$($t.Path)" $file /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) {
            Write-Host "Не вдалося експортувати HKCU\$($t.Path)." -ForegroundColor Red
            return $null
        }
    }
    $readme = @'
ЯК ВІДНОВИТИ СЛІДИ OFFICE ПІСЛЯ clean-office-history.bat
====================================================

Скрипт очистив списки "Останні" (файли й папки), нещодавні шаблони,
довірені документи, історію читання Word і ярлики в папці
%APPDATA%\Microsoft\Office\Recent. Самі документи та налаштування
Office не чіпалися.

ВІДНОВЛЕННЯ (спершу закрийте Word, Excel і PowerPoint)
1. Реєстр: двічі клацніть кожен mru_XXX.reg у цій папці ->
   підтвердіть -> "Так". Імпорт лише ДОДАЄ записи назад.
2. Ярлики: скопіюйте вміст папки Office-Recent назад у
   %APPDATA%\Microsoft\Office\Recent
   (вставте цей шлях в адресний рядок Провідника).

ПРО ЩО ЙДЕТЬСЯ
   mru_XXX.reg - це гілки:
     ...\<програма>\User MRU\<акаунт>\File MRU         (останні файли)
     ...\<програма>\User MRU\<акаунт>\Place MRU        (останні папки)
     ...\<програма>\File MRU, Place MRU                (старий формат)
     ...\<програма>\Recent Templates\<акаунт>\File MRU (нещодавні шаблони)
     ...\<програма>\Security\...\TrustRecords          (довірені файли)
     ...\Word\Reading Locations                        (історія читання)

ДЕ ЛЕЖИТЬ ЦЯ ПАПКА
   У %LOCALAPPDATA% - вона НЕ синхронізується з OneDrive чи iCloud.
   Відкрити: Win+R -> %LOCALAPPDATA% -> Enter.

КОЛИ ВИДАЛЯТИ ЦЮ ПАПКУ
   Усе гаразд -> видаліть одразу: вона містить ті самі шляхи до
   файлів, які скрипт прибрав.
   Треба повернути -> спершу відновіть, потім видаляйте.
'@
    [IO.File]::WriteAllText((Join-Path $backup 'ЯК-ВІДНОВИТИ.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    return $backup
}

function Main {
    Write-Host '=== Очищення слідів Office (Word/Excel/PowerPoint) ===' -ForegroundColor Cyan
    Write-Host ''

    # --- Office must be closed before scanning (it rewrites lists on exit) ---
    if (-not (Wait-OfficeClosed)) {
        Write-Host 'Скасовано. Нічого не змінено.' -ForegroundColor Yellow
        return
    }

    $apps = 'Word', 'Excel', 'PowerPoint'
    $officeBase = 'Software\Microsoft\Office'

    # --- Find installed Office versions (e.g. 11.0 ... 16.0) ---
    $versions = @()
    $vk = Get-Key $HKCU $officeBase
    if ($vk) {
        $versions = @($vk.GetSubKeyNames() | Where-Object { $_ -match '^\d+\.\d+$' } |
            Sort-Object { [version]$_ })
        $vk.Close()
    }
    if ($versions.Count -gt 0) {
        Write-Host ("Знайдені версії Office: " + ($versions -join ', ')) -ForegroundColor DarkGray
    } else {
        Write-Host 'У реєстрі профілю не знайдено версій Office.' -ForegroundColor DarkGray
    }

    # --- Collect targets across all versions, apps and accounts ---
    $targets = @()
    foreach ($v in $versions) {
        foreach ($app in $apps) {
            $appPath = "$officeBase\$v\$app"

            # Modern layout: User MRU\<account>\{File MRU, Place MRU}
            $targets += @(Get-AccountTargets "$appPath\User MRU" 'File' 'Place')

            # Legacy layout (and Office 16 defaults): <app>\{File MRU, Place MRU}
            $t = Get-MruTarget "$appPath\File MRU" 'File'
            if ($t) { $targets += $t }
            $t = Get-MruTarget "$appPath\Place MRU" 'Place'
            if ($t) { $targets += $t }

            # Recent Templates: same account layout; root holds only settings
            $targets += @(Get-AccountTargets "$appPath\Recent Templates" 'Templates' 'Templates')
            $t = Get-MruTarget "$appPath\Recent Templates" 'Templates'
            if ($t) { $targets += $t }

            # Trusted Documents: files opened with "Enable Editing"
            $t = Get-MruTarget "$appPath\Security\Trusted Documents\TrustRecords" 'Trust'
            if ($t) { $targets += $t }

            # Reading Locations (Word only; "resume reading" - subkey per document)
            if ($app -eq 'Word') {
                $t = Get-SubkeyTarget "$appPath\Reading Locations" 'Reading'
                if ($t) { $targets += $t }
            }
        }
    }

    # Office's own Recent folder with .lnk shortcuts to opened documents
    $t = Get-FolderTarget (Join-Path $env:APPDATA 'Microsoft\Office\Recent') 'OfficeRecent'
    if ($t) { $targets += $t }

    if ($targets.Count -eq 0) {
        Write-Host 'Слідів не знайдено. Нічого видаляти.' -ForegroundColor Green
        return
    }

    # --- Preview ---
    $sumKind = { param($x) [int]((@($targets | Where-Object { $_.Kind -eq $x }) | Measure-Object Items -Sum).Sum) }
    $trust = & $sumKind 'Trust'
    Write-Host ''
    Write-Host 'Знайдено записів:' -ForegroundColor Yellow
    Write-Host "  Останні файли (File MRU):                 $(& $sumKind 'File')"
    Write-Host "  Останні папки (Place MRU):                $(& $sumKind 'Place')"
    Write-Host "  Нещодавні шаблони (Recent Templates):     $(& $sumKind 'Templates')"
    Write-Host "  Довірені відкриті файли (TrustRecords):   $trust"
    Write-Host "  Історія читання Word (Reading Locations): $(& $sumKind 'Reading')"
    Write-Host "  Ярлики в папці Office\Recent:             $(& $sumKind 'OfficeRecent')"
    Write-Host ''
    if ($trust -gt 0) {
        Write-Host 'Примітка: після очищення TrustRecords для цих файлів знову з''явиться' -ForegroundColor DarkYellow
        Write-Host 'смуга "Увімкнути редагування" / попередження про макроси. Це нормально.' -ForegroundColor DarkYellow
        Write-Host ''
    }
    Write-Host 'Хмарні документи OneDrive у списку "Останні" скрипт не прибирає -' -ForegroundColor DarkGray
    Write-Host 'їх видаляють у Word: правий клік -> "Видалити зі списку".' -ForegroundColor DarkGray
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

    # --- Re-check: Office could have been reopened while the preview was shown ---
    if (-not (Wait-OfficeClosed)) {
        Write-Host 'Скасовано. Нічого не змінено.' -ForegroundColor Yellow
        return
    }

    # --- Backup (option 1 only), verified ---
    $backup = $null
    if ($doBackup) {
        $backup = New-Backup $targets
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

    # --- Clear ---
    Write-Host 'Очищення...' -ForegroundColor Cyan
    $ok = 0; $fail = 0
    foreach ($t in $targets) {
        if (Clear-Target $t) { $ok++ } else { $fail++ }
    }

    # --- Result ---
    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    Write-Host "  Очищено місць:  $ok"
    if ($fail -gt 0) {
        Write-Host "  Не вдалося:     $fail" -ForegroundColor Yellow
    }
    Write-Host ''
    if ($doBackup) {
        Write-Host 'Резервна копія лежить у %LOCALAPPDATA% (не синхронізується з хмарою):' -ForegroundColor Yellow
        Write-Host "  $backup" -ForegroundColor Yellow
        Write-Host 'Вона містить ті самі шляхи до файлів. Коли переконаєтесь, що все гаразд, видаліть її.' -ForegroundColor Yellow
    } else {
        Write-Host 'Резервну копію не створювали - відновити не вийде.' -ForegroundColor Yellow
    }
}

Main
Wait-Key
