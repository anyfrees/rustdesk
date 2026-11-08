@echo off
setlocal
if not defined VSCMD_ARG_TGT_ARCH (
  echo Run this script from an x64 Visual Studio developer command prompt.
  exit /b 1
)
if not "%VSCMD_ARG_TGT_ARCH%"=="x64" exit /b 1
cl /nologo /O2 /GS- /Zl /W4 /LD "%~dp0nnu_win7_rng.c" /Fo"%~dp0nnu_win7_rng.obj" /Fe"%~dp0nnu_win7_rng.dll" /link /NODEFAULTLIB /NOENTRY /SUBSYSTEM:WINDOWS,6.01 bcrypt.lib
exit /b %errorlevel%
