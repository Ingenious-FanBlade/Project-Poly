#Requires -Version 7.2
<#
.SYNOPSIS
    按版本化的必需用例清单核对 Unity Test Framework 的 NUnit XML 结果。

.DESCRIPTION
    Unity 进程退出码为 0 不代表测试通过：本脚本要求结果非空、必需用例全部出现且通过，
    任何用例失败均判失败；结果写为 TestRun JSON（含每个用例的结果）。

    必需用例清单格式（Tools/CI/RequiredChecks/<checkSetVersion>.json）：
    {
      "checkSetVersion": "battle-slice-v1",
      "cases": [
        { "id": "<NUnit fullname>", "group": "BS-02", "testPlatform": "EditMode", "requiresGraphics": false }
      ]
    }
    requiresGraphics 为 true 的用例依赖真实显卡或窗口，须同时标记 NUnit 类别 RequiresGraphics；
    指定 -ExcludeGraphicsDependent（托管运行器上的 PR 检查）时不要求这些用例。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $ResultsPath,
    [Parameter(Mandatory)] [string] $RequiredCasesPath,
    [Parameter(Mandatory)] [ValidateSet('EditMode', 'PlayMode')] [string[]] $TestPlatform,
    [Parameter(Mandatory)] [string] $OutputPath,
    [switch] $ExcludeGraphicsDependent,
    [string] $SnapshotId,
    [string] $Label = 'Unity 测试'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CiCommon.psm1') -Force
Initialize-CiConsole

$repositoryRoot = Get-RepositoryRoot
$startedAt = Get-UtcTimestamp
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

# 1. 读取必需用例清单。
$checkSet = Read-CiJson -Path $RequiredCasesPath
$requiredCases = @()
if (-not $checkSet) {
    $failures.Add("必需用例清单不存在：$RequiredCasesPath")
}
else {
    $requiredCases = @($checkSet.cases | Where-Object {
            $_.testPlatform -in $TestPlatform -and -not ($ExcludeGraphicsDependent -and $_.requiresGraphics)
        })
    if ($requiredCases.Count -eq 0) {
        $failures.Add("必需用例清单 $($checkSet.checkSetVersion) 在 $($TestPlatform -join '/') 范围内为空；实施时须绑定非空、固定的用例 ID。")
    }
}

# 2. 读取全部 NUnit XML 中的用例结果。
$resultFiles = @(foreach ($path in $ResultsPath) {
        if (Test-Path -LiteralPath $path -PathType Container) { Get-ChildItem -LiteralPath $path -Filter '*.xml' -Recurse -File }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) { Get-Item -LiteralPath $path }
    })
if ($resultFiles.Count -eq 0) { $failures.Add("未找到测试结果 XML：$($ResultsPath -join '、')") }

$observed = @{}
foreach ($file in $resultFiles) {
    try {
        [xml] $document = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    }
    catch {
        $failures.Add("测试报告不可读取：$($file.FullName)：$($_.Exception.Message)")
        continue
    }
    if (-not $document.DocumentElement -or $document.DocumentElement.Name -ne 'test-run') {
        $failures.Add("不是 NUnit 测试报告：$($file.FullName)")
        continue
    }
    foreach ($case in $document.SelectNodes('//test-case')) {
        $id = $case.GetAttribute('fullname')
        $result = $case.GetAttribute('result')
        $resultLabel = $case.GetAttribute('label')
        if (-not $observed.ContainsKey($id)) { $observed[$id] = [System.Collections.Generic.List[object]]::new() }
        $observed[$id].Add([ordered]@{ result = $result; label = $resultLabel; report = $file.Name })
    }
}
if ($resultFiles.Count -gt 0 -and $observed.Count -eq 0) { $failures.Add('测试报告中执行了零个用例。') }

# 3. 逐项核对。
$requiredIds = [System.Collections.Generic.HashSet[string]]::new([string[]] @($requiredCases | ForEach-Object { $_.id }))
$caseResults = [System.Collections.Generic.List[object]]::new()
foreach ($required in $requiredCases) {
    $runs = $observed[$required.id]
    $outcome = if (-not $runs) { 'missing' }
    elseif (@($runs | Where-Object { $_.result -ne 'Passed' }).Count -gt 0) { 'notPassed' }
    else { 'passed' }
    switch ($outcome) {
        'missing' { $failures.Add("必需用例未执行：$($required.id)（$($required.group)）") }
        'notPassed' {
            $detail = ($runs | ForEach-Object { "$($_.result)$(if ($_.label) { "/$($_.label)" })" }) -join '、'
            $failures.Add("必需用例未通过：$($required.id)（$($required.group)）：$detail")
        }
    }
    $caseResults.Add([ordered]@{
            caseId   = $required.id
            group    = $required.group
            required = $true
            status   = $outcome
            runs     = if ($runs) { @($runs) } else { @() }
        })
}
foreach ($id in $observed.Keys | Sort-Object) {
    if ($requiredIds.Contains($id)) { continue }
    $runs = $observed[$id]
    $failedRuns = @($runs | Where-Object { $_.result -eq 'Failed' })
    $skippedRuns = @($runs | Where-Object { $_.result -in 'Skipped', 'Inconclusive' })
    if ($failedRuns.Count -gt 0) { $failures.Add("用例失败：$id") }
    elseif ($skippedRuns.Count -gt 0) { $warnings.Add("非必需用例被跳过：$id") }
    $caseResults.Add([ordered]@{
            caseId   = $id
            group    = $null
            required = $false
            status   = if ($failedRuns.Count -gt 0) { 'failed' } elseif ($skippedRuns.Count -gt 0) { 'skipped' } else { 'passed' }
            runs     = @($runs)
        })
}

$record = [ordered]@{
    runId           = New-CiRunId 'test'
    caseId          = "unity-tests/$($TestPlatform -join '+')"
    level           = 'unity-tests'
    label           = $Label
    snapshotId      = $SnapshotId
    revision        = (git rev-parse HEAD)
    checkSetVersion = if ($checkSet) { $checkSet.checkSetVersion } else { $null }
    testPlatforms   = $TestPlatform
    graphicsExcluded = [bool] $ExcludeGraphicsDependent
    environment     = Get-CiEnvironment -RepositoryRoot $repositoryRoot
    startedAt       = $startedAt
    finishedAt      = Get-UtcTimestamp
    status          = if ($failures.Count -eq 0) { 'passed' } else { 'failed' }
    counts          = [ordered]@{
        required        = $requiredCases.Count
        observed        = $observed.Count
        requiredPassed  = @($caseResults | Where-Object { $_.required -and $_.status -eq 'passed' }).Count
        failures        = $failures.Count
    }
    failures        = @($failures)
    warnings        = @($warnings)
    reports         = @($resultFiles | ForEach-Object { $_.FullName })
    caseResults     = @($caseResults)
}
Write-CiJson -InputObject $record -Path $OutputPath

foreach ($failure in $failures) { Write-CiError "[$Label] $failure" }
foreach ($warning in $warnings) { Write-Warning "[$Label] $warning" }
Add-CiStepSummary @(
    "### $Label",
    '',
    "- 结果：$(if ($failures.Count -eq 0) { '通过' } else { '未通过' })",
    "- 必需用例：$($record.counts.requiredPassed)/$($requiredCases.Count) 通过；报告中共 $($observed.Count) 个用例",
    "- 失败项：$($failures.Count)；警告：$($warnings.Count)"
)

if ($failures.Count -gt 0) {
    Write-Host "$Label 未通过：$($failures.Count) 项失败。报告：$OutputPath"
    exit 1
}
Write-Host "$Label 通过。报告：$OutputPath"
