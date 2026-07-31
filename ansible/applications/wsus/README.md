# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
local v3.1.0 generic loader (`tasks/main.yml`) and a family-level
`present_windows.yml` / `clean_windows.yml`.

Disk provisioning is delegated to the framework's `windows_disk_manager` role. The
playbook must run that role before `wsus`; this role consumes the provisioned volumes
by drive letter and does not select, initialize, partition, or format disks.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

### Required WSUS input

| `wsus:` override key | Consumed as | Fixed target |
|----------------------|-------------|--------------|
| `upstream_server` | `config.upstream_server` | Upstream WSUS server this host syncs from (downstream/replica topology; `SyncFromMicrosoftUpdate=false`). **Required** (C11d) — `validate.yml` fails the play if empty/undefined. Hostname of the upstream WSUS; connection policy (port/SSL/replica) is in `sync.*` defaults below. |

### Disk provisioning

Declare `windows_disk_manager` separately in the playbook with the platform and every
managed disk's stable identity, drive letter, label, and allocation unit. Run it before
`wsus`:

```yaml
windows_disk_manager:
  platform: 'vmware'
  disks:
    - unique_id: 'eui.6C7076230CC23C55000C2968C7AE5760'
      drive_letter: 'E'
      label: 'WSUSDB'
      allocation_unit: 65536
    - unique_id: 'eui.CF4AE05CEB88F43B000C29656D55634B'
      drive_letter: 'F'
      label: 'WSUSDATA'
      allocation_unit: 4096
    - unique_id: 'eui.BC9F0ECE9FBC4B9A000C296303722FC1'
      drive_letter: 'G'
      label: 'WSUSIIS'
      allocation_unit: 4096

roles:
  - role: 'windows_disk_manager'
  - role: 'wsus'
```

The `wsus_defaults.data_disks.*.drive_letter` values must match the provisioner's
drive-letter declarations. No cross-role check enforces that equality. If a mismatched
WSUS letter names an existing volume, this role places the corresponding WSUS content
on the wrong volume without failing.

### Merged configuration

The role detects greenfield vs adopt from the presence of a complete SUSDB on the data volume;
there is no mode flag.

| `wsus_defaults` key | Default | Purpose |
|---------------------|---------|---------|
| `data_disks.db.drive_letter` | `E:` | Target drive letter for the WID/database disk |
| `data_disks.content.drive_letter` | `F:` | Target drive letter for the WSUS content disk |
| `data_disks.iis.drive_letter` | `G:` | Target drive letter for the IIS working-dir disk (`inetpub` relocated here). C12a |
| `iis.log_dir` | `G:\inetpub\logs\LogFiles` | Where IIS writes its site logs — on the IIS disk (G:), not the system drive (STIG "IIS on its own drive"). Must be a **literal** drive-qualified path (a `%SystemDrive%`-style token is treated as drift). The role repoints the global `siteDefaults` + every site's `logFile.directory` here. C12b |
| `iis.wwwroot` | `G:\inetpub\wwwroot` | Active IIS web root, relocated to the IIS disk (G:). Must be a **literal** drive-qualified path (a `%SystemDrive%`-style token is rejected). The role copies the current wwwroot content, repoints the `InetStp` `PathWWWRoot` registry value (native + Wow6432Node) and the **Default Web Site** `physicalPath` here — the WSUS Administration site (Program Files) is untouched. C12c |
| `iis.log_target_w3c` | `File,ETW` | IIS W3C log event destination (STIG V-218786). `File` keeps the G: file logs; `ETW` adds a real-time event emit. Set on siteDefaults + every site. Valid: `File`, `ETW`, `File,ETW`. C13e |
| `iis.custom_log_fields` | Connection / Warning / Authorization / Content-Type | STIG-required W3C **custom** log fields (V-218788/9) — a separate collection from the standard fields, so the complete standard set does not cover them. Each is `{field, source, source_type}` (`RequestHeader`/`ResponseHeader`). Override to add fields. C13d |
| `iis.log_retention_days` | `90` | IIS has no built-in W3C log retention; the scheduled cleanup task deletes `*.log` older than this (in days) under `iis.log_dir`. Override per records-retention needs. C13f |
| `iis.log_cleanup_schedule` | `{day: sunday, time: '02:00', time_limit: PT1H}` | Weekly off-hours schedule for the IIS log cleanup (`day`, target-local `HH:MM`, ISO-8601 `time_limit`). 02:00 sits between the 00:00 monthly WSUS cleanup and the 03:00 weekly reindex. C13g |
| `iis.config_channel_enabled` | `true` | Enable the `Microsoft-IIS-Configuration/Operational` event channel (logs IIS config changes — a web-shell/config-tamper signal; operational-class, retention-safe). Set `false` to opt out (the role then skips it). C13i |
| `iis.config_channel_max_bytes` | `20971520` | Max size (bytes, 20 MB) for that channel; mirrors the App/System event-log sizing. C13i |

**Event Viewer custom views (C13h):** the role deploys three pre-built views to `%ProgramData%\Microsoft\Event Viewer\Views\` — **WSUS** (Application / `Windows Server Update Services`), **IIS - WsusPool** (System / WAS + W3SVC), **WID - SUSDB** (Application / `MSSQL$MICROSOFT##WID`) — for meaningful operational visibility. They appear under **Custom Views** the next time Event Viewer opens.
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

`windows_disk_manager` owns disk selection, safety classification, initialization,
partitioning, drive-letter assignment, and formatting. The `wsus` role begins at the
drive-letter seam and owns only application data and configuration on those volumes.

The required `upstream_server` and `temp_dir` workaround must co-locate in one `wsus:`
declaration. The loader reads `temp_dir` from the raw `wsus` var, and Ansible does not
merge role override dicts across precedence levels; a higher-precedence `wsus:` value
replaces the whole mapping.

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
