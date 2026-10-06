@echo off
:: ============================================================
::  clean-usb-history.bat - removes traces of DISCONNECTED USB
::  flash drives (USBSTOR) for privacy. Built-in tools only.
::  Windows 10 2004+ (build 19041+) and Windows 11.
::  Also removes disconnected portable devices (phones, cameras, players)
::  and clears the device-connection event logs (exported first).
::  Does NOT touch Bluetooth, connected drives, or main System/App logs.
::  Option 1 = clean + backup to %LOCALAPPDATA%\USB-backup-<date>
::             (local, not synced to OneDrive/iCloud).
::  Option 5 = clean WITHOUT backup (irreversible).
::  The cmd part is pure ASCII; the logic runs in PowerShell below.
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

function Wait-Key {
    Write-Host ''
    Write-Host 'Натисніть будь-яку клавішу, щоб закрити вікно...'
    [void][Console]::ReadKey($true)
}

function Get-Key([Microsoft.Win32.RegistryKey]$Hive, [string]$Path, [bool]$Writable = $false) {
    try { return $Hive.OpenSubKey($Path, $Writable) } catch { return $null }
}

# True if text mentions a device that is plugged in right now
function Test-Present([string]$Text, [string[]]$Keys) {
    $u = ($Text -replace '\\', '#').ToUpper()
    foreach ($k in $Keys) { if ($k -and $u.Contains($k)) { return $true } }
    return $false
}

# True if text belongs to a flash drive (USBSTOR or its USB port record) that is NOT connected
function Test-FlashText([string]$Text, [string[]]$Keys, [string[]]$Extra) {
    $u = ($Text -replace '\\', '#').ToUpper()
    $hit = $u.Contains('USBSTOR#')
    if (-not $hit) {
        foreach ($e in $Extra) { if ($e -and $u.Contains($e)) { $hit = $true; break } }
    }
    if (-not $hit) { return $false }
    return -not (Test-Present $Text $Keys)
}

function Find-SubKeys([Microsoft.Win32.RegistryKey]$Hive, [string]$Path, [string[]]$Keys) {
    $k = Get-Key $Hive $Path
    if (-not $k) { return @() }
    $r = @($k.GetSubKeyNames() | Where-Object { Test-FlashText $_ $Keys @() })
    $k.Close()
    return $r
}

# True if the subkey name contains any of the given device tokens.
function Test-HasToken([string]$Text, [string[]]$Tokens) {
    if (-not $Tokens -or $Tokens.Count -eq 0) { return $false }
    $u = ($Text -replace '\\', '#').ToUpper()
    foreach ($t in $Tokens) { if ($t -and $u.Contains($t)) { return $true } }
    return $false
}

function Find-SubKeysByTokens([Microsoft.Win32.RegistryKey]$Hive, [string]$Path, [string[]]$Tokens) {
    $k = Get-Key $Hive $Path
    if (-not $k) { return @() }
    $r = @($k.GetSubKeyNames() | Where-Object { Test-HasToken $_ $Tokens })
    $k.Close()
    return $r
}

# Removes flash-drive sections (">>>  [..." ... "<<<  [Exit status...]") from a setupapi log.
# Returns the number of sections found; writes the file only when $Apply is true.
function Invoke-LogFilter([string]$Path, [string[]]$Keys, [string[]]$Extra, [bool]$Apply) {
    $sr = New-Object IO.StreamReader($Path, [Text.Encoding]::Default, $true)
    try { $text = $sr.ReadToEnd(); $enc = $sr.CurrentEncoding } finally { $sr.Close() }
    $lines = $text -split "`r?`n"
    $out = New-Object 'System.Collections.Generic.List[string]'
    $skip = $false; $sawEnd = $false; $dropped = 0
    foreach ($l in $lines) {
        if ($skip) {
            if ($l -match '^>>>\s+\[') {
                $skip = $false; $sawEnd = $false
            } elseif ($l.StartsWith('<<<')) {
                $sawEnd = $true; continue
            } elseif (-not $sawEnd) {
                continue
            } else {
                $skip = $false; $sawEnd = $false
                if ($l.Trim() -eq '') { continue }
            }
        }
        if ($l -match '^>>>\s+\[' -and (Test-FlashText $l $Keys $Extra)) {
            $skip = $true; $dropped++; continue
        }
        $out.Add($l)
    }
    if ($Apply -and $dropped -gt 0) {
        [IO.File]::WriteAllText($Path, ($out -join "`r`n"), $enc)
    }
    return $dropped
}

