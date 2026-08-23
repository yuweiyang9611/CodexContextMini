@echo off
setlocal
set "APP=%~dp0.artifacts\publish\win-x64\ContextMini.exe"
if not exist "%APP%" (
  echo Context Mini has not been published yet.
  echo Run publish.cmd first.
  exit /b 1
)
"%APP%" "%CD%"