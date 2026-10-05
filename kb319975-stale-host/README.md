# KB 319975 → script

**KB**: Installing or upgrading NSX on an ESXi host fails because of a stale host entry
([319975](https://knowledge.broadcom.com/external/article/319975))

ESXi 主機被**直接從 vCenter 移除、但沒有先移除 NSX**時，NSX 資料庫（以及 NSX 的 search index）
會留下該主機的殘留記錄。之後用**同樣的名稱或 IP** 把重裝 / 新的主機加回來就會失敗：

```
Node with same ip already exists
Discovered node with id <id> is already prepared
Failed to get Host status for upgrade unit <uuid>
```

主機在 **System > Fabric > Hosts** 看不到、重裝 ESXi 也沒用、SDDC Manager precheck 一直擋。

> ✅ **根本修正在 NSX 4.2.3 / 9.0.1**。還沒升到的環境只能跑 KB 的 workaround，這支 script
> 就是把 workaround option 1–5 變成可重複執行的流程。

## 檔案

| 檔案 | 用途 |
|---|---|
| `kb319975_stale_host.py` | **主要** — 在自己的機器（Windows / Linux / Mac）上跑，只打 NSX Manager API；Python 3.8+ 純標準函式庫 |

`resync` 子命令要 SSH 進 NSX Manager，需要 `paramiko`；沒裝的話它會把要手動貼的指令印出來。

---

## 子命令 ↔ KB option 對照

| 子命令 | KB option | 做什麼 |
|---|---|---|
| `scan` | 診斷 | 把 Manager API / Policy API / fabric node / discovered node / **search index** 五個地方的殘留全撈出來，並判斷該走哪個 option |
| `state` | option 3 / 4 第一步 | `GET .../transport-nodes/<uuid>/state`，回 **Object not found** 才算乾淨 |
| `resync` | **option 2** | 對**每一台** NSX Manager 下 `start search resync policy / manager / telemetry`（或 `--all`），等 10 分鐘後自動重掃 |
| `delete` | **option 3 / 4** | `DELETE ...?force=true&unprepare_host=false`，之後每 5 分鐘 poll state 直到 Object not found |
| `cleanup` | option 2→3/4 | 一次跑完 scan →（resync）→ delete → poll → 重掃 |
| `report` | **option 5** | 產出 JSON（含所有原始物件）+ Broadcom Support 會要的資訊清單 |

**option 1（UI：選主機 > REMOVE NSX > 勾 Force Delete）** 沒有做成子命令 —— 那是 UI 操作，
而且 `delete` 打的就是同一條 API。UI 跑不動時才需要這支。

> 🔴 **沒加 `--yes` 就是 dry run，不會刪任何東西。** `scan` / `state` / `report` 永遠是唯讀。

---

## 用法

```bash
python kb319975_stale_host.py -n <nsx-manager-or-vip> --insecure scan <host>
```

`<host>` 可以是 display name、FQDN、短名、IP 或 transport node UUID —— 都會比對到。
不帶 `-n` / `<host>` / 密碼時會互動式問（客戶不用記旗標）：

```
NSX Manager IP or FQDN: nsx-mgr.corp.local
ESXi host name / FQDN / IP: esx04.corp.local
Password for admin@nsx-mgr.corp.local:
```

密碼也可以用環境變數 `NSX_PASSWORD`（`NSX_USER` 預設 `admin`）。
NSX 預設是自簽憑證 → 要嘛 `--insecure`，要嘛 `--ca-bundle <pem>`。

### 1. 先診斷

```bash
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure scan esx04.corp.local
```

輸出會長這樣（實測 mock 輸出）：

```
transport_nodes (1)
  SOURCE                      ID                                    DISPLAY NAME       IP          STATE
  Manager API transport node  11111111-2222-3333-4444-555555555555  esx04.corp.local   10.0.1.14   EXISTS state=failed (8060)

policy_host_transport_nodes (1)
  Policy API host transport node  esx04.corp.local  esx04.corp.local              EXISTS state=in_progress

search_index (3)
  ...

Recommended next step(s):
  * KB option 3 (Manager API): force delete the transport node -- `delete --api manager --id <uuid> --yes`.
  * KB option 4 (Policy API): force delete the host transport node -- `delete --api policy --id <node_name> --yes`.
```

**為什麼要分開看 search index**：NSX UI 和 SDDC Manager precheck 讀的是 search index。
只有 index 有、Manager / Policy API 都查不到 → 這就是 KB option 2 的教科書案例，
要跑 `resync` 而不是去刪東西（刪也沒東西可刪）。

### 2. option 2：search 重建索引

```bash
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure resync esx04.corp.local --yes
```

會從 `/api/v1/cluster/nodes/status` 自動撈出三台 manager 的 IP（也可以 `--managers ip1,ip2,ip3`
手動指定），SSH 以 `admin` 登入逐台下指令，然後等 `--reindex-wait`（預設 600 秒 = KB 要求的
最少 10 分鐘）再重掃。還在 → KB 說接著跑 `--all`：

```bash
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure resync esx04.corp.local --all --yes
```

### 3. option 3 / 4：force delete

> ⚠️ **install 失敗的情境，KB 要求先在 vSphere 把失敗的主機移到 standalone（移出叢集）再做這步。**
> upgrade 失敗的情境沒有這個前置。

```bash
# 先 dry run 看它要刪什麼
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure delete esx04.corp.local

# 真的刪（會再要你手打 delete 確認；自動化情境加 --no-confirm）
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure delete esx04.corp.local --yes
```

- 一律帶 `force=true&unprepare_host=false`（跟 KB 一致，**不會**去動主機上的 VIB）
- 刪完每 `--poll-interval`（預設 300 秒）poll 一次 state，直到 **Object not found**；
  超過 `--poll-timeout`（預設 3600 秒）還在 → 升級成 option 5
- 只想刪一邊：`--api manager` / `--api policy`；已經知道 UUID：`--id <uuid>`

🔒 **安全閘**：如果某筆記錄的 state 是 `success`（看起來是**還活著的** transport node），
script 會直接拒刪，要確認主機真的已經不在 vCenter 了，再加 `--force-anyway`。

### 4. 一次跑完

```bash
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure cleanup esx04.corp.local \
    --with-resync --yes --no-confirm
```

`scan` →（`--with-resync` 才跑 option 2）→ `delete` → poll → 重掃。
最後還有殘留會把下一步建議印出來。

### 5. option 5：要開 case 了

```bash
python kb319975_stale_host.py -n nsx-mgr.corp.local --insecure report esx04.corp.local
```

產出 `kb319975-out/kb319975-report-<時間>.json`（含所有查到的原始物件）+ KB 要求提供的清單：
NSX 版本、失敗是在 upgrade 還是 install、已經做過哪幾個 option、NSX Manager / ESXi log bundle、
確切錯誤訊息與截圖。

每次執行的 console 輸出也會留在 `--out-dir`（預設 `kb319975-out/`）下的 log 檔，`--no-log-file` 關掉。

---

## 離開 API 範圍的兩件事（KB 特別提到，script 不碰）

| 情境 | 做法 |
|---|---|
| **Security-only cluster** | 不能 detach transport node profile。要嘛整個叢集移除 NSX，要嘛把主機移到 datacenter 層級 |
| **vLCM 叢集** | 可能要在**主機上**手動移 VIB：`nsxcli -c del nsx`（ESXi shell） |

這兩項都要在 ESXi / vCenter 上動手，不在 NSX Manager API 範圍內，所以沒做進 script；
`scan` 查不到任何殘留時會提醒往這個方向查。

---

## 退出碼

| 碼 | 意思 |
|---|---|
| 0 | 乾淨 / dry run 正常結束 |
| 1 | 參數、連線、認證錯誤，或被安全閘擋下 |
| 2 | 還有殘留記錄（`scan` / `state` 查到東西，或刪完 poll 不過） |
| 130 | Ctrl-C |

適合塞進 precheck 腳本：`scan` 回 0 才往下走。

---

## 驗證狀態

- 流程（scan / state / resync dry-run / delete + poll / cleanup / report / 安全閘）已用
  **本機 mock NSX Manager** 端到端跑過，包含 404 `error_code 600` 的 Object-not-found 判定、
  cursor 分頁、`force=true&unprepare_host=false` 參數檢查。
- **尚未對真實 NSX Manager 驗過**（lab 當時關機）。第一次對真機用，請先只跑 `scan`。
