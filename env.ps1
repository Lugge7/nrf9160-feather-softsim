# Dot-source this to get west/nrfutil/arm-zephyr-eabi-gcc on PATH:
#     . .\env.ps1
#
# Mirrors C:\ncs\toolchains\dcbdc366a1\environment.json.

$NcsToolchain = 'C:\ncs\toolchains\dcbdc366a1'
$NcsWorkspace = 'C:\ncs\v3.4.0'

if (-not (Test-Path $NcsToolchain)) { throw "Toolchain not found: $NcsToolchain" }
if (-not (Test-Path $NcsWorkspace)) { throw "NCS workspace not found: $NcsWorkspace" }

$toolchainPaths = @(
    "$NcsToolchain",
    "$NcsToolchain\mingw64\bin",
    "$NcsToolchain\bin",
    "$NcsToolchain\opt\bin",
    "$NcsToolchain\opt\bin\Scripts",
    "$NcsToolchain\opt\nanopb\generator-bin",
    "$NcsToolchain\nrfutil\bin",
    "$NcsToolchain\opt\zephyr-sdk\gnu\arm-zephyr-eabi\bin",
    "$NcsToolchain\opt\zephyr-sdk\gnu\riscv64-zephyr-elf\bin"
)

# Prepend, but don't stack duplicates if this is dot-sourced twice.
$existing = ($env:PATH -split ';') | Where-Object { $_ -and ($toolchainPaths -notcontains $_) }
$env:PATH = (($toolchainPaths + $existing) -join ';')

$env:PYTHONPATH            = "$NcsToolchain\opt\bin;$NcsToolchain\opt\bin\Lib;$NcsToolchain\opt\bin\Lib\site-packages"
$env:NRFUTIL_HOME          = "$NcsToolchain\nrfutil\home"
$env:ZEPHYR_TOOLCHAIN_VARIANT = 'zephyr'
$env:ZEPHYR_SDK_INSTALL_DIR = "$NcsToolchain\opt\zephyr-sdk"
$env:ZEPHYR_BASE           = "$NcsWorkspace\zephyr"

Write-Host "NCS env ready: west $((west --version) -replace 'West version: ','') | ZEPHYR_BASE=$env:ZEPHYR_BASE"
