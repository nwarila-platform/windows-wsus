# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
ansible-framework v3 generic loader (`tasks/main.yml`, byte-identical — never edit)
and a family-level `present_windows.yml` / `clean_windows.yml`.

**Status: build in progress.** BEGIN input guards are implemented; later logic lands
one command per cycle piece — see the build queue (repo root) for the build
queue.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

### Required inputs

The disk identifiers are declared in the `wsus:` override dict in the playbook,
`group_vars`, or `host_vars`. The loader merges that dict into the role configuration,
where the role consumes them as `config.wid_disk_id` and `config.wsus_disk_id`. They
are **not** top-level vars and are **not** nested under `wsus.data_disks.*`.

| `wsus:` override key | Consumed as | Fixed target |
|----------------------|-------------|--------------|
| `wid_disk_id` | `config.wid_disk_id` | WID/database disk, mapped to `E:` with label `WSUSDB` |
| `wsus_disk_id` | `config.wsus_disk_id` | WSUS content disk, mapped to `F:` with label `WSUSDATA` |
| `upstream_server` | `config.upstream_server` | Upstream WSUS server this host syncs from (downstream/replica topology; `SyncFromMicrosoftUpdate=false`). **Required** (C11d) — `validate.yml` fails the play if empty/undefined. Hostname of the upstream WSUS; connection policy (port/SSL/replica) is in `sync.*` defaults below. |

Each value is the case-sensitive Windows disk `unique_id` (for example,
`eui.<hex>`). Read it with PowerShell's `Get-Disk` `UniqueId` property or from
`community.windows.win_disk_facts` as the disk's `unique_id`. The role requires one
exactly matching attached disk for each identifier. Drive letters, labels, and
filesystem conventions are documented here for the fixed mapping but land as
consumed configuration one cycle piece at a time.

### Merged configuration

