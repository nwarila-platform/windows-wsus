# nwarila-platform — Ansible style & design guide

The authoring rules the WSUS role being rebuilt will be written to. Each rule states the failure it
prevents, because most of them were learned from that failure rather than chosen in advance.

## 1. Repo & composition model

- One single-purpose role per application repo; the repo composes into a
  version-pinned `ansible-framework` checkout at execution time (`.github/ansible-framework-pin`,
  the compose step in `.github/workflows/aws-deploy.yml` and `scripts/compose-and-run.sh`). Roles
  must be drop-in compatible with the framework's
  `applications/` namespace (`roles_path` resolution by bare name).
- The framework is the chassis: `ansible.cfg`, lint configs, loader contract, CI
  conventions all originate upstream. Application repos copy `.yamllint.yml` /
  `.editorconfig` for local dev parity.

## 2. Naming

- Repo: `windows-wsus` (OS-prefixed product). Role: `wsus` (bare product name,
  resolves via framework `roles_path`). Playbook: `wsus-aws.yml`. Inventory group:
  `wsus_servers` (pluralized component, mirrors `wazuh_indexers`).
- Role defaults live under `<role>_defaults` in `defaults/main.yml`; the merged
  running config materializes as `<role>_running`; playbook overrides use the bare
  `<role>:` dict. (Loader v3 contract.)

## 3. Loader contract

- Every role must ship the framework's generic loader as `tasks/main.yml`,
  **byte-identical, never edited per-role**. Loader changes are governance-surface →
  upstream framework PR only.
- Every local loader is byte-identical to the loader at the current framework pin. A divergence
  is a release-blocking composition failure, not accepted application debt.
- Changes to the loader are upstream changes. It is shared by every consuming role, so a change
  that suits this one and not the others breaks the hash-match invariant that makes it shareable.
  The default answer to "should the loader change for us" is no.
- OS task files: `<state>_<family>[_<dist>[_<ver>]].yml`, resolved most-specific-first
  via `first_found`. This role ships `present_windows.yml` + `clean_windows.yml`
  (family-level; `os_family=Windows`).
- Vars overlays: `vars/<family>[_...][_<env>].yml`, recursive combine,
  `list_merge='replace'`. `ENV` is mandatory and regex-validated by the loader.

## 4. Task authoring idioms

- Task names: `'STAGE | Imperative description'` — stages observed: `INIT`, `MAIN`,
  `BEGIN` (input guards), `END` (verification), `Cleanup`, `INFO` (block wrappers).
- `#region` / `#endregion` banner comments delimit logical sections; files open with
  the boxed header comment (`File:`, description, version where applicable).
- Fully-qualified collection names always (`ansible.builtin.*`, `ansible.windows.*`).
- Asserts use `quiet: true` with actionable, templated `fail_msg`.
- Comments explain WHY (contract, failure modes), not what.
- Service/state verification: retry loops with explicit `retries`/`delay`/`until`
  rather than fixed sleeps (wazuh_agent END-stage pattern).
