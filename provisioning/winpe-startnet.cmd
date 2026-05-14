@echo off
wpeinit

echo === Probing for existing install (idempotency guard) ===
diskpart /s X:\probe.txt >nul 2>&1
if exist W:\Windows\System32\ntoskrnl.exe (
    echo Existing Windows install detected on partition 3 - skipping reinstall
    echo Shutting down so host can relaunch without install media
    wpeutil shutdown /t:0
    exit /b 0
)

echo === Partitioning disk ===
diskpart /s X:\diskpart.txt
if errorlevel 1 goto failed

echo === Locating install.wim ===
for %%d in (D E F G H I) do if exist %%d:\sources\install.wim set INSTALL_WIM=%%d:\sources\install.wim
if not defined INSTALL_WIM (
    echo install.wim not found on any drive
    goto failed
)
echo Found: %INSTALL_WIM%

echo === Applying install.wim index 1 to W: ===
dism /apply-image /imagefile:%INSTALL_WIM% /index:1 /applydir:W:\
if errorlevel 1 goto failed

echo === Writing bootloader to S: ===
W:\Windows\System32\bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 goto failed

echo === Mirroring bootloader to EFI fallback path ===
if not exist S:\EFI\BOOT mkdir S:\EFI\BOOT
copy /Y S:\EFI\Microsoft\Boot\bootmgfw.efi S:\EFI\BOOT\BOOTX64.EFI
if errorlevel 1 goto failed

echo === Staging unattend.xml in Panther ===
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
copy /Y X:\autounattend.xml W:\Windows\Panther\unattend.xml
if errorlevel 1 goto failed

echo === Done; shutting down so host can relaunch without install media ===
wpeutil shutdown /t:0
exit /b 0

:failed
echo *** WinPE install script failed ***
wpeutil shutdown /t:0
exit /b 1
