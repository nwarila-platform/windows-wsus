# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
local v3.1.0 generic loader (`tasks/main.yml`) and a family-level
`present_windows.yml` / `clean_windows.yml`.

Disk provisioning is delegated to the framework's `windows_disk_manager` role. The
playbook must run that role before `wsus`; this role consumes the provisioned volumes
through configured drive letters and drive-qualified paths, and does not select,
initialize, partition, or format disks.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

### Required WSUS input

| `wsus:` override key | Consumed as | Fixed target |
|----------------------|-------------|--------------|
| `upstream_server` | `config.upstream_server` | Upstream WSUS server this host syncs from (downstream/replica topology; `SyncFromMicrosoftUpdate=false`). **Required** — `validate.yml` fails the play if empty/undefined. Hostname of the upstream WSUS; connection policy (port/SSL/replica) is in `sync.*` defaults below. |

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

The identities above are specific to the repository's VMware lab. Replace them with
the target host's stable disk identities when using the role elsewhere.

The letters in `wsus_defaults.data_disks`, or their effective `wsus:` overrides, must
match the disk-manager declaration. The IIS letter must also match the drive prefixes
in `iis.log_dir` and `iis.wwwroot`; `data_disks.iis.drive_letter` does not derive those
paths. Nothing enforces these cross-role and cross-key relationships. If a mismatched
database, content, or IIS path names an existing volume, the role puts that data on
the wrong volume without failing.

For disks that it provisions, `windows_disk_manager` owns selection, safety
classification, initialization, partitioning, drive-letter assignment, and
formatting. An adopted NTFS volume with the declared label is accepted without
reconciling its drive letter, allocation-unit size, partition count, or additional
volumes. Ensure adopted volumes already have the declared letters before running
`wsus`.

### Merged configuration

The role detects greenfield vs adopt from the presence of a complete SUSDB on the data volume;
there is no mode flag.

