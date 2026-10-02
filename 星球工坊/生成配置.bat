@echo off
rem PlanetForge config installer -- ASCII only on purpose (cmd.exe reads this with the console code page).
rem
rem   double click            -> install the newest planetforge.cfg found in Downloads or here,
rem                              and if there is none, write the default recipe
rem   drag a .json onto it    -> install that recipe
rem   drag a .cfg  onto it    -> just place that config file
rem
rem The script finds the config the addon actually reads (%%APPDATA%%\Arrowhead\Helldivers2\planetforge.cfg,
rem falling back to %%APPDATA%% then %%LOCALAPPDATA%%) and backs up whatever was there first. That is
rem what makes the generator's "download planetforge.cfg" enough: double click this and it is applied.
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   PlanetForge - config generator / installer
echo ============================================
echo.
if not "%~1"=="" goto given
set "FOUND="
if exist "%~dp0planetforge.cfg" set "FOUND=%~dp0planetforge.cfg"
if not defined FOUND if exist "%USERPROFILE%\Downloads\planetforge.cfg" set "FOUND=%USERPROFILE%\Downloads\planetforge.cfg"
if not defined FOUND if exist "%USERPROFILE%\Downloads\planetforge (1).cfg" set "FOUND=%USERPROFILE%\Downloads\planetforge (1).cfg"
if defined FOUND goto fromfile
echo No planetforge.cfg next to this script or in Downloads - installing the default recipe.
echo (In the generator, click "download planetforge.cfg" first and then run this again to install yours.)
echo.
python tools\cfg_gen.py --install
goto done
:fromfile
echo Using the config found at:
echo   !FOUND!
echo.
python tools\cfg_gen.py --install-file "!FOUND!"
goto done
:given
echo Input: %~1
echo %~x1 | findstr /i "^\.json$" >nul
if errorlevel 1 goto cfgfile
python tools\cfg_gen.py --install --spec "%~1"
goto done
:cfgfile
python tools\cfg_gen.py --install-file "%~1"
goto done
:done
echo.
echo Finished. The game reloads the config about 2 seconds later.
echo.
pause
endlocal
