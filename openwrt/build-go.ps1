#Requires -Version 5.1
<#
.SYNOPSIS
    为 OpenWrt / ImmortalWrt 交叉编译锐捷校园网认证客户端。

.DESCRIPTION
    main.go 只用了 Go 标准库，所以 CGO_ENABLED=0 的纯 Go 交叉编译就够了，
    既不需要 OpenWrt 工具链，也不需要 WSL。

    产物写到 openwrt\prebuilt\rjpa-<目标>，供 Makefile 打包成 .ipk。
    编译完会读一下 ELF 头，确认架构真的是你要的那个
    （"编错架构" 是这类包最常见的坑）。

    注意: 本文件必须保存为 UTF-8 with BOM。
    Windows PowerShell 5.1 在没有 BOM 时会按 GBK 读取 .ps1，
    中文会变乱码并导致语法错误。

.EXAMPLE
    .\build-go.ps1 -List

.EXAMPLE
    .\build-go.ps1 -Target mipsle-softfloat

.NOTES
    没有 Go 的话: winget install GoLang.Go
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    [switch]$List
)

$ErrorActionPreference = 'Stop'

$Targets = [ordered]@{
    'amd64'              = @{ GOARCH = 'amd64';     GOMIPS = '';          GOARM = '';  Desc = 'x86_64 软路由 / 虚拟机' }
    '386'                = @{ GOARCH = '386';       GOMIPS = '';          GOARM = '';  Desc = '32 位 x86（很少见）' }
    'arm64'              = @{ GOARCH = 'arm64';     GOMIPS = '';          GOARM = '';  Desc = 'aarch64：filogic / ipq807x / RK 系列' }
    'arm-v7'             = @{ GOARCH = 'arm';       GOMIPS = '';          GOARM = '7'; Desc = '32 位 ARMv7' }
    'arm-v6'             = @{ GOARCH = 'arm';       GOMIPS = '';          GOARM = '6'; Desc = '32 位 ARMv6' }
    'arm-v5'             = @{ GOARCH = 'arm';       GOMIPS = '';          GOARM = '5'; Desc = '32 位 ARMv5' }
    'mipsle-softfloat'   = @{ GOARCH = 'mipsle';    GOMIPS = 'softfloat'; GOARM = '';  Desc = '小端 MIPS：mt7620 / mt7621 / mt7628' }
    'mips-softfloat'     = @{ GOARCH = 'mips';      GOMIPS = 'softfloat'; GOARM = '';  Desc = '大端 MIPS（少见）' }
    'mips64le-softfloat' = @{ GOARCH = 'mips64le';  GOMIPS = 'softfloat'; GOARM = '';  Desc = '64 位小端 MIPS：mt7622' }
    'mips64-softfloat'   = @{ GOARCH = 'mips64';    GOMIPS = 'softfloat'; GOARM = '';  Desc = '大端 MIPS 64 位' }
    'riscv64'            = @{ GOARCH = 'riscv64';   GOMIPS = '';          GOARM = '';  Desc = 'RISC-V 64' }
}

function Show-Targets {
    Write-Host ''
    Write-Host '可选目标（-Target 的值）:' -ForegroundColor Cyan
    Write-Host ''
    foreach ($k in $Targets.Keys) {
        Write-Host ('  {0,-21} {1}' -f $k, $Targets[$k].Desc)
    }
    Write-Host ''
    Write-Host '用法:  .\build-go.ps1 -Target <目标>'
    Write-Host ''
}

function Get-ElfInfo {
    param([string]$Path)

    $read = 0
    $hdr = New-Object byte[] 20

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $read = $fs.Read($hdr, 0, 20)
    }
    finally {
        $fs.Close()
    }

    if ($read -lt 20) { return $null }
    if ($hdr[0] -ne 0x7F -or $hdr[1] -ne 0x45 -or $hdr[2] -ne 0x4C -or $hdr[3] -ne 0x46) {
        return $null
    }

    $little = $false
    if ($hdr[5] -eq 1) { $little = $true }

    $bits = 32
    if ($hdr[4] -eq 2) { $bits = 64 }

    if ($little) {
        $machine = $hdr[18] + ($hdr[19] -shl 8)
    }
    else {
        $machine = ($hdr[18] -shl 8) + $hdr[19]
    }

    $names = @{
        3   = 'x86'
        8   = 'MIPS'
        20  = 'PowerPC'
        40  = 'ARM'
        62  = 'x86-64'
        183 = 'AArch64'
        243 = 'RISC-V'
    }

    $name = "未知($machine)"
    if ($names.ContainsKey($machine)) { $name = $names[$machine] }

    $endian = '大端'
    if ($little) { $endian = '小端' }

    return ('ELF {0} 位, {1} 字节序, 架构 {2}' -f $bits, $endian, $name)
}

