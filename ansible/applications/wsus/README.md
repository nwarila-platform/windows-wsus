# `wsus` role

Brings up Windows Server Update Services on a co-located SQL Server instance, serving its clients
over TLS. In one converge it uninstalls the SQL Server components WSUS does not use, pins the
instance's default database directories and restarts it so they take effect, installs the WSUS
features and the management consoles the deployment keeps, removes any it declines, adopts a
preserved `SUSDB` when the volume already carries one, completes post-installation against the
instance, brings up the services that answer for it, imports the PKCS#12 it is given and binds
the listener to the certificate the thumbprint names, requires SSL on the five vendor-named
virtual directories, scopes the host firewall to the ports and program and removes the wide-open
rules WSUS opened for itself, reconciles where update content is kept and who may read it,
restricts the languages the server will accept, points the server at its upstream, synchronises
the catalogue and the files behind it, and then tunes the WSUS application pool, removes the
Default Web Site and the pools nothing else uses, writes IIS request logs to a volume of their
own, and applies the server-level IIS STIG settings.

Everything that arrives from S3 moves through the controller: one PKCS#12 is fetched there, its
password is read there through the framework's `secret` lookup, and the container is handed over
the existing connection, so the guest never receives cloud credentials. In this deployment it has
no route to S3 at all.

> **Scope: one server, one co-located default SQL instance.** The AWS images install the default
> `MSSQLSERVER` instance; the role writes that name where it needs a service and the machine name
> where it needs a connection target. There is no instance-name input, and deliberately so --
> offering one would be offering a choice the rest of the role does not honour.
> Replica topology is what this deployment declares — approvals are made once, upstream, and
> inherited.

## Composition and prerequisites

The role is overlaid into a version-pinned checkout of `nwarila-platform/ansible-framework` at run
time; it is not run directly from this repository. The shipped `ansible/playbooks/wsus-aws.yml`
composes the framework's `credential_resolver`, `host_readiness`, `os_bootstrap`, `remote_client`,
`domain_member` and `windows_disk_manager` onto the host, and `wsus` last.

The target must be Windows Server with SQL Server already installed and three volumes this role
can be given — one for the database, one for the update store, one for IIS request logs — and
with the `ansible.windows`, `community.windows` and `microsoft.iis` modules the role uses. The
controller's Ansible environment needs the `amazon.aws` collection with supported
`boto3`/`botocore` for the S3 fetch.

The volumes themselves are Terraform's -- `terraform/aws.tfvars` declares them as EBS devices --
and `windows_disk_manager` is what formats the attached disks and assigns the drive letters this
role is then given. Nothing here can fall back to the system volume if they are missing:
`tasks/validate.yml` refuses any letter outside `D`-`Z`, so `C:` cannot be named, and creating a
directory on a volume that does not exist fails loudly on the guest rather than landing somewhere
else.

## What the caller supplies

Deployment-specific inputs carry an account id, a certificate identity or a network topology, and
they change with every site, so the playbook states them where a reader can see them rather than
defaulting them in the role. The list below names all sixteen, with the reason where the answer
is not obvious from the key. `tasks/validate.yml` enforces them on the controller before the
role's first mutation — the loader gathers facts from the guest first, so this is the gate in
front of every change, not in front of every contact. The five certificate leaves are required
when `wsus.tls.enabled` is true, which is the shipped default; the other eleven are required
always.

- `wsus.db.drive_letter` — the volume SUSDB is created on. Refused if it equals the content
  letter: both grow independently, and sharing a disk lets either one stop the other.
- `wsus.content.drive_letter` — the volume the update store is created on.
- `wsus.iis.drive_letter` — the volume IIS request logs are written to. Refused if it equals the
  database or the content letter.
- `wsus.sync.upstream_server` — the upstream this server mirrors, as a DNS name or an IPv4
  literal. Never defaulted: a defaulted upstream points at whatever the last deployment's was.
- `wsus.sync.upstream_port` — the port that upstream serves on: 8530 plain, 8531 TLS.
- `wsus.sync.upstream_use_ssl` — whether the link is encrypted. A property of the upstream, which
  must be serving SSL for this to be true.
- `wsus.sync.replica` — whether this server inherits the upstream's approvals.
- `wsus.sync.mode` — `wait` fetches the catalogue and reports what arrived, `start` begins one
  and returns, `disabled` fetches nothing. A first sync against a full mirror takes weeks, which
  is why the last two exist; under either, the server answers clients from whatever catalogue it
  already has.