# Creates the backup folder in %LOCALAPPDATA% (not synced to the cloud), exports the registry branches and
# copies the setupapi logs, then writes the restore guide. Returns the folder
# path, or $null if the folder could not be created.
function New-Backup($Logs, $RegExports) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:LOCALAPPDATA "USB-backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if (-not (Test-Path -LiteralPath $backup)) { return $null }
    foreach ($file in $RegExports.Keys) {
        & reg.exe export $RegExports[$file] (Join-Path $backup $file) /y 2>&1 | Out-Null
    }
    foreach ($f in $Logs) { Copy-Item -LiteralPath $f.FullName -Destination $backup -Force }
    $readme = @'
ЯК ВІДНОВИТИ ЗМІНИ ПІСЛЯ clean-usb-history.bat
==============================================

Скрипт чіпав лише записи про ВІДКЛЮЧЕНІ флешки та портативні пристрої
(телефони, камери, плеєри) і журнали їх підключення. Windows для своєї
роботи їх не потребує, тож відновлення потрібне рідко.

1. РЕЄСТР
   Двічі клацніть кожен .reg-файл у цій папці -> підтвердіть UAC -> "Так":
     MountedDevices.reg          - літери дисків флешок
     MountPoints2.reg            - історія томів у профілі користувача
     WindowsPortableDevices.reg  - назви флешок
     EMDMgmt.reg                 - кеш ReadyBoost (файлу може не бути)
   Імпорт лише ДОДАЄ назад видалене і нічого нового не стирає.

2. SETUPAPI-ЛОГИ
   Скопіюйте файли setupapi.dev*.log з цієї папки назад у
   C:\Windows\INF із заміною (Провідник попросить права адміністратора).

3. ЖУРНАЛИ ПОДІЙ (папка EventLogs, якщо є)
   Журнали підключення очищено повністю. Відновити їх у системний
   журнал стандартними засобами не можна, але .evtx-файли з папки
   EventLogs - це повна копія. Відкрийте будь-який подвійним кліком
   у Переглядачі подій (Event Viewer), щоб переглянути старі записи.

4. Перезавантажте комп'ютер.

ЧОГО ТУТ НЕМАЄ
   Самих записів пристроїв (їх видаляв pnputil) немає в резервній копії:
   Windows не дозволяє їх так зберегти. Вони й не потрібні. Вставте
   флешку чи телефон - Windows за кілька секунд створить запис заново.
   Флешка може отримати іншу літеру диска. Повернути стару:
   Win+X -> Керування дисками -> правий клік на флешці ->
   Змінити букву диска.

ДЕ ЛЕЖИТЬ ЦЯ ПАПКА
   У %LOCALAPPDATA% - вона НЕ синхронізується з OneDrive чи iCloud.
   Відкрити: Win+R -> %LOCALAPPDATA% -> Enter.

КОЛИ ВИДАЛЯТИ ЦЮ ПАПКУ
   Усе гаразд -> видаліть її одразу: вона містить ті самі сліди,
   які скрипт прибрав.
   Щось не так -> спершу відновіть, перевірте, потім видаліть.
