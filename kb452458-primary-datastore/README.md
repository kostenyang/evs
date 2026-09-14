# KB 452458 → script

**KB**: Update the primary (principal) datastore of a cluster in the SDDC Manager inventory via REST API
([452458](https://knowledge.broadcom.com/external/article/452458))

SDDC Manager UI 不支援更換 **imported / converted cluster** 的 principal datastore。KB 的做法是匯出
domain inventory、改 `primaryDatastoreSourceId` / `primaryDatastoreType` / `primaryDatastoreName` 三個欄位、
再 `PUT` 回 `/inventory/extensions/vi/clusters`。

> ⚠ 這只改 SDDC Manager **控制面**的資料庫記錄。VM / FCD / PV 的 Storage vMotion、vCLS datastore、
> Content Library、Supervisor 儲存原則都要先手動做完，最後才跑這支。

## 檔案

| 檔案 | 用途 |
|---|---|
| `kb452458-primary-datastore.sh` | 在 SDDC Manager appliance 上以 `vcf` 使用者執行，`export` / `update` / `verify` / `rollback` 四個子命令 |

## 用法

```bash
scp kb452458-primary-datastore.sh vcf@<sddc-manager>:~/
ssh vcf@<sddc-manager>
```

```bash
# 1. 匯出（自動保留 ~/kb452458/domain.json.bak 供 rollback）
./kb452458-primary-datastore.sh export -d <domainId> -c <clusterId>

# 2. 更新（-m 是 vCenter 的 datastore MoRef，-t 是列舉值，-n 選填）
./kb452458-primary-datastore.sh update -d <domainId> -c <clusterId> -m datastore-1048 -t VMFS -n new-ds01

# 3. 驗證（印出公開 API 的檢查指令）
./kb452458-primary-datastore.sh verify -d <domainId> -c <clusterId>

# 出事就還原
./kb452458-primary-datastore.sh rollback -d <domainId> -c <clusterId>
```

- `domainId` / `clusterId`：`GET https://<sddc-manager>/v1/domains`、`/v1/clusters`
- datastore MoRef：`GET https://<vcenter>/api/vcenter/datastore`（回應的 `datastore` 欄位）
- `-t` 合法值：`VSAN VSAN_ESA VSAN_MAX VSAN_REMOTE NFS NFS41 FC VMFS VVOL VVOL_FC VVOL_ISCSI VVOL_NFS`
- `--kb-style`：改用 KB 原版的 `PUT /clusters`（body 為整份 `{clusters, esxis}`）；預設走 `PUT /clusters/{clusterId}` 只動該叢集
- `--yes`：略過互動確認
- 做完記得到 SDDC Manager UI 對該叢集執行 **Sync Changes**

## 端點行為（SDDC Manager 9.1.1 拆 `vcf-commonsvcs.jar` + 實測）

Controller `InventoryExtensionsViController`，`@RequestMapping("inventory/extensions/vi")`，走 SDDC Manager 本機 `http://localhost`，免 token。

| 端點 | 方法 | 行為 |
|---|---|---|
| `/domainInventory?domainIds=<id>` | GET | 回 `[DomainInventory]`，這就是 KB 的 domain.json |
| `/clusters` | GET | **400** `Request method 'GET' is not supported` |
| `/clusters` | PUT | body = DomainInventory，程式碼 `Validate.notEmpty(clusters)` **且** `notEmpty(esxis)`；缺 esxis → 500 `VCF_RUNTIME_ERROR` |
| `/clusters/{clusterId}` | PUT | body = 單一 Cluster 物件；200 無內容 |

- 更新語意：`TypedClientImpl.updateEntity` = `existsById` → `BeanUtils.copyProperties` → `repository.save`，**整筆覆寫**。
  匯出是 DB 忠實 dump（null 省略），所以「匯出 → 改 → 推回」是安全的；手寫最小 JSON 不安全。
- 9.1 的 `Cluster` 模型：`name` / `datacenter` / `primaryDatastoreName` / `ftt` 已標 `@Deprecated`，DB `cluster` 表沒有 `name` 欄。
  公開 API `/v1/clusters` 的 `name` 與 `primaryDatastoreName` 是從 vCenter 即時解析的，真正 load-bearing 的是
  `primaryDatastoreSourceId`（MoRef）+ `primaryDatastoreType`。
- 🔴 **enum 打錯不會報錯**：`primaryDatastoreType` 給 `VMFS_FC` 之類不存在的值，API 仍回 200，但欄位被寫成 `null`，
  之後 `/v1/clusters/{id}` 對該叢集回傳的所有欄位都是 `null`。腳本在送出前檢查列舉值、送出後重讀確認非 null。

## 實測狀態

在 SDDC Manager **9.1.1.0.25713928** 上跑過完整循環：`export` → `update`（單筆與 `--kb-style` 兩種）→ `verify` → `rollback`，
每步重讀 inventory 都符合預期，公開 API 於 rollback 後恢復正常。無效 enum 在腳本層被擋下。

**尚未驗證**：真實 imported cluster 的儲存更換後，SDDC Manager Add Host / Expand Cluster 工作流對新類型的檢核行為
（lab 只有管理域的 vSAN 叢集，沒有 imported cluster 可以真的換儲存）。
