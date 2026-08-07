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
| `bucket` | `config.bucket` | Artifact bucket holding the TLS PFX (+ password) at `tls.pfx_key`. **Required** whenever `tls.enabled` (the default) — no default exists. The playbook derives it from the controller-imported account id. |
| `upstream_server` | `config.upstream_server` | Upstream WSUS server this host syncs from (downstream/replica topology; `SyncFromMicrosoftUpdate=false`). **Required** — `validate.yml` fails the play if empty/undefined. Hostname of the upstream WSUS; connection policy (port/SSL/replica) is in `sync.*` defaults below. |

### Disk provisioning

Declare `windows_disk_manager` separately in the playbook with the platform and every
managed disk's stable identity, drive letter, label, and allocation unit. Run it before
`wsus`:

```yaml
windows_disk_manager:
  platform: 'aws'
  disks:
    - function: 'WSUSDB'
      drive_letter: 'E'
      label: 'WSUSDB'
      allocation_unit: 65536
    - function: 'WSUSDATA'
      drive_letter: 'F'
      label: 'WSUSDATA'
      allocation_unit: 4096
    - function: 'WSUSIIS'
      drive_letter: 'G'
      label: 'WSUSIIS'
      allocation_unit: 4096
```

Each `function` names the EBS volume's Function tag declared in `terraform/aws.tfvars`;
the role resolves the attached disk itself at run time.

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
| `content_subdir` | `WSUS` | WSUS content folder name; the role forms the content root as `<content drive letter>:\<content_subdir>` (for example, `F:\WSUS`), and `wsusutil postinstall` creates `WSUSContent` inside it |
| `db_subdir` | `WID\Data` | SUSDB relocation target name; the role forms `<db drive letter>:\<db_subdir>` (for example, `E:\WID\Data`) and relocates `SUSDB.mdf` and `.ldf` there |
| `wsuspool.queue_length` | `2000` | WsusPool IIS app-pool request queue length (Microsoft best practice, up from 1000) |
| `wsuspool.private_memory_kb` | `0` | WsusPool private-memory recycle limit in KB; `0` = unlimited (Microsoft's value for a dedicated WSUS host). Override with a finite value on a shared host. |
| `wsuspool.virtual_memory_kb` | `0` | WsusPool virtual-memory recycle limit in KB; `0` = unlimited |
| `wsuspool.periodic_restart` | `00:00:00` | WsusPool periodic-restart interval (`hh:mm:ss`); `00:00:00` disables the default 29-hour recycle |
| `wsuspool.idle_timeout` | `00:00:00` | WsusPool idle timeout (`hh:mm:ss`); `00:00:00` disables idle shutdown |
| `wsuspool.pinging_enabled` | `false` | WsusPool worker-process pinging; `false` stops IIS killing a busy worker |
| `tls.enabled` | `true` | Serve WSUS over HTTPS: deliver + import the CA-issued PFX, bind it to `tls.port` in IIS, set Require-SSL on the five client-facing vdirs, and run `wsusutil configuressl` |
| `tls.dns_name` | `''` | FQDN `configuressl` writes into the client-facing URLs; must match the certificate subject. Empty means the machine's computer name |
| `tls.thumbprint` | `''` | Trust-but-verify pin: when set, the imported certificate must match this SHA-1 thumbprint — proving the S3 object was not modified or swapped. Empty skips the check (delivery still runs) |
| `tls.port` | `8531` | HTTPS port WSUS serves on |
| `tls.pfx_key` | `applications/windows-wsus/tls/wsus.nwarila.internal.pfx` | Object key of the PFX inside the playbook-supplied `bucket`; its password sits beside it at `pfx_key` + `.password` |
| `sync.update_languages` | `['en']` | Languages whose updates WSUS syncs and downloads. The role disables the all-languages default and restricts it to this set before the first sync. |
| `sync.bootstrap_accept_timeout_sec` | `120` | Maximum seconds to confirm that the one-time category bootstrap sync was accepted. The role records a durable per-server marker and does not wait for the WAN-bound sync to complete. |
| `sync.upstream_port` | `8530` | Port of the upstream WSUS server (`8530` HTTP or `8531` HTTPS) |
| `sync.upstream_use_ssl` | `false` | Whether to sync from the upstream WSUS over SSL |
| `sync.replica` | `true` | `true` creates a replica downstream that mirrors the upstream's selections and approvals; `false` creates an autonomous downstream that manages its own approvals |

The required `upstream_server` and `temp_dir` workaround must co-locate in one `wsus:`
declaration. The loader reads `temp_dir` from the raw `wsus` var, and Ansible does not
merge role override dicts across precedence levels; a higher-precedence `wsus:` value
replaces the whole mapping.

## Requirements

- Windows Server 2025 target over SSH, `ansible_shell_type` matching the OpenSSH
  `DefaultShell` (`cmd`, the Windows boot default — a PowerShell login shell mangles
  ansible's module bootstrap; proven live), elevated admin account, `become: false`.
- Pinned framework containing `windows_disk_manager`, invoked before `wsus`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds described in
  the [tech debt register](../../../docs/TECH-DEBT.md).
