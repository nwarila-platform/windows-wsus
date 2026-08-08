# wsus role

Installs and verifies Windows Server Update Services backed by Windows Internal Database on
Windows Server 2025. The role carries the byte-identical v3.3.0 framework loader, merged-input
validation, Windows convergence, recovery guards, and an independent final verifier.

Disk selection and formatting belong to the framework's `windows_disk_manager` role. Run that
role first and feed both roles one shared layout, as `ansible/playbooks/wsus-aws.yml` does. This
role consumes already-provisioned volumes through their drive letters.

## Configuration model

The loader merges `wsus_defaults`, OS/environment overlays under `vars/`, and the playbook's
`wsus:` override into `wsus_running`, exposed to task files as `config`. Validation runs against
that effective mapping before target mutation.

Required deployment inputs are:

| Input | Contract |
|---|---|
| `wsus.upstream_server` | Non-empty downstream source hostname. The repository placeholder is rejected when bootstrap synchronization is enabled. |
| `wsus.bucket` | Artifact bucket containing the TLS PFX and adjacent `.password` object when TLS is enabled. |
| `wsus.tls.dns_name` | Desired client-facing FQDN used by `wsusutil configuressl`; it must equal the leaf's primary/preferred DNS identity or match its single-label wildcard. |
| `wsus.tls.thumbprint` | Exact 40-hex SHA-1 pin for the delivered leaf certificate when TLS is enabled; the leaf must explicitly include Server Authentication EKU OID `1.3.6.1.5.5.7.3.1`. |

The application letters must be three distinct `D` through `Z` values. `content_subdir` and
`db_subdir` must be relative, non-traversing names, and both IIS paths must be literal paths on the
declared IIS drive. These relationships are enforced before convergence.

After the initial post-install, the role treats the WSUS API content-cache path as authoritative.
If a later content drive or subdirectory change moves that path, it uses the supported
`wsusutil movecontent` operation without `-skipcopy`, then verifies the registry root, API cache
path, and IIS `Content` virtual directory before continuing. A registry-only split brain fails
closed instead of being hidden by a direct registry edit. The content cache also receives and
verifies the inheritable `NETWORK SERVICE` FullControl grant required by WSUS.

Example shared layout:

```yaml
wsus_disk_layout:
  db:
    function: WSUSDB
    drive_letter: E
    label: WSUSDB
    allocation_unit: 65536
  content:
    function: WSUSDATA
    drive_letter: F
    label: WSUSDATA
    allocation_unit: 4096
  iis:
    function: WSUSIIS
    drive_letter: G
    label: WSUSIIS
    allocation_unit: 4096
```

Each `function` must match the corresponding EBS `Function` tag in `terraform/aws.tfvars`.

## Effective defaults

| Key | Default | Purpose |
|---|---:|---|
| `data_disks.db.drive_letter` | `E` | Drive used for the SUSDB target directory |
| `data_disks.content.drive_letter` | `F` | Drive used for the WSUS content root |
| `data_disks.iis.drive_letter` | `G` | Drive required for both literal IIS paths |
| `db_subdir` | `WID\Data` | Relative SUSDB target directory |
| `content_subdir` | `WSUS` | Relative content root; postinstall creates `WSUSContent` beneath it |
| `iis.log_dir` | `G:\inetpub\logs\LogFiles` | Global and per-site IIS log location |
| `iis.wwwroot` | `G:\inetpub\wwwroot` | Relocated Default Web Site content root |
| `wsuspool.queue_length` | `2000` | WsusPool request queue length |
| `wsuspool.private_memory_kb` | `0` | Private-memory recycle limit; zero disables it |
| `wsuspool.virtual_memory_kb` | `0` | Virtual-memory recycle limit; zero disables it |
| `wsuspool.periodic_restart` | `00:00:00` | Periodic recycle interval; zero disables it |
| `wsuspool.idle_timeout` | `00:00:00` | Idle shutdown interval; zero disables it |
| `wsuspool.pinging_enabled` | `false` | Worker-process pinging policy |
| `tls.enabled` | `true` | Deliver, validate, import, bind, configure, and live-test HTTPS |
| `tls.port` | `8531` | WSUS HTTPS port |
| `tls.minimum_validity_days` | `45` | Reject a certificate too near expiry |
| `tls.pfx_key` | `applications/windows-wsus/tls/wsus.nwarila.internal.pfx` | Artifact object; password is `<pfx_key>.password` |
| `sync.update_languages` | `[en]` | Unique normalized languages enabled before bootstrap |
| `sync.bootstrap_enabled` | `true` | Require one terminal-success category synchronization |
| `sync.bootstrap_accept_timeout_sec` | `120` | Time allowed for WSUS to accept the request |
| `sync.bootstrap_completion_timeout_sec` | `5400` | Time allowed to reach terminal success |
| `sync.bootstrap_poll_sec` | `15` | Completion polling interval |
| `sync.upstream_port` | `8530` | Downstream source port |
| `sync.upstream_use_ssl` | `false` | Use TLS to reach the upstream |
| `sync.replica` | `true` | Mirror upstream selections and approvals |

