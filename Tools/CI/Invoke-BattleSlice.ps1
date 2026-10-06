#Requires -Version 7.2
<#
.SYNOPSIS
    战斗垂直切片的构建与测试批处理入口，本地开发验证与自托管验收共用。

.DESCRIPTION
    按 Docs/TDD/构建与测试.md 第 5 节分阶段执行，每次只运行一个阶段：
      Snapshot → Precheck → ImportCompile → EditMode → PlayMode → Build → Smoke → Summarize
    记录写入 -OutputRoot：snapshot.json、stages/<阶段>.json、logs/、results/、build/<buildId>/，
    验收模式的汇总写为 acceptance.json。同一次运行的各阶段必须使用同一个 OutputRoot。

    -Mode 只在 Snapshot 阶段生效：Acceptance 要求干净提交并使用 BattleSlice-Acceptance；
    Development 允许本地改动并使用 BattleSlice-Dev，其结果不能计入验收。后续阶段沿用快照中的模式。

    Unity 可执行文件取 -UnityPath、环境变量 UNITY_EDITOR_PATH，或 Unity Hub 的默认安装路径。

.EXAMPLE
    $root = "$env:TEMP/battle-slice/dev-1"
    ./Tools/CI/Invoke-BattleSlice.ps1 -Stage Snapshot -Mode Development -OutputRoot $root
    ./Tools/CI/Invoke-BattleSlice.ps1 -Stage Precheck -OutputRoot $root
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Snapshot', 'Precheck', 'ImportCompile', 'EditMode', 'PlayMode', 'Build', 'Smoke', 'Summarize')]
    [string] $Stage,
    [Parameter(Mandatory)] [string] $OutputRoot,
    [ValidateSet('Development', 'Acceptance')] [string] $Mode = 'Development',
    [string] $UnityPath = $env:UNITY_EDITOR_PATH,
    [string] $ExpectedRevision,
    [int] $UnityTimeoutMinutes = 90,
    [int] $SmokeTimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CiCommon.psm1') -Force
Initialize-CiConsole

# 冒烟协议：玩家程序收到 -battleSliceSmoke 时经正式交互入口自动执行切片流程，
# 把逐步结果写到 -smokeReport 指定的 JSON，并以 0 表示本局通关。
$SmokeConfigPath = 'Tools/CI/battle-slice-smoke.json'
$SmokeRequiredSteps = @(
    'startup',
    'node1.select', 'node1.playCard', 'node1.battleComplete', 'node1.claimReward',
    'node2.select', 'node2.playCard', 'node2.battleComplete', 'node2.claimReward',
    'run.cleared'
)
$AcceptanceStages = @('precheck', 'import-compile', 'editmode', 'playmode', 'build', 'smoke')
$ProductExecutable = 'ProjectPoly.exe'

$repositoryRoot = Get-RepositoryRoot
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$snapshotPath = Join-Path $OutputRoot 'snapshot.json'
$stagesDirectory = Join-Path $OutputRoot 'stages'
$logsDirectory = Join-Path $OutputRoot 'logs'
$resultsDirectory = Join-Path $OutputRoot 'results'
New-Item -ItemType Directory -Force -Path $OutputRoot, $stagesDirectory, $logsDirectory, $resultsDirectory | Out-Null