# ------------------------------------------------------------------ 参数检查

if ($List -or [string]::IsNullOrWhiteSpace($Target)) {
    Show-Targets
    return
}

if (-not $Targets.Contains($Target)) {
    Write-Host ''
    Write-Host "不认识的目标: $Target" -ForegroundColor Red
    Show-Targets
    return
}

$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
    Write-Host ''
    Write-Host '找不到 go 命令。请先安装 Go:' -ForegroundColor Red
    Write-Host '    winget install GoLang.Go'
    Write-Host '    或从 https://go.dev/dl/ 下载安装'
    Write-Host ''
    return
}

$cfg      = $Targets[$Target]
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Source   = Join-Path $RepoRoot 'main.go'
$OutDir   = Join-Path $PSScriptRoot 'prebuilt'
$OutFile  = Join-Path $OutDir "rjpa-$Target"

if (-not (Test-Path $Source)) {
    Write-Host "找不到源文件: $Source" -ForegroundColor Red
    return
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$archDesc = "linux/$($cfg.GOARCH)"
if ($cfg.GOMIPS) { $archDesc = "$archDesc GOMIPS=$($cfg.GOMIPS)" }
if ($cfg.GOARM)  { $archDesc = "$archDesc GOARM=$($cfg.GOARM)" }

Write-Host ''
Write-Host "目标      : $Target  ($($cfg.Desc))"
Write-Host "GOOS/ARCH : $archDesc"
Write-Host "输出      : $OutFile"
Write-Host ''

# 环境变量在本进程里改，退出前一定要还原，否则会污染当前会话
$saved = @{}
foreach ($n in 'GOOS', 'GOARCH', 'GOMIPS', 'GOARM', 'CGO_ENABLED') {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
}

$code = 1

try {
    [Environment]::SetEnvironmentVariable('CGO_ENABLED', '0', 'Process')
    [Environment]::SetEnvironmentVariable('GOOS', 'linux', 'Process')
    [Environment]::SetEnvironmentVariable('GOARCH', $cfg.GOARCH, 'Process')

    $gomips = $null
    if ($cfg.GOMIPS) { $gomips = $cfg.GOMIPS }
    [Environment]::SetEnvironmentVariable('GOMIPS', $gomips, 'Process')

    $goarm = $null
    if ($cfg.GOARM) { $goarm = $cfg.GOARM }
    [Environment]::SetEnvironmentVariable('GOARM', $goarm, 'Process')

    Push-Location $RepoRoot
    try {
        # main.go 是单个文件、无 go.mod，go build 直接按文件参数编译即可
        & go build -trimpath -ldflags '-s -w' -o $OutFile main.go
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($n in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process')
    }
}

if ($code -ne 0 -or -not (Test-Path $OutFile)) {
    Write-Host "go build 失败 (exit $code)" -ForegroundColor Red
    return
}

# ------------------------------------------------------------------ 结果校验

$item = Get-Item $OutFile
$elf  = Get-ElfInfo -Path $OutFile

Write-Host '编译完成' -ForegroundColor Green
Write-Host ('  文件大小 : {0:N0} KB' -f ($item.Length / 1KB))
if ($elf) {
    Write-Host "  格式校验 : $elf"
}
else {
    Write-Host '  格式校验 : 不是 ELF 文件，请检查编译参数！' -ForegroundColor Red
}

Write-Host ''
Write-Host '下一步（在 WSL 里用 SDK 打包）:'
Write-Host '  ./build-ipk.sh <SDK目录>'
Write-Host ''
