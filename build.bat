@echo off
rem Build Scan Tool on Windows using only the Odin toolchain (run from a
rem "x64 Native Tools" prompt, or any prompt where Odin can find the MSVC linker).
rem   build.bat          optimized build -> build\scan_tool.exe
rem   build.bat debug    debug build
rem   build.bat test     run the imaging, app and synthetic-scan unit tests
rem   build.bat check    every check a change must pass on Windows: the debug and
rem                      optimized builds, the tools and the unit tests
cd /d "%~dp0"
if not exist build mkdir build
if "%1"=="debug" (
  odin build src -out:build\scan_tool.exe -debug -vet -strict-style
) else if "%1"=="test" (
  call :test
) else if "%1"=="check" (
  call :check
) else (
  odin build src -out:build\scan_tool.exe -o:speed -vet -strict-style -subsystem:windows
)
exit /b %errorlevel%

:test
odin test src\imaging -vet -strict-style || exit /b 1
odin test src -vet -strict-style || exit /b 1
odin test tools\synth -vet -strict-style -o:speed || exit /b 1
exit /b 0

:check
odin build src -out:build\scan_tool.exe -debug -vet -strict-style || exit /b 1
odin build src -out:build\scan_tool.exe -o:speed -vet -strict-style -subsystem:windows || exit /b 1
for %%t in (tools\synth tools\detect_bench tools\moire_bench) do (
  odin check %%t -vet -strict-style || exit /b 1
)
call :test
exit /b %errorlevel%
