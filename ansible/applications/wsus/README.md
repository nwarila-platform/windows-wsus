# `wsus` role

Brings up Windows Server Update Services on a co-located SQL Server instance, serving its clients
over TLS. In one converge it pins the instance's default database directories and restarts it so
they take effect, installs the WSUS features, adopts a preserved `SUSDB` when the volume already
carries one, completes post-installation against the instance, brings up the services that answer
for it, delivers and installs the certificate the listener presents, requires SSL on the five
vendor-named virtual directories, scopes the host firewall to the estate and removes the
wide-open rules WSUS opened for itself, reconciles where update content is kept and who may read
it, restricts the languages the server will accept, points the server at its upstream, and
synchronises the catalogue and the files behind it.

Everything that arrives from S3 moves through the controller: the certificate, its password and
the public half are fetched, digest-checked and handed over the existing connection, so the guest
never receives cloud credentials. In this deployment it has no route to S3 at all.

> **Scope: one server, one co-located default SQL instance.** The AWS images install the default
> `MSSQLSERVER` instance; the role writes that name where it needs a service and the machine name
> where it needs a connection target. There is no instance-name input, and deliberately so --
> offering one would be offering a choice the rest of the role does not honour.
> Replica topology is the shipped default — approvals are made once, upstream, and inherited.

## Composition and prerequisites

The role is overlaid into a version-pinned checkout of `nwarila-platform/ansible-framework` at run
time; it is not run directly from this repository. The shipped `ansible/playbooks/wsus-aws.yml`
composes the framework's `host_readiness`, `os_bootstrap`, `remote_client`, `domain_member` and
`windows_disk_manager` onto the host, and `wsus` last.

The target must be Windows Server with SQL Server already installed and two volumes this role
can be given — one for the database, one for the update store — and with the `ansible.windows`
and `community.windows` modules the role uses. The controller's Ansible environment needs the
`amazon.aws` collection with supported `boto3`/`botocore` for the S3 fetch.

The volumes themselves are Terraform's -- `terraform/aws.tfvars` declares them as EBS devices --
and `windows_disk_manager` is what formats the attached disks and assigns the drive letters this
role is then given. Nothing here can fall back to the system volume if they are missing:
`tasks/validate.yml` refuses any letter outside `D`-`Z`, so `C:` cannot be named, and creating a
directory on a volume that does not exist fails loudly on the guest rather than landing somewhere
else.

## What the caller supplies

Deployment-specific inputs carry an account id, a certificate identity or a network topology, and
they change with every site, so the playbook states them where a reader can see them rather than
defaulting them in the role. `meta/main.yml` names all thirteen, and gives the reason where the
answer is not obvious from the key. `tasks/validate.yml` enforces them on the controller before
the role's first mutation -- the loader gathers facts from the guest first, so this is the gate in
front of every change, not in front of every contact. The nine certificate leaves are required
when `wsus.tls.enabled` is true, which is the shipped default; the other four are required
always.

Two drive letters (database and content, refused if equal), the upstream WSUS server, the networks
the host firewall admits, and nine keys describing the certificate: bucket, DNS name, the three
object keys, their three digests, and the thumbprint the listener is pinned to.

The digests are checked on the **controller**, because that is where the objects land and where
the credential to fetch them exists. The thumbprint is separate from the digests on purpose: a
digest proves an object is the one that was declared, and a thumbprint proves the listener
presents the certificate that was meant rather than whichever one a subject search happened to
find.

## Configuration

Values a deployer can meaningfully choose live in `defaults/main.yml`: the layout inside the
volumes the role is given, the update languages the estate will accept, the upstream link's port
and transport, the synchronisation timeouts, the HTTP port, and the TLS port, site and secured
paths.

What does **not** live there is constants wearing a default's clothes. The features WSUS is made
of, the flags its post-installation writes, the services that answer for it, the registry keys
Windows publishes and the default SQL instance are fixed by the product, not by a site, and are
written where they are used. The tell is `tasks/validate.yml`: a key it has to pin to one exact
value was never configuration, and every such key has been inlined rather than defended.

## Why the order is what it is

Two placements in `tasks/present_windows.yml` are load-bearing rather than tidy.

**The database directories are pinned first**, before the feature is even installed. `wsusutil
postinstall` creates `SUSDB` wherever the instance's default directories point, and moving it
afterwards is the unsupported detach/copy/attach path. Placement has to be right before anything
can create it, so the role pins the directories, grants the instance rights on them and restarts
the instance so it adopts them — and only then installs WSUS.

**TLS runs before every task that talks to the WSUS API.** Once `wsusutil configuressl` records
`UsingSSL=1`, every later bare `Get-WsusServer` dials this machine over HTTPS and validates what
it is presented, so the trust anchor has to already be in place when they run. Putting TLS last
would work on run one, when they still speak HTTP, and leave a host that had lost its anchor
unable to converge again — every run's first API read failing before reaching the region that
repairs it. It also keeps the two runs the same thing: both drive the API over the same
transport, rather than run one using HTTP and only run two exercising the path the estate uses.

## Serving clients over HTTPS

WSUS splits its client traffic across two ports, and the split is the product's, not a choice made
here. Metadata, authentication and reporting go over TLS on `wsus.tls.port`; update payloads are
served over plain **HTTP** on `wsus.firewall.http_port`, because they are Microsoft-signed and the
client verifies them itself. Measured on the target, the `Content` virtual directory carries no
SSL requirement; requiring one there is what breaks content delivery, which is why it is not in
`secured_paths`.