- `wsus.sync.timeout_seconds` — how long to wait for the catalogue.
- `wsus.sync.content_timeout_seconds` — how long to wait for the files behind it. It runs after
  the catalogue wait in the same step, so the caller owns the sum against its own budget.
- `wsus.updates.languages` — the update languages this server accepts, as the short codes WSUS
  uses (`['en']`, `['en', 'fr']`). Every other language is refused at synchronisation.
- `wsus.tls.certificate.bucket` — the S3 bucket holding the PKCS#12.
- `wsus.tls.certificate.dns_name` — the name clients reach this server by, and the name the
  certificate must be valid for.
- `wsus.tls.certificate.object` — the object key of the PKCS#12, the only object this role
  fetches.
- `wsus.tls.certificate.password` — the password that unlocks it, already resolved.
- `wsus.tls.certificate.thumbprint` — the certificate the listener may present, pinned so a
  subject search cannot select another.

The upstream's endpoint is declared in three parts because that is how a deployer thinks about it,
and the role composes them into a single URL before handing it to the actor. That is not
decoration: a transport flag crossing the Ansible boundary as the string `'False'` binds to
`[System.Boolean]` as **true**, because every non-empty string casts true. A URL cannot go wrong
that way, and `[System.Uri]` takes it apart on the far side with the same parser the rest of .NET
uses.

The password is a **value, not a location**. Reading a credential out of S3 is the framework
`secret` lookup's job, so the playbook calls it and passes what comes back; the role is handed a
password and never a bucket key. That lookup takes the digest of the stored bytes as its second
term, so the pin the role used to check itself did not go away — it moved to the only thing that
still sees the object.

The listener is bound to the certificate the **thumbprint** names, so a subject search cannot
select another. The PKCS#12's bytes are not checked: a wrong one that its password opens is still
imported into `LocalMachine\My`.

## Configuration

`defaults/main.yml` carries only what is the role's own shape: the layout inside the volumes it
is given, the HTTP port, and the TLS port, site name and secured paths. Everything an estate
decides — the upstream and how to synchronise from it, the languages it accepts, the certificate
it presents — is declared empty there and published by the play, so nothing environment-specific
ever lives in the role. The two management consoles are the exception: whether the server carries
the WSUS console and IIS Manager is the estate's to decide, but keeping them is a safe answer, so
`consoles.wsus` and `consoles.iis` default to true, and false uninstalls a console a host already
has.

What does **not** live in defaults at all is constants wearing a default's clothes. The features
WSUS is made of, the SQL Server components it does not use, the flags its post-installation
writes, the services that answer for it and the default SQL instance are fixed by the product,
not by a site, and are written where they are used. `tasks/validate.yml` guards what the caller
supplies and the two defaults later steps build an IIS path or target from, `iis.log_subdir` and
`tls.site_name`; nothing asserts the product constants the role writes where it uses them. Two
converges at `changed=0` show that state is steady, not that it is correct.

## Why the order is what it is

Two placements in `tasks/present_windows.yml` are load-bearing rather than tidy.

**The database directories are pinned first**, before the feature is even installed. `wsusutil
postinstall` creates `SUSDB` wherever the instance's default directories point, and moving it
afterwards is the unsupported detach/copy/attach path. Placement has to be right before anything
can create it, so the role pins the directories, grants the instance rights on them and restarts
the instance so it adopts them — and only then installs WSUS. The features come before anything
that reads WSUS, because the UpdateServices module arrives with them.

**TLS runs before every task that talks to the WSUS API.** Once `wsusutil configuressl` records
`UsingSSL=1`, every later bare `Get-WsusServer` dials this machine over HTTPS and validates what
it is presented, so the listener has to be settled before any of them run. Putting TLS last would
work on run one, when they still speak HTTP, and differ on run two. Keeping it first makes the two
runs the same thing: both drive the API over the same
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

**The role does not make anything trust this certificate.** It imports the PKCS#12 into
`LocalMachine\My` and binds the listener to the certificate the thumbprint names. That is
presenting, not trusting: a certificate in `My` is one this machine holds, and holding it confers
no root trust. A directory delivers its trusted root to every domain member, which is exactly
what a production CA's root would do, and a role that also wrote the root store would be a second
owner of a decision the directory already makes.

In this development estate that delivery is a **separate temporary policy** standing in for a
certificate authority that does not exist yet. Measured reaching the POC client on 2026-09-11
through the `EnterpriseCertificates` hive — the earlier hand-install was needed only because the
client role did not look in that hive. Production's policy is recorded as delivering it. Read
the dependency below with that in mind.