| `wsus_defaults` key | Default | Purpose |
|---------------------|---------|---------|
| `data_disks.db.drive_letter` | `E` | Drive used to form the WID/database target path |
| `data_disks.content.drive_letter` | `F` | Drive used to form the WSUS content target path |
| `data_disks.iis.drive_letter` | `G` | IIS-purpose letter checked for distinctness with the database and content letters; `iis.log_dir` and `iis.wwwroot` remain the actual IIS path targets |
| `iis.log_dir` | `G:\inetpub\logs\LogFiles` | Where IIS writes its site logs — on the IIS disk, not the system drive (STIG "IIS on its own drive"). Must be a **literal** drive-qualified path (a `%SystemDrive%`-style token is treated as drift). The role repoints the global `siteDefaults` and every site's `logFile.directory` here. |
| `iis.wwwroot` | `G:\inetpub\wwwroot` | Active IIS web root, relocated to the IIS disk. Must be a **literal** drive-qualified path (a `%SystemDrive%`-style token is rejected). The role copies the current wwwroot content, repoints the `InetStp` `PathWWWRoot` registry value (native and Wow6432Node) and the **Default Web Site** `physicalPath` here; the WSUS Administration site under Program Files is untouched. |
| `iis.log_target_w3c` | `File,ETW` | IIS W3C log event destination (STIG V-218786). `File` keeps the file logs; `ETW` adds a real-time event emit. Set on site defaults and every site. Valid: `File`, `ETW`, `File,ETW`. |
| `iis.custom_log_fields` | Connection / Warning / Authorization / Content-Type | STIG-required W3C **custom** log fields (V-218788/9) — a separate collection from the standard fields, so the complete standard set does not cover them. Each is `{field, source, source_type}` (`RequestHeader`/`ResponseHeader`). Override to add fields. |
| `iis.log_retention_days` | `90` | IIS has no built-in W3C log retention; the scheduled cleanup task deletes `*.log` older than this under `iis.log_dir`. Override per records-retention needs. |
| `iis.log_cleanup_schedule` | `{day: sunday, time: '02:00', time_limit: PT1H}` | Weekly off-hours schedule for IIS log cleanup (`day`, target-local `HH:MM`, ISO-8601 `time_limit`). The default sits between the 00:00 monthly WSUS cleanup and the 03:00 weekly reindex. |
| `iis.config_channel_enabled` | `true` | Enable the `Microsoft-IIS-Configuration/Operational` event channel, which records IIS configuration changes. Set `false` to opt out. |
| `iis.config_channel_max_bytes` | `20971520` | Maximum size in bytes (20 MB) for the IIS configuration event channel. |
| `content_subdir` | `WSUS` | WSUS content folder name; the role forms the content root as `<content drive letter>:\<content_subdir>` (for example, `F:\WSUS`), and `wsusutil postinstall` creates `WSUSContent` inside it |
| `db_subdir` | `WID\Data` | SUSDB relocation target name; the role forms `<db drive letter>:\<db_subdir>` (for example, `E:\WID\Data`) and relocates `SUSDB.mdf` and `.ldf` there |
| `wsuspool.queue_length` | `2000` | WsusPool IIS app-pool request queue length (Microsoft best practice, up from 1000) |
| `wsuspool.private_memory_kb` | `0` | WsusPool private-memory recycle limit in KB; `0` = unlimited (Microsoft's value for a dedicated WSUS host). Override with a finite value on a shared host. |
| `wsuspool.virtual_memory_kb` | `0` | WsusPool virtual-memory recycle limit in KB; `0` = unlimited |
| `wsuspool.periodic_restart` | `00:00:00` | WsusPool periodic-restart interval (`hh:mm:ss`); `00:00:00` disables the default 29-hour recycle |
| `wsuspool.idle_timeout` | `00:00:00` | WsusPool idle timeout (`hh:mm:ss`); `00:00:00` disables idle shutdown |
| `wsuspool.pinging_enabled` | `false` | WsusPool worker-process pinging; `false` stops IIS killing a busy worker |
| `maintenance.dir` | `C:\ProgramData\wsus-maintenance` | Role-managed directory holding the SUSDB maintenance scripts and their timestamped run logs |
| `maintenance.reindex_schedule.day` | `sunday` | Day of the week the scheduled SUSDB reindex runs |
| `maintenance.reindex_schedule.time` | `03:00` | Target-local `HH:MM` for the reindex |
| `maintenance.reindex_schedule.time_limit` | `PT2H` | ISO-8601 duration bounding a hung or lock-blocked reindex run |
| `maintenance.cleanup_operations` | the 6 Microsoft operations | WSUS Server Cleanup operations the scheduled cleanup runs; each value is validated against the role's allowlist. Override to a subset. |
| `maintenance.cleanup_schedule.week` | `1` | Week of the month for the monthly cleanup (`1` = first) |
| `maintenance.cleanup_schedule.day` | `sunday` | Day of the week the monthly cleanup runs |
| `maintenance.cleanup_schedule.time` | `00:00` | Target-local `HH:MM` for cleanup; the default leaves an hour before the weekly reindex |
| `maintenance.cleanup_schedule.time_limit` | `PT2H` | ISO-8601 duration bounding a hung cleanup run |
| `sync.update_languages` | `['en']` | Languages whose updates WSUS syncs and downloads. The role disables the all-languages default and restricts it to this set before the first sync. |
| `sync.bootstrap_accept_timeout_sec` | `120` | Maximum seconds to confirm that the one-time category bootstrap sync was accepted. The role records a durable per-server marker and does not wait for the WAN-bound sync to complete. |
| `sync.upstream_port` | `8530` | Port of the upstream WSUS server (`8530` HTTP or `8531` HTTPS) |
| `sync.upstream_use_ssl` | `false` | Whether to sync from the upstream WSUS over SSL |
| `sync.replica` | `true` | `true` creates a replica downstream that mirrors the upstream's selections and approvals; `false` creates an autonomous downstream that manages its own approvals |

The role also deploys three Event Viewer custom views under
`%ProgramData%\Microsoft\Event Viewer\Views\`: **WSUS**, **IIS - WsusPool**, and
**WID - SUSDB**. They appear under **Custom Views** the next time Event Viewer opens.

The required `upstream_server` and `temp_dir` workaround must co-locate in one `wsus:`
declaration. The loader reads `temp_dir` from the raw `wsus` var, and Ansible does not
merge role override dicts across precedence levels; a higher-precedence `wsus:` value
replaces the whole mapping.

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Pinned framework containing `windows_disk_manager`, invoked before `wsus`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds described in
  the [tech debt register](../../../docs/TECH-DEBT.md).