`wsus.tls.secured_paths` therefore names five directories — `ApiRemoting30`, `ClientWebService`,
`DssAuthWebService`, `ServerSyncWebService`, `SimpleAuthWebService` — and stops. Those are the
five Microsoft's own instructions name. The site serves more, and each of the others is
deliberately absent: `Content` and `SelfUpdate` break when secured, and `Inventory` and
`ReportingWebService` are simply not endpoints the vendor asks to be secured. Naming the five
rather than deriving the list from what is installed is also what makes the role indifferent to
which of the others a given image happens to ship — `SelfUpdate` tracks the WSUS patch level, not
the OS version, and is present on one image here and absent on the other.

The public half of the certificate is delivered as its own object rather than re-used from the
PFX, because this server must **trust** the certificate as well as serve it: with `UsingSSL=1`,
WSUS's own API calls go over HTTPS to this machine and .NET validates the chain. A self-signed
certificate is its own anchor, so without the public half in `Root` every converge after the first
fails on its first API read — the second run, the one that is supposed to be the proof. Shipping
it separately keeps the private key out of the `Root` store.

The delivery is wrapped in a block whose `always` removes both staging copies, controller first:
both hold the private key, but only the target copy can be stranded by an unreachable guest, so
the one that cannot be stranded is removed first.

## Who may reach the server

Measured on a live server, WSUS opens two inbound rules of its own at post-installation — both
named `WSUS`, TCP 8530 and 8531, with program `Any`, service `Any` and remote address **`Any`**.
That is the entire internet admitted to the update service. The role replaces them with two scoped
rules and then removes the vendor's, in that order, because Windows evaluates every matching allow
and the overlap keeps the service answering throughout.

The replacements are scoped three ways: to the two ports WSUS serves; to program `System`, because
the listener is HTTP.SYS in kernel mode and the sockets belong to PID 4 rather than to `w3wp.exe`;
and to `wsus.firewall.admitted_networks`. They are **not** scoped to a service, which is a limit
rather than an omission — no service owns a kernel-mode socket, so naming one would match nothing
and close the port to the clients the rule exists to admit. Windows' own built-in IIS rules leave
it unset for the same reason.

This is not the cloud security group repeated. A security group cannot see traffic arriving over a
VPN tunnel at all: it sees a UDP envelope, and the payload is decapsulated inside the guest past
every group rule. For everything reaching this server from the lab, the host firewall is not
defence in depth — it is the only defence there is.

The rules are written in the shape Windows writes its own — `<Product> (<PROTOCOL> Traffic-In)`, a
group, and a description ending `[TCP <port>]` — but saying WSUS things rather than IIS things, so
an administrator reading the rule list learns why the port is open and not merely that something
web-shaped wanted it.

## State

- `present` (default) — install and configure to the declared state.
- `absent` — **not implemented.** The framework loader resolves an OS task file per state and
  refuses the run by name when there is none, saying which files it searched. Removing WSUS means
  removing features, dropping `SUSDB` and deleting the content store on a host whose whole purpose
  is to be a WSUS server, and this deployment destroys the host instead. A file that only repeated
  the loader's refusal would be a second place to say one thing.
- `clean` — present and deliberately empty, and not because nothing is staged. The TLS delivery
  stages a PFX and a trust anchor on the guest and removes both in its own `always` block, so no
  persistent cache survives a converge for `clean` to remove.

## Design invariants

- **`SUSDB` never lands on the system volume.** Placement is pinned before anything can create the
  database, and `END` proves it by reading the system volume for stray database files.
- **The guest holds no cloud credential.** Every S3 object is fetched and verified on the
  controller.
- **Nothing asserts what it already controls.** Two clean runs are the proof; re-reading a value
  this role just wrote proves only that it can read itself. `END` reads the *engine* and the
  *filesystem*, which are the things that could disagree with it.
- **One HTTPS port.** `wsus.tls.port` is the only declaration of it; the firewall reads that value
  rather than carrying a second copy to disagree with.
- **Update languages are declared, not inherited.** A server installs accepting every language
  Microsoft publishes, which is a permanent cost in disk and sync time for content nobody will
  approve.

## First-class PowerShell

Guest-side logic a task cannot express cleanly is a first-class PowerShell script under `files/`,
written against the org `NWarila/powershell-template` and shipped with a Linux-runnable Pester
sibling: `Get-SqlDatabasePlacement.ps1`, `Invoke-SusdbAdoption.ps1`,
`Invoke-WsusSynchronisation.ps1`, `Set-AclGrant.ps1`, `Set-WsusContentLocation.ps1`,
`Set-WsusHttpsListener.ps1`, `Set-WsusUpdateLanguage.ps1` and `Set-WsusUpstream.ps1`, each beside
its `.pester.ps1`.

Unlike `pdq-deploy-inventory`, the scripts are tracked directly rather than materialised from
stubs: there is one consumer, so a second copy under `scripts/` would be a second thing to keep in
step. `.github/workflows/powershell.yml` runs the pinned `pester-matrix` harness, which discovers
every `<Name>.ps1` + `<Name>.pester.ps1` pair and runs it with the org's analyzer settings.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/compose-and-run.sh              # composes the pinned framework and runs wsus-aws.yml
(cd .compose/ansible-framework && ansible-lint applications/wsus)
# Pester runs in CI (the pinned powershell-template pester-matrix), one leg per files/ pair.
```

Idempotence is the acceptance criterion: a second converge against the same host must report
`changed=0`. Every actor in this role is written to be re-read rather than re-applied, which is
what makes that criterion meetable rather than aspirational.