That leaves an ordering dependency worth stating plainly. Measured on a live Server 2025 host, a
PKCS#12 imported into `My` alone appears in no other store and chains to `UntrustedRoot`. So once
`UsingSSL=1` is written, WSUS's own API calls go over HTTPS to this machine and fail their chain
check until policy has delivered the root — on this server as much as on any client. A converge
against a host Group Policy has not yet reached will fail at its first API read.

The delivery is wrapped in a block whose `always` removes both staging directories, controller
first: both hold the private key, but only the target copy can be stranded by an unreachable
guest, so the one that cannot be stranded is removed first.

## Who may reach the server

Measured on a live server, WSUS opens two inbound rules of its own at post-installation — both
named `WSUS`, TCP 8530 and 8531, with program `Any`, service `Any` and remote address **`Any`**.
The role replaces them with two rules that name the ports and the program, and then removes the
vendor's, in that order, because Windows evaluates every matching allow and the overlap keeps the
service answering throughout. Remote address stays `Any` on the host: the security group states
the admitted networks for traffic that reaches the ENI, and nothing scopes traffic arriving inside
the VPN tunnel — see below.

The replacements are scoped two ways: to the two ports WSUS serves, and to program `System`,
because the listener is HTTP.SYS in kernel mode and the sockets belong to PID 4 rather than to
`w3wp.exe`. They are **not** scoped to a service, which is a limit rather than an omission — no
service owns a kernel-mode socket, so naming one would match nothing and close the port to the
clients the rule exists to admit. Windows' own built-in IIS rules leave it unset for the same
reason.

They are **not** scoped to a network, by decision 60. For traffic that reaches the ENI, the
security group states the admitted networks once. For traffic that arrives inside the VPN tunnel,
**nothing now scopes it** — the group sees only the UDP envelope, and the payload is decapsulated
inside the guest past every group rule. That is accepted because production is AWS-only and has no
tunnel (decisions 57, 58). In this development estate it means any authenticated tunnel source
can reach 8530 and 8531; the earlier rules admitted only the two `/16`s there.

The rules are written in the shape Windows writes its own — `<Product> (<PROTOCOL> Traffic-In)`, a
group, and a description ending `[TCP <port>]` — but saying WSUS things rather than IIS things, so
an administrator reading the rule list learns why the port is open and not merely that something
web-shaped wanted it.

## IIS

The role expects IIS to serve WSUS alone, and checks that right after post-installation, before
the HTTPS listener and every later IIS change. It reads every site, application pool, application
and virtual directory, and refuses the run unless IIS holds WsusPool and exactly one WSUS site
whose root and applications all run on it; unless no path that site serves from holds `..`, and
every one but the site's own Content directory, which the content placement pins, lies in WSUS's
own tree, `Program Files\Update Services` on the drive of the site's root; and unless any other
site is the Default Web Site with IIS's stock root: DefaultAppPool at
`%SystemDrive%\inetpub\wwwroot`, one `http *:80` binding, nothing beneath it.
Only then does it set WsusPool to Microsoft's WSUS values — queue length 2000, no idle timeout,
no scheduled or memory recycling, pinging off — with the rapid-fail protection IIS STIG
V-218777/V-218778 requires, remove the Default Web Site and the three pools nothing on a WSUS host
uses, and write request logs to a volume of their own.

The zero idle and recycle limits are why that check exists: IIS Site STIG V-218762 exempts a WSUS
host from its idle timeout only when the host serves no other content, and V-218775 does not
apply to a WSUS host at all. The check goes by location, so content someone places inside WSUS's
own tree passes it. Removing the Default Web Site deletes its configuration, not its files.

The log directory grants SYSTEM and Administrators full control and Users read-and-execute, and
inherits nothing from its volume, whose root would let Users create files and folders there. An
entry for any other identity, which the role never adds, is outside what it manages. The Users
entry is the ratified convention, and a recorded deviation from V-283673.

Last, the role sets the IIS STIG settings that live in IIS and ASP.NET configuration, which no
Group Policy reaches: machine-key validation HMACSHA256 (V-218807), a 15-minute session timeout
(V-218763, V-218805), no `X-Powered-By` header (V-241789), no high-bit characters in request URLs
(V-218756), and the request-size limit IIS already applies, 30000000 bytes, written explicitly
(V-218754). The IIS STIG rules held in the registry, SCHANNEL protocols and HTTP.sys settings, are
left to the STIG GPOs, and the rules that need documentation to the ISSO.