- **Avoid `set_fact` for role-internal derived/intermediate data.**
  `set_fact` registers HOST FACTS that persist for the rest of the play and BLEED into later
  roles (variable pollution + surprising precedence). Use scoped alternatives: block `vars:`
  (lazily evaluated, block-scoped), task `vars:`, or `register`. Reserve `set_fact` for values
  that persist BY CONTRACT (e.g. the loader's `<role>_running` merged config) and namespace them
  (`<role>_*` / `__dunder__`).

## 4a. Role scope — the "handed machine" contract

- **composed-play ownership amendment.** The owner
  of guest OS state is the **composed play and its ordered roles**, not a single
  application role. Its input contract is a machine handed to it as **OS + reachable
  SSH + attached-but-blank data disks** — exactly what a fresh Terraform-provisioned
  VM provides. Guest disk provisioning through drive-letter
  assignment belongs to a disk-manager role, which runs first; the
  application role consumes the resulting volumes by drive letter and owns application
  features, installation, configuration, and verification.
- **Boundary:** *hardware provisioning* (disk count/size/attachment, vCPU/RAM, NIC)
  belongs to the deploy layer (the pinned aws-terraform-framework
  later). *Guest OS state* belongs to the composed play and its ordered roles.
  Formatting a disk into the baseline image is FORBIDDEN — it must be role-declared
  code, proven on every clean revert.
- This intentionally **diverges from wazuh**, where storage prep is an operator/packer
  prerequisite outside the composed Ansible play. For nwarila-platform Windows app
  repos the composed play is the end-to-end configurator of the machine it is handed.
- Disk identification is **declarative by a stable per-disk identifier — never
  disk-number- nor size-coupled**. On AWS, the application
  declares a unique EBS `Function` tag; the shared disk manager resolves it to the attached
  volume id and the guest's Nitro serial. Other platforms may supply a native `unique_id`.
  Enumeration order and capacity are never identity.

## 4b. Guards earn their keep

**Prefer the Ansible action; assert only when load-bearing.** An assert is admitted only if
BOTH prongs clear:
- **(a) Don't assert what fails anyway.** Never pre-assert a precondition an Ansible action
  already fails loudly on — lean on that failure (the loader's `first_found` + "OS task file not
  found" enforces os_family; `win_initialize_disk` fails on an absent/bad `uniqueid`; the
  exactly-one resolution rejects a missing/empty id as "found 0"). A friendlier or earlier message
  for a state a module would reject anyway is NOT sufficient justification.
- **(b) Configure, don't assert.** Never assert a state you can idempotently CONFIGURE — configure
  it (`win_initialize_disk online:true` MAKES the disk online/writable; do not assert it is).
An assert is **RETAINED only** when a wrong state is **SILENT-WRONG or DESTRUCTIVE and no Ansible
action catches it before the damage** — e.g. two logical volumes declared onto one physical disk
(equal ids → both resolve to one disk → half-provisioned), or a foreign/occupied initialized disk
(`win_initialize_disk force:false` no-ops, then `win_partition -1` carves its free extent → silent
clobber, verified at the module source). These stay `quiet: true` with an actionable fail_msg.
(§4c is the destructive analog; §4a the identifier rule.)

**Guard / validate-stage shape:**
- The guard stage is **read-only on the target**: facts gathering, asserts, and **scoped
  resolution vars** — a block `vars:` attribute deriving a declared-spec → resolved-object from
  gathered facts (no mutation, and NEVER `set_fact`, which bleeds across roles — see §4). The
  first *mutating* task belongs to the piece that owns it, never a guard.
- Facts are gathered **once**, at the superset the load-bearing path needs; a mutating piece owns
  its own post-mutation refresh.
- Declarative resource selection resolves to **exactly one** match per declared spec (assert
  `length == 1`, enumerating fail_msg; then reuse the resolved object — never re-select with a bare
  `| first`). Zero and multiple are both hand-off failures. Declared specs must be mutually
  distinguishable (e.g. distinct identifiers).
- The declared CONFIG contract (post-merge `config.*`) is validated in ONE place where `config` is
  in scope — the role's `tasks/validate.yml`, run by the loader's
  `INIT | Validating Merged Configuration` hook — **never** `meta/argument_specs.yml` (structurally blind to the merged
  `config`; see §8).
- Guard pieces carry a negative proof (deliberately-wrong input fails on the intended assert;
  sibling specs still pass)..

## 4c. Mutation safety

- A piece that MUTATES a declared resource carries a **state-aware safety assert BEFORE
  the first mutation** — the destructive analog of the §4b read-only guard. It refuses
  to clobber a resource that does not match the managed layout, recognizing an
  already-managed target by a **declared convention** (for example, an NTFS volume's
  declared label), NEVER by size or enumeration number. Blank/RAW, already-ours, and
  positively recognized unformatted states proceed; a foreign/occupied state refuses
  loudly with an actionable `fail_msg`. Recognizing the declared label lets an adopted
  or converged volume pass, which a blank-only guard would wrongly reject.
- **named exception: the two disk-manager roles.** Both the pinned shared
  `windows_disk_manager`, which the play delegates to, and this repository's unreferenced
  `aws_windows_disk_manager` fork of it (TD-011) bring every declared disk online and writable
  before classifying observed state and asserting that none is foreign. Both reset and
  accumulate `__resolved_disks__` with `set_fact`, and both resolve each declared identity to
  exactly one match in an attachment guard that the later classifier repeats with `| first`.
  The exception is scoped to those two and was inherited verbatim from the fork point in the
  second. In both, the foreign-layout assert still precedes every provisioning module
  (initialize, partition, and format). The general §4, §4b, and §4c requirements remain
  unchanged for every other role written in this repository.

## 5. Windows conventions

- Transport: **SSH** (org standard; key auth, one transport story across the fleet).
  `ansible_shell_type: cmd`; the target's OpenSSH `DefaultShell` stays cmd (the boot default) — a
  PowerShell login shell re-parses ansible's module-bootstrap argv and breaks `-EncodedCommand`
  (proven live); `win_*` modules run inside their own PowerShell wrapper regardless.
- `become: false` at play level (framework chassis `become=sudo` is POSIX-only;
  built-in administrator over SSH is already elevated). Revisit for least-privilege
  runs (runas) when a non-admin service account is introduced — TBD.
- Windows modules from `ansible.windows` (fallback `community.windows`); never invoke
  raw PowerShell where a module exists — escape-hatch threshold decided at C05, see the
  escape-hatch rule below.
- The v3.3.0 loader guards POSIX-only package and temporary-directory paths on Windows. Do not
  restore the retired playbook fact seed or `temp_dir: false` workaround.
- **required per-target
  inputs live in the `<role>:` override dict, consumed via `config`.** Environment-
  specific inputs the role cannot default (for example, `upstream_server` for `wsus`
  or `disks[].function` for the AWS disk manager) are declared inside the
  corresponding `<role>:` override dict (playbook / group_vars / host_vars) and read
  from that role's `config`, matching the framework/wazuh idiom and the loader's
  `defaults -> overlays -> <role> override -> config` merge.
  Only `ENV`/`state` stay top-level (loader-level). NOTE: a `-e '{"<role>":{...}}'`
  override REPLACES the whole dict; it does not recursively merge with a playbook mapping.
  The README documents these values as merged config, not top-level vars.
- never `set_fact` the name `ansible_facts` — the resulting
  set_fact variable shadows the live facts store and silently hides every later
  facts module's results.
- **the escape-hatch policy.** Native module FIRST, always
  (C05 verified the gap empirically: 0 of 118 modules across `ansible.windows` +
  `community.windows` cover WSUS server ops). Where no module exists:
  1. `ansible.windows.win_command` in **`argv` form** is the sanctioned escape hatch
     (each element auto-quoted per Win32 rules — spaced paths are a non-issue; no shell
     parsing surface).
  2. `win_shell` ONLY for genuine shell semantics — e.g. a PowerShell **cmdlet**
     (`Get-WsusServer`), pipes, redirects. Never for plain .exe invocation.
  3. Idempotency: `creates:`/`removes:` ONLY when the marker reliably represents
     **completed** desired state. An artifact the command creates EARLY in its run does
     NOT qualify — a midway failure leaves it behind and every later run silently
     false-converges (C05/P2 rejected the community-standard `creates: ...\WSUSContent`
     for exactly this). Where no reliable completion file exists, use the
     **probe-gates-actor idiom**: a read-only registered probe
     (`changed_when: false`, `failed_when: false` — nonzero rc IS the signal, not an
     error) gating the mutating command via `when:` (C05: `Get-WsusServer` gating
     `wsusutil postinstall`; the UpdateServicesDsc model, implemented natively).
  4. No `chdir` when the tool has no working-directory requirement; invoke by absolute
     path. No asserts on undocumented/localizable stdout — rc + a functional probe are
     the contract.
- **embedded PowerShell follows OTBS.** Any
  multi-statement PowerShell inside a `win_shell` block scalar uses One True Brace Style:
  opening brace on the statement line; cuddled `} elseif (...) {` / `} else {`; multi-statement
  bodies on their own indented lines (4-space); NO semicolon statement-chaining; blank lines
  between logical sections. Idiomatic one-line pipeline filter blocks
  (`Where-Object { ... }`) stay inline — OTBS governs control statements.
- **the native-module template for `win_shell` §8 escape hatches.**
  Every mutating `win_shell` block that stands in for a missing native module MUST act like one:
  1. `$ErrorActionPreference = 'Stop'` is the FIRST statement (a mid-script non-terminating error
     must not pass silently).
  2. Inputs arrive via `environment:` (env-passing), NEVER Jinja-interpolated into the PowerShell
     source (`'{{ x }}'`) — env-passing removes an injection + `split_args` surface. Architectural
     constants (a database connection string, say) are defined ONCE in the task file's `vars:`
     block and env-passed, not duplicated per block.
  3. Any external resource (a `SqlConnection`) is opened inside `try { } finally { <close-only> }`
     — the `finally` closes and does nothing else (no `catch`, no swallow); intentional
     fail-closed `throw`s (e.g. Attach's DROP-on-unhealthy) stay inside `try` before the finally.
  4. Idempotency by a normalized compare → mutate-on-diff → **re-acquire-and-verify** → deterministic
     `changed`/`nochange` (or a read-only probe with `changed_when: false`), never blind mutation.
  5. Embedded PowerShell follows OTBS (above).
- **never put a backslash immediately before a closing quote
  (`\'` / `\"`) in `win_shell`/`win_command` free-form.** Ansible parses
  the free-form module arg with `split_args`, which honors `\` as an escape **even inside single
  quotes**.
  A literal backslash right before a closing quote — `Replace('/','\')`, `'IIS:\Sites\'`, `'C:\'` —
  escapes the quote, unbalances the parser, and fails the task at **LOAD time**
  (`failed at splitting arguments…`). Interior backslashes are fine (`'IIS:\Sites\Default Web Site'`);
  only backslash-adjacent-to-a-closing-quote breaks. **RULE:** build such strings with `[char]92`
  (`$dir.TrimEnd([char]92) + [char]92`) and never end a quoted literal with `\`. Nothing catches
  this statically: yamllint, ansible-lint, and `ansible-playbook --syntax-check` all pass an
  unbalanced-`\'` regression (proven 2026-07-17; it is exactly how the C12c bug shipped), which
  is why the rule is absolute rather than advisory.
- **Users browse-access ACL
  hygiene.** Role-created directories INTENDED FOR INTERACTIVE ADMINISTRATION/BROWSING,
  under an explicitly documented trust model ("all interactive users are admins"), get an
  explicit `BUILTIN\Users` ReadAndExecute grant (`win_acl`, allow,
  `ContainerInherit, ObjectInherit`) co-located with their creation. WHY: an unreadable
  folder makes Explorer offer "Continue", which stamps the browsing admin's PERSONAL ACE
  onto the ACL — stale/orphaned SIDs after they depart. Explicit, never inherited-by-luck
  (format-default root ACLs evaporate under hardening). EXCLUDED BY DEFAULT: secrets,
  private service data, product-managed ACL boundaries (e.g. WSUSContent — postinstall
  owns it).

## 6. Controller & toolchain

- The controller toolchain installs into a virtualenv from `requirements-quality.txt`, which pins
  `ansible-core`, `ansible-lint`, and `yamllint` exactly. Collections are pinned in
  `requirements-quality.yml`: `ansible.windows`, `community.windows`, and `amazon.aws`.
- Windows targets are never long-lived development state: every proof creates a fresh ephemeral
  instance with Terraform; the lab-era snapshot-revert workflow is retired.
- **Lint from the composed tree**: the playbook's roles resolve only inside the composed
  framework checkout, which also supplies the chassis `.ansible-lint` profile. Repo-side
  `ansible-lint <playbook>` fails `syntax-check` by design — do not "fix" that by vendoring a
  roles_path shim without a ratified rule.
- SSH connection state is isolated in each disposable runner. Stale local ControlMaster sockets
  must be removed before any manually operated proof.

## 7. Commits & process

- Conventional Commits. Scopes in use here include the role name, `ansible`, `iam`, `deps`, and
  `wsus`; unscoped commits are acceptable when a change is repository-wide.

## 8. Not covered here

- `meta/argument_specs.yml` is not used for enforcement. The auto-inserted validator runs BEFORE
  the loader builds the merged `config`, so it is structurally blind to `config.*` and only
  duplicates the loader's `ENV`/`state` assert. Merged-config validation lives in each role's
  `tasks/validate.yml` (§4b). An argument spec is permissible only as description-only
  documentation of the `<role>:` dict shape.
- Handler usage and service-restart conventions on Windows.
- A Molecule (or equivalent) test story for Windows roles.
- Secrets handling for Windows; this repository uses none.