| `wsus_defaults` key | Default | Purpose |
|---------------------|---------|---------|
| `data_disks.db.drive_letter` | `E:` | Target drive letter for the WID/database disk |
| `data_disks.content.drive_letter` | `F:` | Target drive letter for the WSUS content disk |
| `data_disks.db.label` | `WSUSDB` | NTFS volume label for the WID/database disk (E:) |
| `data_disks.db.allocation_unit` | `65536` | NTFS allocation unit (bytes) for E: — 64 KiB, MS SQL/WID storage best practice |
| `data_disks.content.label` | `WSUSDATA` | NTFS volume label for the WSUS content disk (F:) |
| `data_disks.content.allocation_unit` | `4096` | NTFS allocation unit (bytes) for F: — 4 KiB NTFS default (MS is silent on WSUS-content cluster size) |
| `content_subdir` | `WSUS` | WSUS content folder name; the role forms the content root as `<content drive letter>:\<content_subdir>` (e.g. `F:\WSUS`); `wsusutil postinstall` (C05) creates `WSUSContent` inside it |
| `db_subdir` | `WID\Data` | SUSDB relocation target dir name; the role forms `<db drive letter>:\<db_subdir>` (e.g. `E:\WID\Data`); C06 relocates `SUSDB.mdf`/`.ldf` there |
| `wsuspool.queue_length` | `2000` | WsusPool IIS app-pool request queue length (MS best-practice, up from 1000). C08 |
| `wsuspool.private_memory_kb` | `0` | WsusPool private-memory recycle limit in KB; `0` = unlimited (MS value for a **dedicated** WSUS host). Override with a finite KB value on a shared/co-located host. C08 |
| `wsuspool.virtual_memory_kb` | `0` | WsusPool virtual-memory recycle limit in KB; `0` = unlimited. C08 |
| `wsuspool.periodic_restart` | `00:00:00` | WsusPool periodic-restart interval (`hh:mm:ss`); `00:00:00` disables the default 29-hour recycle. C08 |
| `wsuspool.idle_timeout` | `00:00:00` | WsusPool idle timeout (`hh:mm:ss`); `00:00:00` disables idle shutdown. C08 |
| `wsuspool.pinging_enabled` | `false` | WsusPool worker-process pinging; `false` stops IIS killing a busy worker. C08 |
| `maintenance.dir` | `C:\ProgramData\wsus-maintenance` | Role-managed directory holding the SUSDB maintenance scripts (`SUSDBMaint.sql`, `Invoke-SusdbReindex.ps1`) + their timestamped run logs. C09 |
| `maintenance.reindex_schedule.day` | `sunday` | Day of the week the scheduled SUSDB reindex runs. C09b |
| `maintenance.reindex_schedule.time` | `03:00` | Target-local `HH:MM` for the reindex (off-hours). C09b |
| `maintenance.reindex_schedule.time_limit` | `PT2H` | ISO-8601 duration bounding a hung/lock-blocked reindex run (the scheduled task's execution time limit). C09b |
| `maintenance.cleanup_operations` | the 6 MS ops | WSUS Server Cleanup operations the scheduled cleanup runs (`DeclineSupersededUpdates`, `DeclineExpiredUpdates`, `CleanupObsoleteComputers`, `CleanupObsoleteUpdates`, `CleanupUnneededContentFiles`, `CompressUpdates`); each is validated against this allowlist. Override to a subset. C10 |
| `maintenance.cleanup_schedule.week` | `1` | Week-of-month for the monthly cleanup (`monthlydow` `weeks_of_month`; 1 = first). C10b |
| `maintenance.cleanup_schedule.day` | `sunday` | Day of the week the monthly cleanup runs (first `<day>` of the month). C10b |
| `maintenance.cleanup_schedule.time` | `00:00` | Target-local `HH:MM` for the cleanup; defaults to 00:00 to finish (within `time_limit`) before the 03:00 weekly reindex. C10b |
| `maintenance.cleanup_schedule.time_limit` | `PT2H` | ISO-8601 duration bounding a hung cleanup run. C10b |
| `sync.update_languages` | `['en']` | Languages (lowercase codes) whose updates WSUS syncs/downloads. The postinstall default is ALL languages (a large, wasteful scope); the role sets `AllUpdateLanguagesEnabled=false` and restricts to this set before the first sync. Override to add languages (e.g. `['en','fr']`). The update SOURCE stays Microsoft Update (postinstall default). C11a |
| `sync.bootstrap_accept_timeout_sec` | `120` | Max seconds to confirm the one-time category bootstrap sync was **accepted** (`StartSynchronizationForCategoryOnly` — status left `NotProcessing`, or a new sync-history entry appeared). Prove-started: the role confirms the sync started and writes a durable per-server marker, then does **not** block on the (~1–2hr, WAN-bound) full category sync — the usable product/classification catalog loads early and populates asynchronously. C11b |
| `sync.upstream_port` | `8530` | Port of the upstream WSUS server (`8530` HTTP / `8531` HTTPS). Connection policy for the required `upstream_server` input. C11d |
| `sync.upstream_use_ssl` | `false` | Sync from the upstream WSUS over SSL. C11d |
| `sync.replica` | `true` | `IsReplicaServer`: `true` = **replica** downstream mirroring the upstream's product/classification selections **and** approvals (inherit-everything, no local management); `false` = autonomous downstream that syncs metadata from the upstream but manages its own approvals. C11d |

The role provisions a declared disk only when it is RAW or already carries its target
drive letter. It refuses an initialized disk carrying a foreign drive letter, which
protects existing data and prevents an identifier mistake from selecting the OS/system
disk with `C:`. Disk size is never used for selection. C02e NTFS-formats E:/F: with these labels +
allocation units (WSUSDB at 64 KiB, WSUSDATA at 4 KiB).

The identifiers and `temp_dir` must co-locate in one `wsus:` declaration. The loader
reads `temp_dir` from the raw `wsus` var, and Ansible does not merge role override
dicts across precedence levels; a higher-precedence `wsus:` value replaces the whole
mapping.

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
