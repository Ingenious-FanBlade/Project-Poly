#Requires -Version 7.2
<#
.SYNOPSIS
    不启动 Unity 的仓库输入检查（BS-01 的输入预检部分）。

.DESCRIPTION
    检查已跟踪文件中没有生成目录与 IDE 文件、资源与 .meta 成对、GUID 不重复、Git LFS 指针有效；
    指定 -CheckBuildProfiles 时，再检查两份 Build Profile 只包含唯一切片场景。
    结果写为预检 TestRun JSON，任一检查失败时以退出码 1 结束。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputPath,
    [switch] $CheckBuildProfiles,
    [string] $SnapshotId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CiCommon.psm1') -Force
Initialize-CiConsole

$SliceScenePath = $BattleSliceScenePath
$BuildProfiles = @($BattleSliceBuildProfiles.Values)
# BuildTarget.StandaloneWindows64
$WindowsX64BuildTarget = 19

$repositoryRoot = Get-RepositoryRoot
Push-Location $repositoryRoot
try {
    $startedAt = Get-UtcTimestamp
    $trackedFiles = Get-GitTrackedFiles
    $trackedSet = [System.Collections.Generic.HashSet[string]]::new([string[]] $trackedFiles, [System.StringComparer]::Ordinal)
    $checks = [System.Collections.Generic.List[object]]::new()

    function Add-CheckResult([string] $Name, [string[]] $Failures, [string] $Note) {
        $Failures = @($Failures | Where-Object { $_ })
        $checks.Add([ordered]@{
                name     = $Name
                status   = if ($Failures.Count -eq 0) { 'passed' } else { 'failed' }
                failures = @($Failures)
                note     = $Note
            })
    }

    # 1. 生成目录与 IDE 文件不能进入仓库。
    $forbiddenPattern = '(?i)^(library|temp|obj|build|builds|logs|usersettings|memorycaptures|recordings)/|(^|/)\.(vs|idea|gradle)/|\.(csproj|sln|slnx|unityproj|suo|user|userprefs|pidb|booproj|pdb|mdb|opendb)$'
    $forbidden = @($trackedFiles | Where-Object { $_ -match $forbiddenPattern })
    Add-CheckResult '生成文件未入库' ($forbidden | ForEach-Object { "不应提交的生成文件：$_" })

    # 2. Unity 可见资源与 .meta 成对。Unity 忽略以 . 开头或以 ~ 结尾的文件与目录。
    function Test-UnityVisible([string] $Path) {
        foreach ($segment in $Path.Split('/')) {
            if ($segment.StartsWith('.') -or $segment.EndsWith('~')) { return $false }
        }
        return $true
    }
    function Get-ScopeRootDepth([string] $Path) {
        if ($Path -match '^Assets/.+') { return 1 }
        if ($Path -match '^Packages/[^/]+/.+') { return 2 }   # 嵌入式包，包根目录本身不需要 .meta
        return 0
    }

    $metaFailures = [System.Collections.Generic.List[string]]::new()
    $assetDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $metaFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $trackedFiles) {
        $rootDepth = Get-ScopeRootDepth $file
        if ($rootDepth -eq 0 -or -not (Test-UnityVisible $file)) { continue }
        if ($file.EndsWith('.meta')) { $metaFiles.Add($file); continue }
        if (-not $trackedSet.Contains("$file.meta")) { $metaFailures.Add("缺少 .meta：$file") }
        $segments = $file.Split('/')
        for ($depth = $rootDepth + 1; $depth -lt $segments.Length; $depth++) {
            [void] $assetDirectories.Add(($segments[0..($depth - 1)] -join '/'))
        }
    }
    foreach ($directory in $assetDirectories) {
        if (-not $trackedSet.Contains("$directory.meta")) { $metaFailures.Add("缺少目录 .meta：$directory") }
    }
    foreach ($meta in $metaFiles) {
        $assetPath = $meta.Substring(0, $meta.Length - '.meta'.Length)
        if (-not $trackedSet.Contains($assetPath) -and -not $assetDirectories.Contains($assetPath)) {
            $metaFailures.Add("孤立的 .meta（对应资源未提交或为空目录）：$meta")
        }
    }
    Add-CheckResult '资源与 .meta 成对' $metaFailures

    # 3. GUID 必须存在且不重复。
    $guidFailures = [System.Collections.Generic.List[string]]::new()
    $guidOwners = @{}
    foreach ($meta in $metaFiles) {
        $match = Select-String -LiteralPath $meta -Pattern '^guid:\s*([0-9a-fA-F]{32})\s*$' | Select-Object -First 1
        if (-not $match) { $guidFailures.Add("无法读取 GUID：$meta"); continue }
        $guid = $match.Matches[0].Groups[1].Value.ToLowerInvariant()
        if ($guidOwners.ContainsKey($guid)) { $guidFailures.Add("GUID $guid 重复：$($guidOwners[$guid]) 与 $meta") }
        else { $guidOwners[$guid] = $meta }
    }
    Add-CheckResult 'GUID 唯一' $guidFailures

    # 4. 按 .gitattributes 应存为 LFS 的文件确实是规范的 LFS 指针。
    $lfsFailures = [System.Collections.Generic.List[string]]::new()
    $null = git lfs version 2>&1
    if ($LASTEXITCODE -ne 0) {
        $lfsFailures.Add('运行环境未安装 Git LFS。')
    }
    else {
        $fsckOutput = git lfs fsck --pointers 2>&1
        if ($LASTEXITCODE -ne 0) {
            $lfsFailures.Add("git lfs fsck --pointers 失败：`n$($fsckOutput -join "`n")")
        }
    }
    Add-CheckResult 'Git LFS 指针有效' $lfsFailures

    # 5. 两份 Build Profile 只包含唯一切片场景，开发与验收配置的 Development 开关正确。
    if ($CheckBuildProfiles) {
        $profileFailures = [System.Collections.Generic.List[string]]::new()
        if (-not $trackedSet.Contains($SliceScenePath)) { $profileFailures.Add("切片场景未提交：$SliceScenePath") }

        foreach ($buildProfile in $BuildProfiles) {
            if (-not $trackedSet.Contains($buildProfile.path)) {
                $profileFailures.Add("$($buildProfile.profileId) 未提交：$($buildProfile.path)")
                continue
            }
            $lines = Get-Content -LiteralPath $buildProfile.path -Encoding utf8
            $text = $lines -join "`n"

            $buildTarget = [regex]::Match($text, '(?m)^\s*m_BuildTarget:\s*(\d+)')
            if (-not $buildTarget.Success -or [int] $buildTarget.Groups[1].Value -ne $WindowsX64BuildTarget) {
                $profileFailures.Add("$($buildProfile.profileId) 的目标平台不是 Windows x64（m_BuildTarget 应为 $WindowsX64BuildTarget）。")
            }
            if ($text -notmatch '(?m)^\s*m_OverrideGlobalSceneList:\s*1\s*$') {
                $profileFailures.Add("$($buildProfile.profileId) 未覆盖全局场景清单，会回退到 EditorBuildSettings 中的模板场景。")
            }
            $development = [regex]::Match($text, '(?m)^\s*m_Development:\s*(\d)')
            if (-not $development.Success -or [int] $development.Groups[1].Value -ne $buildProfile.development) {
                $profileFailures.Add("$($buildProfile.profileId) 的 Development Build 开关应为 $($buildProfile.development)。")
            }

            # m_Scenes 的条目形如“  - enabled: 1”后跟更深缩进的 path 与 guid。
            $scenes = [System.Collections.Generic.List[hashtable]]::new()
            $sceneIndex = [array]::FindIndex([string[]] $lines, [Predicate[string]] { param($l) $l -match '^  m_Scenes:' })
            if ($sceneIndex -ge 0 -and $lines[$sceneIndex] -notmatch '\[\]\s*$') {
                for ($i = $sceneIndex + 1; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -match '^  - (\w+):\s*(.*)$') { $scenes.Add(@{ $Matches[1] = $Matches[2].Trim() }) }
                    elseif ($line -match '^    (\w+):\s*(.*)$' -and $scenes.Count -gt 0) { $scenes[$scenes.Count - 1][$Matches[1]] = $Matches[2].Trim() }
                    else { break }
                }
            }
            if ($scenes.Count -ne 1 -or $scenes[0]['path'] -ne $SliceScenePath -or $scenes[0]['enabled'] -ne '1') {
                $actual = if ($scenes.Count -eq 0) { '空' } else { ($scenes | ForEach-Object { "$($_['path'])（enabled=$($_['enabled'])）" }) -join '、' }
                $profileFailures.Add("$($buildProfile.profileId) 的场景清单应只含启用的 $SliceScenePath，实际为：$actual")
            }
        }
        Add-CheckResult 'Build Profile 与切片场景' $profileFailures '脚本后端（Mono/IL2CPP）由验收构建阶段核对产物结构。'
    }

    $failed = @($checks | Where-Object { $_.status -eq 'failed' })
    $record = [ordered]@{
        runId       = New-CiRunId 'precheck'
        caseId      = 'BS-01/repository-inputs'
        level       = 'precheck'
        snapshotId  = $SnapshotId
        revision    = (git rev-parse HEAD)
        environment = Get-CiEnvironment -RepositoryRoot $repositoryRoot
        startedAt   = $startedAt
        finishedAt  = Get-UtcTimestamp
        status      = if ($failed.Count -eq 0) { 'passed' } else { 'failed' }
        checks      = $checks
    }
    Write-CiJson -InputObject $record -Path $OutputPath

    $summary = @('### 仓库检查', '', '| 检查 | 结果 |', '| --- | --- |')
    foreach ($check in $checks) {
        $summary += "| $($check.name) | $(if ($check.status -eq 'passed') { '通过' } else { "失败（$($check.failures.Count)）" }) |"
        foreach ($failure in $check.failures) { Write-CiError "[$($check.name)] $failure" }
    }
    Add-CiStepSummary $summary

    if ($failed.Count -gt 0) {
        Write-Host "仓库检查未通过：$($failed.Count) 项失败。报告：$OutputPath"
        exit 1
    }
    Write-Host "仓库检查通过。报告：$OutputPath"
}
finally {
    Pop-Location
}