## State

- `present` (default) — install and configure to the declared state.
- `absent` — **not implemented.** The framework loader resolves an OS task file per state and
  refuses the run by name when there is none, saying which files it searched. Removing WSUS means
  removing features, dropping `SUSDB` and deleting the content store on a host whose whole purpose
  is to be a WSUS server, and this deployment destroys the host instead. A file that only repeated
  the loader's refusal would be a second place to say one thing.
- `clean` — present and deliberately empty, and not because nothing is staged. The TLS delivery
  stages a PFX on the guest and removes it in its own `always` block, so no persistent cache
  survives a converge for `clean` to remove.

## Design invariants

1. `[INV-01]` **`SUSDB` never lands on the system volume.** Placement is pinned before anything
   can create the database, and `END` proves it by reading the system volume for stray database
   files.
2. `[INV-02]` **The guest holds no cloud credential.** Every S3 object is fetched on the
   controller.
3. `[INV-03]` **Nothing asserts what it already controls.** Two clean runs show the role steady,
   not correct; re-reading a value this role just wrote proves only that it can read itself.
   `END` reads the *engine* and the *filesystem*, which are the things that could disagree with
   it. An independent readback of the IIS settings is owed until GATE-01 runs here, as the
   migration contract records.
4. `[INV-04]` **One HTTPS port.** `wsus.tls.port` is the only declaration of it; the firewall
   reads that value rather than carrying a second copy to disagree with.
5. `[INV-05]` **Update languages are declared, not inherited.** A server installs accepting every
   language Microsoft publishes, which is a permanent cost in disk and sync time for content
   nobody will approve.
6. `[INV-06]` **The instance restarts only on evidence.** A restart is an outage, so exactly two
   cases earn one: the pin just changed — measured on a live instance (4000ee0), writing it moved
   neither `SERVERPROPERTY` nor where a database landed until the service came back — or `BEGIN`
   reached the engine and it named the wrong directory. An instance that was down when `BEGIN`
   looked earns nothing by itself: it has since started and read the registry on the way up, so
   either it is already correct or the pin changed and the first case fires. `END` proves the
   outcome either way. The restart forces the instance's dependents, because Windows refuses to
   stop a service that has them. At 4000ee0, while the image's MSSQLLaunchpad still ran, the
   forced restart brought the running Launchpad back with the engine and left a stopped agent
   stopped. Once the components WSUS does not use are gone, the only dependent is SQL Server
   Agent (measured 2026-10-01).

## First-class PowerShell

Guest-side logic a task cannot express cleanly is a first-class PowerShell script under the
repository's `scripts/`, written against the org `NWarila/powershell-template` and shipped with a
Linux-runnable Pester sibling: `Get-SqlDatabasePlacement.ps1`, `Invoke-SusdbAdoption.ps1`,
`Invoke-WsusSynchronisation.ps1`, `Set-AclGrant.ps1`, `Set-IisLogDirectory.ps1`,
`Set-IisServerHardening.ps1`, `Set-WsusContentLocation.ps1`, `Set-WsusHttpsListener.ps1`,
`Set-WsusUpdateLanguage.ps1` and `Set-WsusUpstream.ps1`, each beside its `.pester.ps1`.

The role itself carries only `files/<Name>.ps1.stub` markers, each naming its source; composition
joins the sources to the framework's `scripts/` and runs the framework's materializer, which
copies each one to `files/<Name>.ps1`, a build artifact the `.gitignore` never allowlists — the
org's three-file layout. Unlike `pdq-deploy-inventory`, whose workflow calls its own copy of the
materializer, this repository's workflows run no helper script of their own.
`.github/workflows/powershell.yml` runs the pinned `pester-matrix` harness over `scripts/`, which
discovers every `<Name>.ps1` + `<Name>.pester.ps1` pair and runs it with the org's analyzer
settings.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/compose-and-run.sh              # composes the pinned framework and runs wsus-aws.yml
(cd .compose/ansible-framework && ansible-lint applications/wsus)
# Pester runs in CI (the pinned powershell-template pester-matrix), one leg per scripts/ pair.
```

Idempotence is the acceptance criterion: a second converge against the same host must report
`changed=0`. Every actor in this role is written to be re-read rather than re-applied, which is
what makes that criterion meetable rather than aspirational.
