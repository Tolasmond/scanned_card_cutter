@echo off
rem Build Scan Tool on Windows using only the Odin toolchain (run from a
rem "x64 Native Tools" prompt, or any prompt where Odin can find the MSVC linker).
rem   build.bat          optimized build -> build\scan_tool.exe
rem   build.bat debug    debug build
rem   build.bat test     run the imaging unit tests
cd /d "%~dp0"
if not exist build mkdir build
if "%1"=="debug" (
  odin build src -out:build\scan_tool.exe -debug -vet -strict-style
) else if "%1"=="test" (
  odin test src\imaging -vet -strict-style
) else (
  odin build src -out:build\scan_tool.exe -o:speed -vet -strict-style -subsystem:windows
)
