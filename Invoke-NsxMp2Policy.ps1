<#
.SYNOPSIS
    KB 385606 - "Check for data inconsistencies in DB upgrade" NSX precheck error for VCF 9
    upgrades ("MP Objects found in DB") 的檢查與修復腳本。

.DESCRIPTION
    VCF/NSX 9.0 已移除 MP Logical API 與 MP-to-Policy promotion 工具，升級前殘留的
    Manager (MP) 物件會讓 NSX 升級 precheck 失敗：

        UC MP - Check for data inconsistencies in DB
        Found data inconsistencies: MP Objects found in DB before promotion for tables : <...>,
        please perform Manager to Policy promotion or delete the MP objects and retry the
        prechecks. Delete any Bridge firewall section/rule if they exist and then retry the
        prechecks.

    本腳本把 KB 的兩段人工流程自動化：
      1) Bridge Firewall  - 列出 Manager 模式下殘留的 L2/Bridge firewall section（可選擇刪除）
      2) Manager Objects  - 啟動 migration-coordinator、觸發 MP -> Policy promotion、輪詢到完成

    KB: https://knowledge.broadcom.com/external/article/385606

.PARAMETER NsxManager
    NSX Manager 的 FQDN 或 IP（單一節點即可，promotion 是叢集層級動作）。

.PARAMETER Credential
    NSX admin 憑證。未提供時會用 -User / -Password，再不然互動式詢問。

.PARAMETER Action
    Check   - 唯讀。只做盤點與判定，不改任何東西（預設）。
    Promote - 執行修復：啟動 migration-coordinator + 觸發 promotion + 輪詢到結束。

.PARAMETER RemoveBridgeFirewall
    只在 -Action Promote 時有效。刪除非預設的 L2 (Bridge) firewall section。
    這是不可逆動作，會逐一 confirm（可用 -WhatIf 先看，或 -Confirm:$false 略過確認）。

.PARAMETER StartCoordinator
    允許腳本啟動 migration-coordinator 服務（-Action Promote 時自動啟動，不需此參數）。
    Check 模式下必須明確加上此參數才會動到服務，否則只做唯讀查詢。

.PARAMETER SkipFailedResources
    對應 UI 的 "Skip and Continue"。promotion 時個別物件失敗不中斷整體流程。

.PARAMETER TimeoutMinutes
    Promotion 輪詢逾時（預設 120 分鐘）。

.PARAMETER PollSeconds
    輪詢間隔秒數（預設 20 秒）。

.PARAMETER OutputDir
    JSON 報告輸出目錄。預設為腳本旁的 reports\ 。

.EXAMPLE
    # 只檢查（唯讀，可在正式環境隨時跑）
    .\Invoke-NsxMp2Policy.ps1 -NsxManager nsx-mgmt.example.local -User admin
    # 不給 -Password 會互動式詢問；也可用 -Credential 帶 PSCredential

.EXAMPLE
    # 實際做 promotion，個別物件失敗就跳過
    .\Invoke-NsxMp2Policy.ps1 -NsxManager 10.0.0.140 -Action Promote -SkipFailedResources

.EXAMPLE
    # 連 Bridge Firewall 一起清（先用 -WhatIf 看會刪什麼）
    .\Invoke-NsxMp2Policy.ps1 -NsxManager 10.0.0.140 -Action Promote -RemoveBridgeFirewall -WhatIf

.NOTES
    Exit codes:
      0 = 乾淨，precheck 應該會過
      1 = 仍需人工處理（還有 MP 物件 / Bridge FW）
      2 = 執行錯誤（連線、認證、API 失敗、逾時）
      3 = Promotion 跑完但有物件失敗
    相容 Windows PowerShell 5.1 與 PowerShell 7+。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$NsxManager,

    [pscredential]$Credential,
    [string]$User = 'admin',
    [string]$Password,

    [ValidateSet('Check', 'Promote')]
    [string]$Action = 'Check',

    [switch]$RemoveBridgeFirewall,
    [switch]$SkipFailedResources,
    [switch]$StartCoordinator,

    [int]$TimeoutMinutes = 120,
    [int]$PollSeconds = 20,

    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -NsxManager 是 Mandatory，PowerShell 會自己問。這裡容錯客戶可能貼進來的形式：