'@
    [IO.File]::WriteAllText((Join-Path $backup 'ЯК-ВІДНОВИТИ.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    return $backup
}

function Main {
    Write-Host '=== Очищення історії USB-флешок та портативних пристроїв ===' -ForegroundColor Cyan
    Write-Host ''

    # --- Windows version check ---
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -lt 19041) {
        Write-Host "Ця версія Windows (збірка $build) не вміє видаляти пристрої вбудованими засобами." -ForegroundColor Red
        Write-Host 'Потрібна Windows 10 версії 2004 або новіша чи Windows 11.' -ForegroundColor Red
        return
    }

    Write-Host 'Пошук слідів...' -ForegroundColor Cyan

    # --- Devices ---
    $all = @(Get-PnpDevice)
    $presentKeys = @($all | Where-Object { $_.Present -and $_.InstanceId -like 'USBSTOR\*' } |
        ForEach-Object { ($_.InstanceId -replace '\\', '#').ToUpper() })

    $disks = @($all | Where-Object { -not $_.Present -and $_.InstanceId -like 'USBSTOR\*' })
    $vols  = @($all | Where-Object {
        -not $_.Present -and (
            $_.InstanceId -like 'STORAGE\VOLUME\*USBSTOR#*' -or
            $_.InstanceId -like 'SWD\WPDBUSENUM\*USBSTOR#*')
    })

    # USB port records ("USB Mass Storage Device") that belong to those flash drives
    $parents = @()
    foreach ($d in $disks) {
        $p = $null
        foreach ($kn in 'DEVPKEY_Device_Parent', 'DEVPKEY_Device_LastKnownParent') {
            $v = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $kn).Data
            if ($v) { $p = [string]$v; break }
        }
        if (-not $p -or $p -notlike 'USB\*') { continue }
        $pd = $all | Where-Object { $_.InstanceId -eq $p } | Select-Object -First 1
        if (-not $pd -or $pd.Present) { continue }
        $svc = (Get-PnpDeviceProperty -InstanceId $p -KeyName 'DEVPKEY_Device_Service').Data
        if ($svc -eq 'USBSTOR') { $parents += $pd }
    }
    $parents = @($parents | Sort-Object InstanceId -Unique)
    $parentKeys = @($parents | ForEach-Object { ($_.InstanceId -replace '\\', '#').ToUpper() })

    # Other portable devices (phones, cameras, players): WPD class, NOT flash drives.
    # Flash volumes are handled above, so exclude anything USBSTOR-backed here.
    $wpdClassGuid = '{eec5ad98-8080-425f-922a-dabf3de3f69a}'
    $wpd = @($all | Where-Object {
        -not $_.Present -and
        $_.ClassGuid -eq $wpdClassGuid -and
        $_.InstanceId.ToUpper() -notlike '*USBSTOR#*'
    })
    # Tokens that identify those devices inside registry subkey names / log sections.
    $wpdKeysId = @($wpd | ForEach-Object { ($_.InstanceId -replace '\\', '#').ToUpper() })
    foreach ($d in $wpd) {
        $pp = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LastKnownParent').Data
        if ($pp) { $wpdKeysId += ($pp -replace '\\', '#').ToUpper() }
    }
    $wpdKeysId = @($wpdKeysId | Sort-Object -Unique)

    # --- Registry ---
    $HKLM = [Microsoft.Win32.Registry]::LocalMachine
    $HKCU = [Microsoft.Win32.Registry]::CurrentUser
    $mdPath  = 'SYSTEM\MountedDevices'
    $mp2Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
    $wpdPath = 'SOFTWARE\Microsoft\Windows Portable Devices\Devices'
    $emdPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\EMDMgmt'

    $mdValues = @(); $volGuids = @()
    $md = Get-Key $HKLM $mdPath
    if ($md) {
        foreach ($n in $md.GetValueNames()) {
            $b = $md.GetValue($n)
            if ($b -is [byte[]] -and $b.Length -gt 24) {
                $s = [Text.Encoding]::Unicode.GetString($b)
                if (Test-FlashText $s $presentKeys @()) {
                    $mdValues += $n
                    if ($n -match '^\\\?\?\\Volume(\{[0-9A-Fa-f-]+\})$') { $volGuids += $Matches[1].ToUpper() }
                }
            }
        }
        $md.Close()
    }

    $mp2Keys = @()
    $mp2 = Get-Key $HKCU $mp2Path
    if ($mp2) {
        $mp2Keys = @($mp2.GetSubKeyNames() | Where-Object { $volGuids -contains $_.ToUpper() })
        $mp2.Close()
    }

    $wpdKeys = @(Find-SubKeys $HKLM $wpdPath $presentKeys)
    $emdKeys = @(Find-SubKeys $HKLM $emdPath $presentKeys)

    # Windows Portable Devices name cache + MountPoints2 entries for the WPD devices.
    $wpdNameKeys = @(Find-SubKeysByTokens $HKLM $wpdPath $wpdKeysId)
    $wpdMp2Keys = @()
    $mp2b = Get-Key $HKCU $mp2Path
    if ($mp2b) {
        $wpdMp2Keys = @($mp2b.GetSubKeyNames() | Where-Object { Test-HasToken $_ $wpdKeysId })
        $mp2b.Close()
    }

    # --- setupapi logs ---
    $logs = @(Get-ChildItem -Path (Join-Path $env:WINDIR 'INF') -Filter 'setupapi.dev*.log' -File)
    $logHits = 0
    foreach ($f in $logs) { $logHits += Invoke-LogFilter $f.FullName $presentKeys $parentKeys $false }

    # --- Event logs that record device/USB connection history ---
    # These can only be cleared as a whole (single entries can't be removed).
    # With backup (option 1) each is exported first. Main System/Application
    # logs are intentionally NOT touched.
    $evtCandidates = @(
        'Microsoft-Windows-Partition/Diagnostic'
        'Microsoft-Windows-Storage-ClassPnP/Operational'
        'Microsoft-Windows-Kernel-PnP/Configuration'
        'Microsoft-Windows-DriverFrameworks-UserMode/Operational'
    )
    $evtLogs = @()
    foreach ($ln in $evtCandidates) {
        & wevtutil.exe gl "$ln" > $null 2>&1
        if ($LASTEXITCODE -eq 0) { $evtLogs += $ln }
    }

    # --- Preview ---
    $total = $disks.Count + $vols.Count + $parents.Count + $wpd.Count + $mdValues.Count +
             $mp2Keys.Count + $wpdMp2Keys.Count + $wpdKeys.Count + $wpdNameKeys.Count +
             $emdKeys.Count + $logHits + $evtLogs.Count
    Write-Host ''
    if ($presentKeys.Count -gt 0) {
        Write-Host "Підключені зараз флешки ($($presentKeys.Count)) не чіпаються." -ForegroundColor DarkGray
    }
    if ($total -eq 0) {
        Write-Host 'Слідів відключених пристроїв не знайдено. Нічого видаляти.' -ForegroundColor Green
        return
    }

    Write-Host "Відключені флешки: $($disks.Count)" -ForegroundColor Yellow
    foreach ($d in $disks) {
        $name = $d.FriendlyName
        if (-not $name) { $name = $d.InstanceId }
        Write-Host "  - $name"
    }
    Write-Host ''
    Write-Host "Інші портативні пристрої (телефони, камери, плеєри): $($wpd.Count)" -ForegroundColor Yellow
    foreach ($d in $wpd) {
        $name = $d.FriendlyName
        if (-not $name) { $name = $d.InstanceId }
        Write-Host "  - $name"
    }
    Write-Host ''
    Write-Host 'Пов''язані сліди:' -ForegroundColor Yellow
    Write-Host "  Томи флешок:                       $($vols.Count)"
    Write-Host "  Записи USB-портів:                 $($parents.Count)"
    Write-Host "  MountedDevices (літери дисків):    $($mdValues.Count)"
    Write-Host "  MountPoints2 (профіль):            $($mp2Keys.Count + $wpdMp2Keys.Count)"
    Write-Host "  Windows Portable Devices (назви):  $($wpdKeys.Count + $wpdNameKeys.Count)"
    Write-Host "  EMDMgmt (ReadyBoost):              $($emdKeys.Count)"
    Write-Host "  Розділи в setupapi-логах:          $logHits"
    Write-Host ''
    if ($evtLogs.Count -gt 0) {
        Write-Host 'Журнали підключення (буде очищено ПОВНІСТЮ):' -ForegroundColor Yellow
        foreach ($ln in $evtLogs) { Write-Host "  - $ln" }
        Write-Host ''
    }

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

    # --- Backup (option 1 only) ---
    $backup = $null
    if ($doBackup) {
        $regExports = [ordered]@{
            'MountedDevices.reg'         = "HKLM\$mdPath"
            'MountPoints2.reg'           = "HKCU\$mp2Path"
            'WindowsPortableDevices.reg' = "HKLM\$wpdPath"
            'EMDMgmt.reg'                = "HKLM\$emdPath"
        }
        $backup = New-Backup $logs $regExports
        if (-not $backup) {
            Write-Host 'Не вдалося створити папку для резервної копії. Зупиняюсь, нічого не змінено.' -ForegroundColor Red
            return
        }
        Write-Host "Резервну копію збережено: $backup" -ForegroundColor Cyan
        Write-Host 'Інструкція з відновлення: ЯК-ВІДНОВИТИ.txt у цій папці.' -ForegroundColor Cyan
    } else {
        Write-Host 'Режим без резервної копії: зміни будуть НЕЗВОРОТНІ.' -ForegroundColor Red
    }
    Write-Host ''

    # --- 1. Devices ---
    Write-Host '[1/4] Видалення записів пристроїв...' -ForegroundColor Cyan
    $okDev = 0; $failDev = 0
    foreach ($d in @($vols + $disks + $parents + $wpd)) {
        & pnputil.exe /remove-device $d.InstanceId 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) { $okDev++ } else { $failDev++ }
    }

    # --- 2. Registry ---
    Write-Host '[2/4] Очищення реєстру...' -ForegroundColor Cyan
    $okReg = 0; $failReg = 0
    if ($mdValues.Count -gt 0) {
        $k = Get-Key $HKLM $mdPath $true
        if ($k) {
            foreach ($n in $mdValues) { try { $k.DeleteValue($n); $okReg++ } catch { $failReg++ } }
            $k.Close()
        } else { $failReg += $mdValues.Count }
    }
    $targets = @(
        @{ H = $HKCU; P = $mp2Path; N = @($mp2Keys + $wpdMp2Keys | Sort-Object -Unique) },
        @{ H = $HKLM; P = $wpdPath; N = @($wpdKeys + $wpdNameKeys | Sort-Object -Unique) },
        @{ H = $HKLM; P = $emdPath; N = $emdKeys }
    )
    foreach ($t in $targets) {
        if ($t.N.Count -eq 0) { continue }
        $k = Get-Key $t.H $t.P $true
        if (-not $k) { $failReg += $t.N.Count; continue }
        foreach ($n in $t.N) { try { $k.DeleteSubKeyTree($n); $okReg++ } catch { $failReg++ } }
        $k.Close()
    }

    # --- 3. setupapi logs ---
    Write-Host '[3/4] Очищення журналу встановлення пристроїв (setupapi)...' -ForegroundColor Cyan
    $okLog = 0; $failLog = 0
    foreach ($f in $logs) {
        try { $okLog += Invoke-LogFilter $f.FullName $presentKeys $parentKeys $true } catch { $failLog++ }
    }

    # --- 4. Event logs (export when backing up, then clear whole log) ---
    Write-Host '[4/4] Очищення журналів підключення...' -ForegroundColor Cyan
    $okEvt = 0; $failEvt = 0
    $evtDir = $null
    if ($doBackup -and $evtLogs.Count -gt 0) {
        $evtDir = Join-Path $backup 'EventLogs'
        New-Item -ItemType Directory -Path $evtDir -Force | Out-Null
    }
    foreach ($ln in $evtLogs) {
        if ($evtDir) {
            $safe = ($ln -replace '[\\/]', '_')
            & wevtutil.exe epl "$ln" (Join-Path $evtDir "$safe.evtx") '/ow:true' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $failEvt++; continue }
        }
        & wevtutil.exe cl "$ln" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $okEvt++ } else { $failEvt++ }
    }

    # --- Result ---
    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    Write-Host "  Пристроїв видалено:        $okDev"
    Write-Host "  Записів реєстру видалено:  $okReg"
    Write-Host "  Розділів setupapi видалено:$okLog"
    Write-Host "  Журналів очищено:          $okEvt"
    if (($failDev + $failReg + $failLog + $failEvt) -gt 0) {
        Write-Host "  Не вдалося: пристроїв $failDev, реєстру $failReg, setupapi $failLog, журналів $failEvt" -ForegroundColor Yellow
    }
    Write-Host ''
    if ($doBackup) {
        Write-Host 'Якщо щось пішло не так, відкрийте ЯК-ВІДНОВИТИ.txt у папці резервної копії.' -ForegroundColor Yellow
        Write-Host 'Резервна копія містить ті самі сліди, які скрипт прибрав.' -ForegroundColor Yellow
        Write-Host 'Папка лежить у %LOCALAPPDATA% (не синхронізується з хмарою).' -ForegroundColor Yellow
        Write-Host 'Коли переконаєтесь, що все працює, видаліть її:' -ForegroundColor Yellow
        Write-Host "  $backup" -ForegroundColor Yellow
    } else {
        Write-Host 'Резервну копію не створювали - відновити видалене не вийде.' -ForegroundColor Yellow
    }
}

Main
Wait-Key