The public AWS smoke play sets `sync.bootstrap_enabled: false` because its placeholder upstream is
deliberately unreachable. With a real reachable upstream, the role writes its durable marker only
after the category-only synchronization it started reaches terminal `Succeeded`. The marker includes
a configuration fingerprint, so changing the server or synchronization policy stops any older
in-flight work and requires a new successful invocation whose unique history ID, UTC start time, and
manual-start flag were not present before the role's request. The marker retains that history ID;
if WSUS expires the underlying record, the next run automatically performs fresh proof.

## Recovery and verification

Every run observes the attached SUSDB location and both source/target file pairs. The role repairs
only unambiguous partial targets, treats a complete attached target as authoritative even when an
interrupted cleanup left one source file behind, restores a complete healthy attachment after a
relocation failure, and refuses ambiguous unattached states. WID relocation is nevertheless
outside Microsoft's support guidance; see [TD-005](../../../docs/TECH-DEBT.md).

When an OS-volume replacement loses the post-install registry flags but retains the data volume,
the role performs that authority check before `wsusutil postinstall`: a sole complete target pair
is attached and health-checked first, while partial or competing pairs fail without creating or
deleting a database. Post-install then rebuilds the Windows/IIS metadata against the preserved
SUSDB instead of silently replacing it with a fresh system-volume database.

TLS artifacts use unique controller and target staging directories. Before import, the role checks
the private key, exact thumbprint, DNS identity, activation, minimum validity, and explicit Server
Authentication EKU (`1.3.6.1.5.5.7.3.1`). A leaf with no EKU extension is rejected rather than
treated as unrestricted. It binds the exact leaf to one wildcard, empty-host `*:port:` IIS listener
with non-SNI `sslFlags=0`, completes an HTTPS request to the WSUS client endpoint with the intended
SNI and Host header, and removes staging material in an `always` path. The machine-store probe and
independent final verifier enforce the same EKU contract; a converged target does not redeliver the
PFX on the second pass.

The final verifier independently checks WID's Automatic/Running service contract and the WSUS/IIS
service state, the registry/API/IIS content-path triple and required content ACLs, application paths,
upstream policy, all six declared WsusPool tuning values, IIS bindings and SSL requirements, the
pinned live certificate and its explicit Server Authentication EKU, and (when enabled) the
terminal-success bootstrap marker.

## Requirements

- Windows Server 2025 reached over OpenSSH with `ansible_shell_type: cmd`; the administrator
  account is already elevated and the play must use `become: false`.
- The pinned ansible-framework and its `windows_disk_manager` and artifact-delivery roles.
- Exact collection versions from `requirements-quality.yml`.
- Controller environment values `AWS_ACCOUNT_ID`, `AWS_REGION`, `GITHUB_REPOSITORY_ID`, and
  `GITHUB_RUN_ID`; the playbook preflight requires an exact numeric run identity.
