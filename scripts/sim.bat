@echo off
REM =============================================================================
REM DSP-CNN Coprocessor Simulation Runner (Windows Batch)
REM QuestaSim / ModelSim Compatible
REM =============================================================================
REM Usage:
REM   sim.bat                     - Run CIC testbench (default)
REM   sim.bat cic                 - Run CIC testbench
REM   sim.bat fir                 - Run FIR testbench
REM   sim.bat csr                 - Run CSR testbench
REM   sim.bat pe                  - Run CNN PE testbench
REM   sim.bat top                 - Run system top testbench
REM   sim.bat all                 - Run all testbenches (regression)
REM   sim.bat <name> gui          - Run in GUI mode
REM =============================================================================

setlocal enabledelayedexpansion

REM --- Parse arguments ---
set TB=%1
set MODE=%2

if "%TB%"=="" set TB=cic
if "%MODE%"=="" set MODE=batch

REM --- Map short name to testbench module ---
if /i "%TB%"=="cic"  set TB_TOP=tb_filter_cicd
if /i "%TB%"=="fir"  set TB_TOP=tb_filter_fir
if /i "%TB%"=="csr"  set TB_TOP=tb_csr_controller
if /i "%TB%"=="pe"   set TB_TOP=tb_cnn_pe
if /i "%TB%"=="top"  set TB_TOP=tb_dsp_cnn_top
if /i "%TB%"=="all"  goto :run_all

if not defined TB_TOP (
    echo [ERROR] Unknown testbench: %TB%
    echo Usage: sim.bat [cic^|fir^|csr^|pe^|top^|all] [gui]
    exit /b 1
)

REM --- Run single testbench ---
call :run_single %TB_TOP% %MODE%
goto :eof

REM =============================================================================
:run_single
REM Arguments: %1=TB_TOP, %2=MODE
REM =============================================================================
set _TB=%~1
set _MODE=%~2

echo.
echo ============================================
echo   Running: %_TB%
echo   Mode:    %_MODE%
echo ============================================

cd /d "%~dp0"

if /i "%_MODE%"=="gui" (
    vsim -do "set TB_TOP %_TB%; do sim.do"
) else (
    vsim -c -do "set TB_TOP %_TB%; do sim.do" > ..\sim\%_TB%.log 2>&1
    echo   Log: sim\%_TB%.log
    
    REM Check for PASS/FAIL in log
    findstr /c:"ALL TESTS PASSED" ..\sim\%_TB%.log > nul 2>&1
    if !errorlevel! equ 0 (
        echo   Result: PASSED
    ) else (
        echo   Result: FAILED or INCOMPLETE
    )
)

goto :eof

REM =============================================================================
:run_all
REM =============================================================================
echo.
echo ============================================
echo   DSP-CNN Full Regression
echo ============================================

REM Create sim output directory
if not exist "%~dp0..\sim" mkdir "%~dp0..\sim"

set PASS_COUNT=0
set FAIL_COUNT=0

for %%T in (tb_filter_cicd tb_filter_fir tb_csr_controller tb_cnn_pe tb_dsp_cnn_top) do (
    call :run_single %%T batch
    
    findstr /c:"ALL TESTS PASSED" "%~dp0..\sim\%%T.log" > nul 2>&1
    if !errorlevel! equ 0 (
        set /a PASS_COUNT+=1
    ) else (
        set /a FAIL_COUNT+=1
    )
)

echo.
echo ============================================
echo   REGRESSION SUMMARY
echo   Passed: %PASS_COUNT%
echo   Failed: %FAIL_COUNT%
echo ============================================

if %FAIL_COUNT% equ 0 (
    echo   *** ALL REGRESSIONS PASSED ***
) else (
    echo   *** SOME REGRESSIONS FAILED ***
)

goto :eof
