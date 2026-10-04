@echo off
rem PlanetForge emergency reset -- ASCII only on purpose (cmd.exe reads this with the console code page).
rem
rem   Double click this file when the mod looks stuck (for example after a mission, when the captured
rem   mission-row templates seem to be stale). It writes a trigger file; the addon notices it within a
rem   second or two and clears everything it captured:
rem
rem     state.templates          the per-faction template copies
rem     state.unlock_rows        the mission rows it wrote
rem     state.unlock_snapshots   the record bytes from before it touched them
rem     state.cleared_rows       rows it invalidated for other targets
rem
rem   Nothing else is touched: the cfg file, your planets and the game data stay as they are. After it
rem   fires, look at %LOCALAPPDATA%\PlanetForge.log for the line
rem     "UNLOCK templates cleared by emergency reset"
rem   and then visit the source planet again (215 / 262 / 224) so a fresh template gets captured.
setlocal
echo ============================================
echo   PlanetForge - emergency template reset
echo ============================================
echo.
echo Triggering the in-game reset...
type nul > "%LOCALAPPDATA%\PlanetForge.reset"
if errorlevel 1 (
  echo FAILED to write "%LOCALAPPDATA%\PlanetForge.reset"
  echo Check that the path exists and is writable.
) else (
  echo Done. The addon clears its captured templates within a second or two.
  echo Confirm in %%LOCALAPPDATA%%\PlanetForge.log - look for:
  echo   UNLOCK templates cleared by emergency reset
)
echo.
pause
endlocal