# https://nsx.corp.local/ 、nsx.corp.local:443 、結尾多一個點的 FQDN、前後空白
$NsxManager = $NsxManager.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '\.$', ''
if ([string]::IsNullOrWhiteSpace($NsxManager)) { throw 'NsxManager 不可為空' }
if ($NsxManager -notmatch '^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9][A-Za-z0-9.\-]*)(:[0-9]{1,5})?$') {
    throw "不是合法的 IP / FQDN：$NsxManager"
}

# ---------------------------------------------------------------- 基礎設施 ----

$script:IsCoreEdition = $PSVersionTable.PSVersion.Major -ge 6
$script:Findings = [ordered]@{
    kb                   = '385606'
    nsxManager           = $NsxManager
    action               = $Action
    startedAt            = (Get-Date).ToString('s')
    nsxVersion           = $null
    migrationCoordinator = $null
    bridgeFirewall       = @()
    prePromotionStats    = $null
    promotion            = $null
    postPromotionStats   = $null
    remainingMpObjects   = $null
    history              = $null
    verdict              = $null
    finishedAt           = $null
    exitCode             = $null
}

function Write-Step { param([string]$m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info2{ param([string]$m) Write-Host "  [ .. ] $m" -ForegroundColor Gray }

if (-not $script:IsCoreEdition) {
    # PS 5.1：NSX 預設自簽憑證，關掉驗證
    if (-not ('NsxCertBypass' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class NsxCertBypass : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object NsxCertBypass
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

if (-not $Credential) {
    if ($Password) {
        $Credential = New-Object pscredential($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
    }
    else {
        $Credential = Get-Credential -UserName $User -Message "NSX Manager $NsxManager admin credential"
    }
}

$script:AuthHeader = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
    Accept        = 'application/json'
}

function Invoke-Nsx {
    <# NSX API 呼叫封裝。-AllowNotFound 讓 400/404 回 $null 而不是丟例外。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Method = 'GET',
        $Body,
        [switch]$AllowNotFound,
        [int[]]$TolerateStatus = @()
    )
    $uri = "https://$NsxManager$Path"
    $p = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $script:AuthHeader
        TimeoutSec  = 300
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $p.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $p.ContentType = 'application/json'
    }
    if ($script:IsCoreEdition) { $p.SkipCertificateCheck = $true }

    Write-Verbose "$Method $uri"
    try {
        return Invoke-RestMethod @p
    }
    catch {
        $status = $null
        $resp = $_.Exception.PSObject.Properties['Response']
        if ($resp -and $resp.Value) { try { $status = [int]$resp.Value.StatusCode } catch { } }
        if ($AllowNotFound -and ($status -eq 404 -or $status -eq 400)) { return $null }
        if ($status -and $TolerateStatus -contains $status) { return $null }
        $suffix = if ($status) { " (HTTP $status)" } else { '' }
        throw "NSX API $Method $Path failed$suffix : $($_.Exception.Message)"
    }
}

function Get-Prop {
    <# StrictMode 下安全取屬性 #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Write-Report {
    param([int]$ExitCode)
    $script:Findings.finishedAt = (Get-Date).ToString('s')
    $script:Findings.exitCode = $ExitCode
    $dir = $OutputDir
    if (-not $dir) { $dir = Join-Path $PSScriptRoot 'reports' }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safe = ($NsxManager -replace '[^\w\.\-]', '_')
    $file = Join-Path $dir "kb385606-$safe-$stamp.json"
    $script:Findings | ConvertTo-Json -Depth 12 | Set-Content -Path $file -Encoding UTF8
    Write-Host "`n報告：$file" -ForegroundColor DarkCyan
}

# ------------------------------------------------------------ 步驟 0：連線 ----

Write-Step "0. 連線 NSX Manager $NsxManager"
try {
    $node = Invoke-Nsx -Path '/api/v1/node'
    $script:Findings.nsxVersion = Get-Prop $node 'product_version'
    Write-Ok "已連線 - NSX $($script:Findings.nsxVersion) / hostname $(Get-Prop $node 'hostname')"
}
catch {
    Write-Bad $_.Exception.Message
    exit 2
}

# --------------------------------------- 步驟 1：Bridge Firewall（KB 第一段）----

Write-Step '1. Bridge Firewall 檢查 (Manager 模式 L2 firewall section)'
$bridgeSections = @()
try {
    $fw = Invoke-Nsx -Path '/api/v1/firewall/sections?page_size=1000' -AllowNotFound
    if ($null -eq $fw) {
        Write-Warn2 'MP firewall section API 不可用（NSX 9.x 已移除）- 略過此項檢查'
    }
    else {
        $sections = @(Get-Prop $fw 'results' @())
        Write-Info2 "共取得 $($sections.Count) 個 MP firewall section"
        foreach ($s in $sections) {
            if ((Get-Prop $s 'section_type') -ne 'LAYER2') { continue }
            $isDefault = [bool](Get-Prop $s 'is_default' $false)
            $ruleCount = [int](Get-Prop $s 'rule_count' 0)
            $bridgeSections += [pscustomobject]@{
                id          = Get-Prop $s 'id'
                displayName = Get-Prop $s 'display_name'
                sectionType = 'LAYER2'
                isDefault   = $isDefault
                ruleCount   = $ruleCount
                # 非預設 section，或預設 section 但帶了規則，才會擋 precheck
                mustRemove  = ((-not $isDefault) -or ($ruleCount -gt 0))
                removed     = $false
            }
        }
        $blocking = @($bridgeSections | Where-Object { $_.mustRemove })
        if ($blocking.Count -eq 0) {
            Write-Ok '沒有需要移除的 Bridge / L2 firewall section'
        }
        else {
            Write-Warn2 "發現 $($blocking.Count) 個需要處理的 L2 (Bridge) firewall section："
            $blocking | Format-Table id, displayName, ruleCount, isDefault -AutoSize | Out-String | Write-Host
        }
    }
}
catch {
    Write-Warn2 "Bridge Firewall 檢查失敗（不中斷）：$($_.Exception.Message)"
}
$script:Findings.bridgeFirewall = $bridgeSections

# -------------------------------- 步驟 2：migration-coordinator（KB 前置條件）----

Write-Step '2. migration-coordinator 服務狀態'
$mcRunning = $false
try {
    $mc = Invoke-Nsx -Path '/api/v1/node/services/migration-coordinator/status' -AllowNotFound
    $mcState = Get-Prop $mc 'runtime_state' 'unknown'
    $mcRunning = ($mcState -eq 'running')
    $script:Findings.migrationCoordinator = $mcState
    if ($mcRunning) { Write-Ok "migration-coordinator: $mcState" }
    else { Write-Warn2 "migration-coordinator: $mcState（promotion 前必須啟動）" }
}
catch {
    Write-Warn2 "無法查詢 migration-coordinator 狀態：$($_.Exception.Message)"
}

if (-not $mcRunning -and ($Action -eq 'Promote' -or $StartCoordinator)) {
    if ($PSCmdlet.ShouldProcess($NsxManager, 'start service migration-coordinator')) {
        Invoke-Nsx -Path '/api/v1/node/services/migration-coordinator?action=start' -Method POST | Out-Null
        Write-Info2 '已送出啟動請求，等待服務就緒…'
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $mc = Invoke-Nsx -Path '/api/v1/node/services/migration-coordinator/status' -AllowNotFound
            if ((Get-Prop $mc 'runtime_state') -eq 'running') { $mcRunning = $true; break }
        }
        if ($mcRunning) {
            Write-Ok 'migration-coordinator 已啟動'
            $script:Findings.migrationCoordinator = 'running'
        }
        else {
            Write-Bad '10 分鐘內未進入 running。請於 NSX admin CLI 手動執行： start service migration-coordinator'
            Write-Report 2; exit 2
        }
    }
}

# ------------------------------ 步驟 3：盤點待 promote 的 MP 物件（KB API 1）----

Write-Step '3. 盤點待 promote 的 Manager (MP) 物件'
$mpTotal = -1
try {
    # migration-coordinator 沒跑時，此端點會回 HTTP 500，屬預期情況而非致命錯誤
    $preStats = Invoke-Nsx -Path '/api/v1/migration/mp-to-policy/stats?pre_promotion=true' `
        -AllowNotFound -TolerateStatus 500, 503
    $script:Findings.prePromotionStats = $preStats
    if ($null -eq $preStats) {
        Write-Warn2 'pre-promotion stats API 無回應 - MP 物件數量「無法判定」'
        if (-not $mcRunning) {
            Write-Info2 '原因：migration-coordinator 未啟動。加 -StartCoordinator 讓腳本啟動它，'
            Write-Info2 '      或於 NSX admin CLI 執行： start service migration-coordinator'
        }
    }
    else {
        $mpTotal = [int](Get-Prop $preStats 'total_count' 0)
        if ($mpTotal -eq 0) { Write-Ok '沒有殘留的 MP 物件' }
        else {
            Write-Warn2 "共 $mpTotal 個 MP 物件待 promote："
            @(Get-Prop $preStats 'migration_stats' @()) |
                Select-Object resource_type, promotion_status, total_count, promoted_objects_count, failed_objects_count |
                Format-Table -AutoSize | Out-String | Write-Host
        }
    }
}
catch {
    Write-Bad $_.Exception.Message
    Write-Report 2; exit 2
}

$blockingBridge = @($bridgeSections | Where-Object { $_.mustRemove })

# ------------------------------------------------------ Check 模式：到此為止 ----

if ($Action -eq 'Check') {
    Write-Step '判定'
    if ($mpTotal -eq 0 -and $blockingBridge.Count -eq 0) {
        $script:Findings.verdict = 'CLEAN'
        Write-Ok 'NSX 側乾淨，"Check for data inconsistencies in DB" precheck 應可通過'
        Write-Report 0; exit 0
    }
    if ($mpTotal -lt 0 -and $blockingBridge.Count -eq 0) {
        $script:Findings.verdict = 'INDETERMINATE'
        Write-Warn2 '無法判定 - MP 物件盤點未取得結果，請先啟動 migration-coordinator 後重跑：'
        Write-Host "    .\Invoke-NsxMp2Policy.ps1 -NsxManager $NsxManager -Action Check -StartCoordinator" -ForegroundColor Yellow
        Write-Report 1; exit 1
    }
    $script:Findings.verdict = 'REMEDIATION_REQUIRED'
    Write-Bad '需要修復：'
    if ($mpTotal -gt 0) { Write-Host "         - $mpTotal 個 MP 物件需 promote 到 Policy" }
    if ($mpTotal -lt 0) { Write-Host "         - MP 物件數量未知（migration-coordinator 未啟動）" }
    if ($blockingBridge.Count -gt 0) { Write-Host "         - $($blockingBridge.Count) 個 Bridge/L2 firewall section 需移除" }
    $extra = if ($blockingBridge.Count -gt 0) { ' -RemoveBridgeFirewall' } else { '' }
    Write-Host "`n  修復指令："
    Write-Host "    .\Invoke-NsxMp2Policy.ps1 -NsxManager $NsxManager -Action Promote -SkipFailedResources$extra" -ForegroundColor Yellow
    Write-Report 1; exit 1
}

# ------------------------------------- 步驟 4：移除 Bridge Firewall（可選）----

if ($blockingBridge.Count -gt 0) {
    if ($RemoveBridgeFirewall) {
        Write-Step '4. 移除 Bridge / L2 firewall section'
        foreach ($b in $blockingBridge) {
            $target = "$($b.displayName) ($($b.id), $($b.ruleCount) rules)"
            if ($PSCmdlet.ShouldProcess($target, 'DELETE firewall section (cascade)')) {
                try {
                    Invoke-Nsx -Path "/api/v1/firewall/sections/$($b.id)?cascade=true" -Method DELETE | Out-Null
                    $b.removed = $true
                    Write-Ok "已刪除 $target"
                }
                catch {
                    Write-Bad "刪除失敗 $target - $($_.Exception.Message)"
                }
            }
        }
    }
    else {
        Write-Step '4. Bridge Firewall'
        Write-Warn2 "尚有 $($blockingBridge.Count) 個 L2 (Bridge) firewall section 未處理（未指定 -RemoveBridgeFirewall）"
        Write-Info2 'UI 路徑：System > General Settings > User Interface 切 Manager 模式 -> Security > Bridge Firewall'
    }
}

# ---------------------------------------- 步驟 5：觸發 promotion（KB API 2）----

Write-Step '5. Manager -> Policy promotion'
if ($mpTotal -lt 0) {
    Write-Bad '無法取得 MP 物件盤點結果，中止 promotion 以免在不明狀態下動作'
    $script:Findings.verdict = 'INDETERMINATE'
    Write-Report 2; exit 2
}
elseif ($mpTotal -eq 0) {
    Write-Ok '沒有 MP 物件需要 promote，略過'
}
else {
    $body = @{ skip_failed_resources = [bool]$SkipFailedResources; mode = 'GENERIC' }
    if ($PSCmdlet.ShouldProcess($NsxManager, "POST /api/v1/migration/mp-to-policy ($mpTotal objects, skip_failed_resources=$($body.skip_failed_resources))")) {
        Invoke-Nsx -Path '/api/v1/migration/mp-to-policy' -Method POST -Body $body | Out-Null
        Write-Ok 'Promotion 已觸發'

        # 步驟 6：輪詢 status-summary（KB API 3）
        Write-Step '6. 輪詢 promotion 進度'
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $final = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            $sum = Invoke-Nsx -Path '/api/v1/migration/status-summary' -AllowNotFound -TolerateStatus 500,503
            if ($null -eq $sum) { continue }
            $overall = Get-Prop $sum 'overall_migration_status' 'UNKNOWN'
            $comp = @(Get-Prop $sum 'component_status' @()) |
                Where-Object { (Get-Prop $_ 'component_type') -eq 'MP_TO_POLICY_MIGRATION' } |
                Select-Object -First 1
            $cStatus = Get-Prop $comp 'status' 'UNKNOWN'
            $cPct = [math]::Round([double](Get-Prop $comp 'percent_complete' 0), 1)
            Write-Info2 ("{0}  overall={1}  migration={2} {3}%" -f (Get-Date -Format 'HH:mm:ss'), $overall, $cStatus, $cPct)
            if ('SUCCESS', 'FAILED', 'PAUSED', 'CANCELED' -contains $cStatus) { $final = $sum; break }
            if ('SUCCESS', 'FAILED' -contains $overall) { $final = $sum; break }
        }
        if ($null -eq $final) {
            Write-Bad "$TimeoutMinutes 分鐘內未結束。請至 UI System > General Settings > Manager Objects Promotion 檢視"
            $script:Findings.promotion = 'TIMEOUT'
            Write-Report 2; exit 2
        }
        $script:Findings.promotion = $final
        Write-Ok "Promotion 結束：overall=$(Get-Prop $final 'overall_migration_status')"
    }
}

# ------------------------- 步驟 7：結果覆核（KB API 4 stats + KB API 5 history）----

Write-Step '7. 結果覆核'
$failedTotal = 0
$postStats = Invoke-Nsx -Path '/api/v1/migration/mp-to-policy/stats' -AllowNotFound -TolerateStatus 500,503
$script:Findings.postPromotionStats = $postStats
if ($postStats) {
    $rows = @(Get-Prop $postStats 'migration_stats' @())
    if ($rows.Count -gt 0) {
        $rows | Select-Object resource_type, promotion_status, total_count, promoted_objects_count, failed_objects_count |
            Format-Table -AutoSize | Out-String | Write-Host
        foreach ($r in $rows) { $failedTotal += [int](Get-Prop $r 'failed_objects_count' 0) }
    }
}

$leftTotal = 0
$recheck = Invoke-Nsx -Path '/api/v1/migration/mp-to-policy/stats?pre_promotion=true' -AllowNotFound -TolerateStatus 500,503
if ($recheck) { $leftTotal = [int](Get-Prop $recheck 'total_count' 0) }
$script:Findings.remainingMpObjects = $leftTotal

$hist = Invoke-Nsx -Path '/api/v1/migration/mp-policy-promotion/history' -AllowNotFound -TolerateStatus 500,503
$script:Findings.history = $hist
if ($hist) {
    foreach ($h in (@(Get-Prop $hist 'results' @()) | Select-Object -First 6)) {
        $ms = [int64](Get-Prop $h 'date_time' 0)
        $ts = if ($ms -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime.ToString('s') } else { '?' }
        Write-Info2 "history: $ts  $(Get-Prop $h 'status')"
    }
}

Write-Step '判定'
$stillBridge = @($bridgeSections | Where-Object { $_.mustRemove -and -not $_.removed })

if ($leftTotal -eq 0 -and $failedTotal -eq 0 -and $stillBridge.Count -eq 0) {
    $script:Findings.verdict = 'CLEAN'
    Write-Ok '全部完成 - 可以重跑 NSX / VCF 升級 prechecks'
    Write-Report 0; exit 0
}

if ($failedTotal -gt 0) {
    $script:Findings.verdict = 'PROMOTED_WITH_FAILURES'
    Write-Bad "$failedTotal 個物件 promote 失敗，需人工處理後重跑"
}
else {
    $script:Findings.verdict = 'REMEDIATION_REQUIRED'
}
if ($leftTotal -gt 0) { Write-Bad "仍有 $leftTotal 個 MP 物件未 promote" }
if ($stillBridge.Count -gt 0) { Write-Bad "仍有 $($stillBridge.Count) 個 Bridge/L2 firewall section 未移除" }

$code = if ($failedTotal -gt 0) { 3 } else { 1 }
Write-Report $code
exit $code
