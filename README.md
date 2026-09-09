# KB 385606 → script

**KB**: [“Check for data inconsistencies in DB upgrade” NSX precheck error for VCF 9 upgrades — “MP Objects found in DB”](https://knowledge.broadcom.com/external/article/385606)

升級到 VCF / NSX 9 時 precheck 失敗：

```
UC MP - Check for data inconsistencies in DB
Found data inconsistencies: MP Objects found in DB before promotion for tables : <table_name, ...>,
please perform Manager to Policy promotion or delete the MP objects and retry the prechecks.
Delete any Bridge firewall section/rule if they exist and then retry the prechecks.
```

原因：VCF 9.0 已移除 MP Logical API 與 MP-to-Policy promotion 工具，殘留的 Manager 物件必須先
promote 成 Policy 物件或刪除，precheck 才會過。

## 檔案

| 檔案 | 用途 |
|---|---|
| `kb385606-mp2policy.sh` | **主要** — 直接在 NSX Manager appliance 上跑的 shell script |
| `Invoke-NsxMp2Policy.ps1` | 同功能的 PowerShell 版，給從 Windows 遠端跑的情境 |

---

## 在 NSX Manager 上跑（shell script）

只需要 `bash` + `curl` + `python3`（或 `jq`）—— NSX Manager appliance 都有。

### 上傳並執行

```bash
scp kb385606-mp2policy.sh admin@<nsx-manager>:/tmp/
```

在 NSX Manager 上：

```bash
st en
```

```bash
bash /tmp/kb385606-mp2policy.sh --action check
```

不帶 `--host` 時預設打 `localhost`；不帶密碼時會互動式輸入（也吃 `NSX_PASSWORD` 環境變數）。

### 常用組合

```bash
# 1) 唯讀檢查（安全，正式環境隨時可跑）
bash kb385606-mp2policy.sh --action check
```

```bash
# 2) 檢查時順便啟動 migration-coordinator（否則盤點端點會回 500）
bash kb385606-mp2policy.sh --action check --start-coordinator
```

```bash
# 3) 實際修復：啟服務 + promotion + 輪詢到結束，個別物件失敗就跳過
bash kb385606-mp2policy.sh --action promote --skip-failed
```

```bash
# 4) 連 Bridge Firewall 一起清，全程不問（自動化 / 排程用）
bash kb385606-mp2policy.sh --action promote --skip-failed --remove-bridge-fw --yes
```

```bash
# 5) 從別台 Linux 遠端跑
NSX_PASSWORD='<pw>' bash kb385606-mp2policy.sh --host nsx-mgmt.example.local --action check
```

`--help` 有完整參數表。

---

## 從 Windows 遠端跑（PowerShell 版）

```bash
pwsh -File .\Invoke-NsxMp2Policy.ps1 -NsxManager nsx-mgmt.example.local -User admin -Action Check
```

```bash
pwsh -File .\Invoke-NsxMp2Policy.ps1 -NsxManager nsx-mgmt.example.local -Action Promote -SkipFailedResources
```

支援 `-WhatIf` / `-Confirm`，Windows PowerShell 5.1 與 PowerShell 7+ 都可跑。

---

## KB 步驟 ↔ 腳本步驟對照

| KB 內容 | 腳本步驟 | API |
|---|---|---|
| — | 0 連線 | `GET /api/v1/node` |
| Bridge Firewall：Manager 模式 → Security → Bridge Firewall，有設定就移除 | 1 盤點 / 4 刪除 | `GET /api/v1/firewall/sections`、`DELETE /api/v1/firewall/sections/{id}?cascade=true` |
| 前置：`start service migration-coordinator` | 2 | `GET/POST /api/v1/node/services/migration-coordinator[/status][?action=start]`，API 失敗時退回 `nsxcli -c "start service migration-coordinator"` |
| 取得可 promote 的 MP 物件數量與型別 | 3 | `GET /api/v1/migration/mp-to-policy/stats?pre_promotion=true` |
| Start Objects Promotion | 5 | `POST /api/v1/migration/mp-to-policy`，body `{"skip_failed_resources":…,"mode":"GENERIC"}` |
| 查 migration 狀態摘要 | 6 輪詢 | `GET /api/v1/migration/status-summary`（取 `MP_TO_POLICY_MIGRATION`） |
| 查各物件 migration stats | 7 | `GET /api/v1/migration/mp-to-policy/stats` |
| 查 promotion 歷史 | 7 | `GET /api/v1/migration/mp-policy-promotion/history` |
| Rerun the Upgrade prechecks | exit 0 後自行重跑 | — |

## Exit code

| code | 意義 |
|---|---|
| 0 | 乾淨，可重跑 upgrade prechecks |
| 1 | 仍需處理（有 MP 物件 / Bridge FW，或盤點無法判定） |
| 2 | 執行錯誤（連線、認證、API 失敗、輪詢逾時、缺相依工具） |
| 3 | Promotion 跑完但有物件 promote 失敗 |

每次執行都會寫一份 JSON 報告（shell 版預設 `/var/log/kb385606-<ts>.json`，寫不進去就落在當前目錄；
PowerShell 版在 `reports\`），含所有 API 原始回應，可直接附在 case 或交付文件裡。

## 設計上的取捨

- **預設唯讀。** `--action check` 不動任何東西；連啟動 `migration-coordinator`（算服務狀態變更）
  都要明確加 `--start-coordinator`。
- **刪除永不自動。** Bridge firewall section 的刪除要 `--remove-bridge-fw`，且逐一問 y/N，
  要無人值守才加 `--yes`。
- **密碼不進 process list。** 走 0600 的暫存 netrc 給 curl，離開時 `trap` 清掉；
  不用 `curl -u user:pass`（`ps` 看得到）。
- **Bridge FW 判定方式**：列出 MP firewall sections，取 `section_type = LAYER2`；「非預設 section」
  或「預設 section 但 `rule_count > 0`」才視為需移除。KB 沒給精確判定條件，這裡採保守列舉、
  由人確認再刪。
- **盤點不到 ≠ 乾淨。** `migration-coordinator` 沒跑時 stats 端點回 HTTP 500，腳本判
  `INDETERMINATE` 並 exit 1，不會誤報「通過」；promote 模式下也會拒絕在不明狀態下開始 promotion。

## 實測狀態

在 lab 的 NSX **9.1.0.0.25318225**（`vcf-m02-nsx01a` / 10.0.1.20）跑過 shell 版與 PowerShell 版的
check 模式，行為一致：

- 連線 / 版本偵測正常
- MP firewall section API 已於 9.x 移除（HTTP 404）→ 正確降級為 WARN 並略過
- `migration-coordinator` 為 `stopped` → 盤點端點 HTTP 500 → 正確判 `INDETERMINATE`，exit 1
- JSON 報告輸出格式正確

**尚未驗證**：`--action promote` 的實際 promotion 路徑（`POST /api/v1/migration/mp-to-policy` 與
輪詢、覆核），因為這台 lab 已經是 9.1、沒有殘留 MP 物件可測。要完整驗證需要一套升級前的
NSX 4.x 環境。步驟 3 / 6 / 7 的回應解析是照 KB 所列的 response 範例寫的。