if ($OutputRoot.StartsWith($repositoryRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputRoot 不能位于仓库内（会改变输入快照）：$OutputRoot"
}

function Get-StageRecordPath([string] $Name) { Join-Path $stagesDirectory "$Name.json" }

function Get-InputFingerprint {
    # 用临时索引把工作区中的 Unity 输入（含未跟踪、未忽略的文件）写成树对象，不改动真实索引。
    $temporaryIndex = Join-Path ([System.IO.Path]::GetTempPath()) "poly-index-$([guid]::NewGuid().ToString('N'))"
    $realIndex = git rev-parse --git-path index
    Copy-Item -LiteralPath $realIndex -Destination $temporaryIndex
    $env:GIT_INDEX_FILE = $temporaryIndex
    try {
        git add -A -- Assets Packages ProjectSettings .gitattributes
        if ($LASTEXITCODE -ne 0) { throw '计算输入指纹时 git add 失败。' }
        $tree = git write-tree
        $parts = foreach ($path in 'Assets', 'Packages', 'ProjectSettings', '.gitattributes') {
            $object = git rev-parse --verify --quiet "${tree}:$path"
            "$path=$object"
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
        return [ordered]@{
            fingerprint = 'sha256:' + [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            inputTree   = $tree
        }
    }
    finally {
        Remove-Item Env:GIT_INDEX_FILE
        Remove-Item -LiteralPath $temporaryIndex -ErrorAction SilentlyContinue
    }
}

function Get-Snapshot {
    $snapshot = Read-CiJson -Path $snapshotPath
    if (-not $snapshot) { throw "尚未固定输入快照，请先运行 -Stage Snapshot：$snapshotPath" }
    return $snapshot
}

function Assert-InputUnchanged($Snapshot) {
    $current = Get-InputFingerprint
    if ($current.fingerprint -ne $Snapshot.inputFingerprint) {
        $status = git -c core.quotepath=off status --porcelain=v1 --untracked-files=all
        return "项目输入在执行期间发生变化，快照 $($Snapshot.snapshotId) 失效，需重新捕获：`n$($status -join "`n")"
    }
    return $null
}

function Resolve-UnityExecutable {
    $candidate = $UnityPath
    if (-not $candidate) {
        $version = Get-ProjectUnityVersion -RepositoryRoot $repositoryRoot
        $candidate = Join-Path $env:ProgramFiles "Unity/Hub/Editor/$version/Editor/Unity.exe"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "找不到 Unity 可执行文件：$candidate" }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Invoke-Unity([string[]] $Arguments, [string] $LogPath, [int] $TimeoutMinutes) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Resolve-UnityExecutable))
    foreach ($argument in @('-batchmode', '-projectPath', $repositoryRoot) + $Arguments + @('-logFile', $LogPath)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    Write-Host "Unity $($startInfo.ArgumentList -join ' ')"
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        $process.Kill($true)
        return [ordered]@{ exitCode = $null; timedOut = $true }
    }
    return [ordered]@{ exitCode = $process.ExitCode; timedOut = $false }
}

function Get-ProfileArguments($Snapshot) { @('-activeBuildProfile', $Snapshot.profilePath) }

function New-StageRecord($Snapshot, [string] $Prefix, [string] $CaseId, [string] $StartedAt) {
    return [ordered]@{
        runId       = New-CiRunId $Prefix
        caseId      = $CaseId
        snapshotId  = $Snapshot.snapshotId
        profileId   = $Snapshot.profileId
        environment = Get-CiEnvironment -RepositoryRoot $repositoryRoot
        startedAt   = $StartedAt
        finishedAt  = $null
        status      = 'running'
        failures    = @()
    }
}

function Complete-StageRecord($Record, [string] $Name, [string[]] $Failures, [string] $PassedStatus = 'passed', [string] $FailedStatus = 'failed') {
    $Failures = @($Failures | Where-Object { $_ })
    $Record.failures = $Failures
    $Record.finishedAt = Get-UtcTimestamp
    if ($Record.status -eq 'running') { $Record.status = if ($Failures.Count -eq 0) { $PassedStatus } else { $FailedStatus } }
    $path = Get-StageRecordPath $Name
    Write-CiJson -InputObject $Record -Path $path
    foreach ($failure in $Failures) { Write-CiError "[$Name] $failure" }
    Write-Host "阶段 $Name：$($Record.status)。记录：$path"
    if ($Record.status -notin 'passed', 'succeeded') { exit 1 }
}

function Test-InteractiveSession {
    return [Environment]::UserInteractive -and (Get-Process -Id $PID).SessionId -ne 0
}

Push-Location $repositoryRoot
try {
    switch ($Stage) {
        'Snapshot' {
            if (Test-Path -LiteralPath $snapshotPath) { throw "快照已存在且不可变；新一轮运行请使用新的 OutputRoot：$snapshotPath" }
            $revision = git rev-parse HEAD
            if ($ExpectedRevision -and $revision -ne $ExpectedRevision) {
                throw "检出提交 $revision 与触发提交 $ExpectedRevision 不一致。"
            }
            $status = @(git -c core.quotepath=off status --porcelain=v1 --untracked-files=all)
            $hasLocalChanges = $status.Count -gt 0
            if ($Mode -eq 'Acceptance' -and $hasLocalChanges) {
                throw "验收须使用干净提交，工作区存在改动：`n$($status -join "`n")"
            }
            $buildProfile = $BattleSliceBuildProfiles[$Mode]
            $fingerprint = Get-InputFingerprint
            $localChangesRef = $null
            if ($hasLocalChanges) {
                # 补丁覆盖已跟踪文件；inputTree 还包含未跟踪文件，可用 git checkout <tree> 重建输入。
                $patchPath = Join-Path $OutputRoot 'local-changes.patch'
                git diff HEAD --binary "--output=$patchPath"
                $localChangesRef = [ordered]@{ patch = $patchPath; inputTree = $fingerprint.inputTree; status = $status }
            }
            $snapshot = [ordered]@{
                snapshotId       = New-CiRunId 'snap'
                mode             = $Mode
                revision         = $revision
                hasLocalChanges  = $hasLocalChanges
                inputFingerprint = $fingerprint.fingerprint
                localChangesRef  = $localChangesRef
                profileId        = $buildProfile.profileId
                profilePath      = $buildProfile.path
                scriptingBackend = $buildProfile.scriptingBackend
                playerVariation  = $buildProfile.playerVariation
                unityVersion     = Get-ProjectUnityVersion -RepositoryRoot $repositoryRoot
                checkSet         = [ordered]@{
                    version = (Read-CiJson -Path $RequiredCasesPath).checkSetVersion
                    path    = $RequiredCasesPath
                    sha256  = (Get-FileHash -LiteralPath $RequiredCasesPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                capturedAt       = Get-UtcTimestamp
            }
            Write-CiJson -InputObject $snapshot -Path $snapshotPath
            Write-Host "已固定输入快照 $($snapshot.snapshotId)（$Mode，$($buildProfile.profileId)，本地改动：$hasLocalChanges）。"
        }

        'Precheck' {
            $snapshot = Get-Snapshot
            $record = New-StageRecord $snapshot 'precheck' 'BS-01/precheck' (Get-UtcTimestamp)
            $failures = [System.Collections.Generic.List[string]]::new()
            $failures.Add((Assert-InputUnchanged $snapshot))

            try {
                $unity = Resolve-UnityExecutable
                $actualVersion = (Get-Item -LiteralPath $unity).VersionInfo.ProductVersion
                $record.unityExecutable = $unity
                $record.unityProductVersion = $actualVersion
                if (-not $actualVersion -or $actualVersion.Split('_')[0] -ne $snapshot.unityVersion) {
                    $failures.Add("Unity 版本不匹配：项目要求 $($snapshot.unityVersion)，实际为 $actualVersion。")
                }
                $variation = Join-Path (Split-Path -Parent $unity) "Data/PlaybackEngines/windowsstandalonesupport/Variations/$($snapshot.playerVariation)"
                if (-not (Test-Path -LiteralPath $variation)) {
                    $failures.Add("缺少 Windows 构建模块 $($snapshot.playerVariation)（$($snapshot.scriptingBackend)）：$variation")
                }
            }
            catch { $failures.Add($_.Exception.Message) }

            if ($snapshot.scriptingBackend -eq 'IL2CPP') {
                $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
                $vcTools = if (Test-Path -LiteralPath $vswhere) {
                    & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
                }
                if (-not $vcTools) { $failures.Add('未找到 IL2CPP 所需的 MSVC x64 工具链（Visual Studio「使用 C++ 的桌面开发」）。') }
            }
            if ($snapshot.mode -eq 'Acceptance' -and -not (Test-InteractiveSession)) {
                $failures.Add('当前不是已登录用户的交互式桌面会话，无法执行玩家程序冒烟。')
            }

            $repositoryReport = Join-Path $stagesDirectory 'precheck-repository.json'
            & (Join-Path $PSScriptRoot 'Test-RepositoryInputs.ps1') -OutputPath $repositoryReport -CheckBuildProfiles -SnapshotId $snapshot.snapshotId
            if ($LASTEXITCODE -ne 0) { $failures.Add("仓库输入检查未通过，详见 $repositoryReport") }
            $record.reportRef = $repositoryReport
            Complete-StageRecord $record 'precheck' $failures
        }

        'ImportCompile' {
            $snapshot = Get-Snapshot
            $record = New-StageRecord $snapshot 'import' 'BS-01/import-compile' (Get-UtcTimestamp)
            $failures = [System.Collections.Generic.List[string]]::new()
            $failures.Add((Assert-InputUnchanged $snapshot))
            $logPath = Join-Path $logsDirectory 'import-compile.log'
            $run = Invoke-Unity -Arguments ((Get-ProfileArguments $snapshot) + '-quit') -LogPath $logPath -TimeoutMinutes $UnityTimeoutMinutes
            $record.logRef = $logPath
            $record.exitCode = $run.exitCode
            if ($run.timedOut) { $record.status = 'aborted'; $failures.Add("导入与编译超过 $UnityTimeoutMinutes 分钟，已中止。") }
            elseif ($run.exitCode -ne 0) { $failures.Add("Unity 以退出码 $($run.exitCode) 结束。") }
            if (Test-Path -LiteralPath $logPath) {
                $errors = @(Select-String -LiteralPath $logPath -Pattern 'error CS\d{4}' | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique)
                $record.compilerErrors = @($errors | Select-Object -First 50)
                $record.compilerWarningCount = @(Select-String -LiteralPath $logPath -Pattern 'warning CS\d{4}').Count
                if ($errors.Count -gt 0) { $failures.Add("编译错误 $($errors.Count) 条，首条：$($errors[0])") }
            }
            else { $failures.Add("未生成 Unity 日志：$logPath") }
            $failures.Add((Assert-InputUnchanged $snapshot))
            Complete-StageRecord $record 'import-compile' $failures
        }

        { $_ -in 'EditMode', 'PlayMode' } {
            $snapshot = Get-Snapshot
            $name = $Stage.ToLowerInvariant()
            $startedAt = Get-UtcTimestamp
            $preFailure = Assert-InputUnchanged $snapshot
            $resultsPath = Join-Path $resultsDirectory "$name-results.xml"
            $logPath = Join-Path $logsDirectory "$name.log"
            # 运行测试时不附加 -quit，由 Test Framework 在结束后退出。
            $run = Invoke-Unity -Arguments ((Get-ProfileArguments $snapshot) + @('-runTests', '-testPlatform', $Stage, '-testResults', $resultsPath)) -LogPath $logPath -TimeoutMinutes $UnityTimeoutMinutes

            $recordPath = Get-StageRecordPath $name
            & (Join-Path $PSScriptRoot 'Test-UnityTestResults.ps1') -ResultsPath $resultsPath -RequiredCasesPath $RequiredCasesPath `
                -TestPlatform $Stage -OutputPath $recordPath -SnapshotId $snapshot.snapshotId -Label "$Stage 测试"
            $record = [ordered]@{}
            (Read-CiJson -Path $recordPath).PSObject.Properties | ForEach-Object { $record[$_.Name] = $_.Value }
            $record.profileId = $snapshot.profileId
            $record.startedAt = $startedAt
            $record.logRef = $logPath
            $record.exitCode = $run.exitCode
            # 结果核对的结论与进程状态合并后重新判定，超时记为中止。
            $record.status = if ($run.timedOut) { 'aborted' } else { 'running' }
            $failures = [System.Collections.Generic.List[string]]::new([string[]] @($record.failures))
            $failures.Add($preFailure)
            if ($run.timedOut) { $failures.Add("$Stage 测试超过 $UnityTimeoutMinutes 分钟，已中止。") }
            elseif ($run.exitCode -notin 0, 2) { $failures.Add("Unity 测试进程异常退出，退出码 $($run.exitCode)。") }
            $failures.Add((Assert-InputUnchanged $snapshot))
            Complete-StageRecord $record $name $failures
        }

        'Build' {
            $snapshot = Get-Snapshot
            foreach ($required in 'precheck', 'import-compile', 'editmode', 'playmode') {
                $previous = Read-CiJson -Path (Get-StageRecordPath $required)
                if (-not $previous -or $previous.status -ne 'passed' -or $previous.snapshotId -ne $snapshot.snapshotId) {
                    throw "前置阶段 $required 未在快照 $($snapshot.snapshotId) 上通过，不能构建。"
                }
            }
            $buildId = New-CiRunId 'build'
            $record = [ordered]@{
                buildId     = $buildId
                profileId   = $snapshot.profileId
                snapshotId  = $snapshot.snapshotId
                environment = Get-CiEnvironment -RepositoryRoot $repositoryRoot
                startedAt   = Get-UtcTimestamp
                finishedAt  = $null
                status      = 'running'
                failures    = @()
            }
            $failures = [System.Collections.Generic.List[string]]::new()
            $failures.Add((Assert-InputUnchanged $snapshot))
            $buildDirectory = Join-Path $OutputRoot "build/$buildId"
            $executable = Join-Path $buildDirectory $ProductExecutable
            $logPath = Join-Path $logsDirectory 'build.log'
            $run = Invoke-Unity -Arguments ((Get-ProfileArguments $snapshot) + @('-build', $executable, '-quit')) -LogPath $logPath -TimeoutMinutes $UnityTimeoutMinutes
            $record.logRef = $logPath
            $record.exitCode = $run.exitCode
            if ($run.timedOut) { $record.status = 'aborted'; $failures.Add("构建超过 $UnityTimeoutMinutes 分钟，已中止。") }
            elseif ($run.exitCode -ne 0) { $failures.Add("Unity 构建以退出码 $($run.exitCode) 结束。") }
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { $failures.Add("未生成玩家程序：$executable") }
            else {
                # 产物结构核对脚本后端：IL2CPP 生成 GameAssembly.dll，Mono 带 MonoBleedingEdge。
                $hasIl2Cpp = Test-Path -LiteralPath (Join-Path $buildDirectory 'GameAssembly.dll')
                $hasMono = Test-Path -LiteralPath (Join-Path $buildDirectory 'MonoBleedingEdge')
                if ($snapshot.scriptingBackend -eq 'IL2CPP' -and (-not $hasIl2Cpp -or $hasMono)) { $failures.Add('产物不是 IL2CPP 构建。') }
                if ($snapshot.scriptingBackend -eq 'Mono' -and -not $hasMono) { $failures.Add('产物不是 Mono 构建。') }
                $record.artifactRef = $buildDirectory
            }
            $failures.Add((Assert-InputUnchanged $snapshot))
            Complete-StageRecord $record 'build' $failures -PassedStatus 'succeeded'
        }

        'Smoke' {
            $snapshot = Get-Snapshot
            $build = Read-CiJson -Path (Get-StageRecordPath 'build')
            if (-not $build -or $build.status -ne 'succeeded' -or $build.snapshotId -ne $snapshot.snapshotId) {
                throw "快照 $($snapshot.snapshotId) 没有成功的构建记录，不能冒烟。"
            }
            $record = New-StageRecord $snapshot 'smoke' 'BS-10/player-smoke' (Get-UtcTimestamp)
            $record.buildId = $build.buildId
            $failures = [System.Collections.Generic.List[string]]::new()
            $smokeConfig = Read-CiJson -Path $SmokeConfigPath

            if (-not $smokeConfig -or -not $smokeConfig.sliceConfigId -or $null -eq $smokeConfig.seed) {
                $failures.Add("切片配置与随机种子尚未确定（$SmokeConfigPath 不存在或缺少 sliceConfigId/seed），冒烟无法执行。")
            }
            elseif (-not (Test-InteractiveSession)) {
                $failures.Add('当前不是已登录用户的交互式桌面会话，无法执行真实窗口冒烟。')
            }
            else {
                $record.sliceConfigId = $smokeConfig.sliceConfigId
                $record.seed = $smokeConfig.seed
                $reportPath = Join-Path $resultsDirectory 'smoke-report.json'
                $playerLog = Join-Path $logsDirectory 'player-smoke.log'
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $build.artifactRef $ProductExecutable))
                foreach ($argument in '-battleSliceSmoke', '-smokeSliceConfig', $smokeConfig.sliceConfigId, '-smokeSeed', "$($smokeConfig.seed)", '-smokeReport', $reportPath, '-logFile', $playerLog) {
                    $startInfo.ArgumentList.Add($argument)
                }
                $startInfo.UseShellExecute = $false
                $process = [System.Diagnostics.Process]::Start($startInfo)
                if (-not $process.WaitForExit($SmokeTimeoutMinutes * 60 * 1000)) {
                    $process.Kill($true)
                    $record.status = 'aborted'
                    $failures.Add("冒烟超过 $SmokeTimeoutMinutes 分钟，已中止。")
                }
                $record.exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
                $record.logRef = $playerLog
                $record.reportRef = $reportPath
                if ($record.exitCode -ne 0) { $failures.Add("玩家程序以退出码 $($record.exitCode) 结束。") }

                $report = Read-CiJson -Path $reportPath
                if (-not $report) { $failures.Add("玩家程序未生成逐步报告：$reportPath") }
                else {
                    $record.steps = $report.steps
                    $record.runResult = $report.runResult
                    foreach ($step in $SmokeRequiredSteps) {
                        $observed = @($report.steps | Where-Object { $_.name -eq $step })
                        if ($observed.Count -eq 0) { $failures.Add("缺少冒烟步骤：$step") }
                        elseif ($observed[-1].status -ne 'passed') { $failures.Add("冒烟步骤未通过：$step（$($observed[-1].detail)）") }
                    }
                    if ($report.runResult -ne 'cleared') { $failures.Add("本局结果为 $($report.runResult)，不是通关。") }
                }
            }
            Complete-StageRecord $record 'smoke' $failures
        }

        'Summarize' {
            $snapshot = Get-Snapshot
            $reasons = [System.Collections.Generic.List[string]]::new()
            $stageResults = [System.Collections.Generic.List[object]]::new()
            foreach ($name in $AcceptanceStages) {
                $stageRecord = Read-CiJson -Path (Get-StageRecordPath $name)
                if (-not $stageRecord) {
                    $stageResults.Add([ordered]@{ stage = $name; recordId = $null; status = 'notRun' })
                    $reasons.Add("$name 未运行。")
                    continue
                }
                $recordId = if ($name -eq 'build') { $stageRecord.buildId } else { $stageRecord.runId }
                $stageResults.Add([ordered]@{ stage = $name; recordId = $recordId; status = $stageRecord.status })
                if ($stageRecord.status -notin 'passed', 'succeeded') { $reasons.Add("$name 结果为 $($stageRecord.status)。") }
                if ($stageRecord.snapshotId -ne $snapshot.snapshotId) { $reasons.Add("$name 的记录来自其他快照 $($stageRecord.snapshotId)。") }
            }
            $build = Read-CiJson -Path (Get-StageRecordPath 'build')
            $smoke = Read-CiJson -Path (Get-StageRecordPath 'smoke')
            if ($build -and $smoke -and $smoke.buildId -ne $build.buildId) { $reasons.Add("冒烟记录关联的构建 $($smoke.buildId) 不是本次构建 $($build.buildId)。") }
            $changed = Assert-InputUnchanged $snapshot
            if ($changed) { $reasons.Add($changed) }
            $currentCheckSetHash = (Get-FileHash -LiteralPath $RequiredCasesPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentCheckSetHash -ne $snapshot.checkSet.sha256) { $reasons.Add('必需检查集在运行期间被修改。') }

            $isAcceptance = $snapshot.mode -eq 'Acceptance'
            if ($isAcceptance -and $snapshot.hasLocalChanges) { $reasons.Add('输入快照含本地改动。') }
            $summary = [ordered]@{
                ($isAcceptance ? 'acceptanceId' : 'summaryId') = New-CiRunId ($isAcceptance ? 'acceptance' : 'dev-summary')
                snapshotId          = $snapshot.snapshotId
                revision            = $snapshot.revision
                profileId           = $snapshot.profileId
                requiredCheckSetRef = $snapshot.checkSet
                stageResults        = $stageResults
                result              = if ($reasons.Count -eq 0) { 'passed' } else { 'failed' }
                reason              = @($reasons)
                countsAsAcceptance  = $isAcceptance
                createdAt           = Get-UtcTimestamp
            }
            $summaryPath = Join-Path $OutputRoot ($isAcceptance ? 'acceptance.json' : 'development-summary.json')
            Write-CiJson -InputObject $summary -Path $summaryPath

            $lines = @("### $($isAcceptance ? '里程碑验收' : '开发验证汇总')：$($reasons.Count -eq 0 ? '通过' : '未通过')", '', '| 阶段 | 记录 | 结果 |', '| --- | --- | --- |')
            $lines += $stageResults | ForEach-Object { "| $($_.stage) | $($_.recordId) | $($_.status) |" }
            if ($reasons.Count -gt 0) { $lines += @('', '未通过原因：') + ($reasons | ForEach-Object { "- $_" }) }
            Add-CiStepSummary $lines
            foreach ($reason in $reasons) { Write-CiError "[汇总] $reason" }
            Write-Host "汇总结果：$($summary.result)。记录：$summaryPath"
            if ($reasons.Count -gt 0) { exit 1 }
        }
    }
}
finally {
    Pop-Location
}
