@echo off
wpeinit

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

echo === Staging unattend.xml in Panther ===
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
copy /Y X:\autounattend.xml W:\Windows\Panther\unattend.xml
if errorlevel 1 goto failed

echo === Done; rebooting ===
wpeutil reboot
exit /b 0

:failed
echo *** WinPE install script failed ***
pause
exit /b 1
