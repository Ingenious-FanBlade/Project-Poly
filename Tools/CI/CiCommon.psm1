# 构建与测试脚本的公共函数：运行 ID、记录读写、Git 与 Unity 版本信息。
# 记录字段遵循 Docs/TDD/构建与测试.md 第 4 节的数据模型。

Set-StrictMode -Version Latest

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 唯一随包场景与两份受版本控制的 Build Profile（构建与测试 TDD 第 2、4 节）。
$BattleSliceScenePath = 'Assets/Scenes/BattleSlice.unity'
$BattleSliceBuildProfiles = [ordered]@{
    Development = [pscustomobject]@{
        profileId          = 'BattleSlice-Dev'
        path               = 'Assets/Settings/Build Profiles/BattleSlice-Dev.asset'
        development        = 1
        scriptingBackend   = 'Mono'
        playerVariation    = 'win64_player_development_mono'
    }
    Acceptance  = [pscustomobject]@{
        profileId          = 'BattleSlice-Acceptance'
        path               = 'Assets/Settings/Build Profiles/BattleSlice-Acceptance.asset'
        development        = 0
        scriptingBackend   = 'IL2CPP'
        playerVariation    = 'win64_player_nondevelopment_il2cpp'
    }
}
$RequiredCasesPath = 'Tools/CI/RequiredChecks/battle-slice-v1.json'

function Initialize-CiConsole {
    # 保证 git 输出的中文路径与写出的报告都使用 UTF-8。
    [Console]::OutputEncoding = $script:Utf8NoBom
    $global:OutputEncoding = $script:Utf8NoBom
}

function Get-RepositoryRoot {
    $root = git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0) { throw '当前目录不在 Git 仓库中。' }
    return [System.IO.Path]::GetFullPath($root)
}

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function New-CiRunId {
    param([Parameter(Mandatory)] [string] $Prefix)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$Prefix-$stamp-$suffix"
}

function Get-GitTrackedFiles {
    param([string[]] $PathSpec = @())
    $output = git -c core.quotepath=off ls-files -z -- @PathSpec
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files 执行失败。' }
    return @(($output -join '') -split "`0" | Where-Object { $_ })
}

function Get-ProjectUnityVersion {
    param([Parameter(Mandatory)] [string] $RepositoryRoot)
    $versionFile = Join-Path $RepositoryRoot 'ProjectSettings/ProjectVersion.txt'
    $match = Select-String -LiteralPath $versionFile -Pattern '^m_EditorVersion:\s*(\S+)' | Select-Object -First 1
    if (-not $match) { throw "无法从 $versionFile 读取 Unity 版本。" }
    return $match.Matches[0].Groups[1].Value
}

function Get-CiEnvironment {
    param([Parameter(Mandatory)] [string] $RepositoryRoot)
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    return [ordered]@{
        os                  = $runtime::OSDescription
        architecture        = $runtime::OSArchitecture.ToString()
        projectUnityVersion = Get-ProjectUnityVersion -RepositoryRoot $RepositoryRoot
        runner              = if ($env:GITHUB_ACTIONS -eq 'true') { "$env:RUNNER_ENVIRONMENT/$env:RUNNER_NAME" } else { 'local' }
        workflowRun         = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { $null }
    }
}

function Write-CiJson {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $json = $InputObject | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $script:Utf8NoBom)
}

function Read-CiJson {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 32
}

function Write-CiError {
    param([Parameter(Mandatory)] [string] $Message)
    if ($env:GITHUB_ACTIONS -eq 'true') {
        # GitHub 注解中的换行需要转义。
        $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "::error::$escaped"
    }
    else {
        Write-Host "错误：$Message" -ForegroundColor Red
    }
}

function Add-CiStepSummary {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines)
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

Export-ModuleMember -Function * -Variable BattleSliceScenePath, BattleSliceBuildProfiles, RequiredCasesPath
