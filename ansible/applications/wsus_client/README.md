# `wsus_client` role

Asks an estate WSUS server for updates, takes what it offers, and proves it answered. It is the
acceptance test for the `wsus` role expressed as a role: point a machine at a freshly built
server, run this, and read what came back.

**It writes no WSUS configuration.** Group Policy owns what a machine is told about WSUS — the
server it reports to, whether to use it, and the certificate it must trust — and rewrites those
values at its own convenience. A role writing them would be a second owner losing intermittently,
so every registry operation here is a read.

It does two things that change the machine, and both are deliberate: it refreshes Group Policy so
what it reads is current, and it installs the updates it is offered. What it is *offered* remains
the server's decision, which is the whole point of pointing a client at one.

> **Scope: proof-of-concept only.** This role exists to validate a WSUS build end to end. It is
> not part of the production estate, where clients are driven by Group Policy alone and no role
> triggers their scans.

## Composition and prerequisites

The role is overlaid into a version-pinned checkout of `nwarila-platform/ansible-framework` at run
time; it is not run directly from this repository. The shipped `ansible/playbooks/wsus-aws.yml`
runs it against the client host after the `wsus` play has built the server.

The target must be a domain-joined Windows Server receiving the Group Policy that names the WSUS
server, with the `ansible.windows` modules the role uses. It needs no route to the internet — that
is the point — but it does need one to the WSUS server on both of its ports.

## What the caller supplies

`wsus_client.server.url` — the URL Group Policy is expected to have named, with scheme, host and
port. It is an **expectation, not a setting**: the role compares it against what policy actually
wrote and refuses a machine nothing told. `meta/main.yml` records it; `tasks/validate.yml`
enforces its shape on the controller: scheme, a well-formed host, and an explicit port that is a
whole number in range. The port is required because WSUS serves on neither 80 nor 443, and five
digits is a shape rather than a port — `99999` matches the shape and cannot be dialled.

`wsus_client.certificate.thumbprint` — the trust anchor Group Policy is expected to have
delivered. The same kind of expectation, and declared empty for the same reason the server role
declares its own certificate keys empty: which certificate an estate trusts belongs to the
deployment, not to a role that travels. A present run that omits it is refused.

## Configuration

`defaults/main.yml` carries only the shape of those expectations and what to ask for; the
trust-anchor identity itself comes from the deployment.

The categories default to `['*']` deliberately. The module's own default names three and excludes
Definition Updates, so a client asking for the default set finds nothing whenever the server's
approvals fall outside it — and reports success. Approvals are made upstream and inherited, and
this repository declares none of them, so the only safe ask is everything.

`reboot` is `false` for the same reason the counts are printed: a machine that reboots mid-task
reports nothing, so `reboot_required` comes back in the result for a human to act on instead.

## The one refusal

A machine Group Policy never reached scans Microsoft, or scans nothing, and reports *no updates
required* — which is indistinguishable from a successful proof. Every other way this can fail is
loud; that way is silent, so it is the one worth catching.

Before asking for anything, the role makes policy current with `gpupdate` (without `/force`, which
would reapply every policy rather than refresh what changed), then reads four values and asserts
on them: `WUServer` matches the expected URL, `UseWUServer` is 1, and the anchor thumbprint is
present in **either** the Group Policy root store or the machine root store. Both are checked
because they are different mechanisms — a policy deployment lands under
`Policies\Microsoft\SystemCertificates` and a locally installed certificate under
`Microsoft\SystemCertificates` — and Windows honours either.

The WSUS server presents a self-signed certificate, so a client that cannot chain it fails every
scan with a transport error naming TLS and never mentioning WSUS. The anchor check turns that into
a message that says what is actually wrong.

## Taking the updates

`ansible.windows.win_updates` rather than the update agent's own COM interface, and not for
convenience: that interface refuses to **install** from a remote session, so a script driven over
this connection could search and download and then fail at the one step that matters. The module
runs the work through a scheduled task on the machine itself, which is the supported way around
that.

`server_selection: managed_server` is explicit. No server name is passed to the module and none
could be: `managed_server` tells the update agent to use the service Group Policy configured it
with, and the default would let the agent decide for itself. Naming the right server is what the
refusal above does — it proves `WUServer` is the URL the caller expects before anything asks the
agent for anything.

The task owns its own outcome through `failed_when`, rather than leaving a following assertion to
judge it: an update WSUS offered and this machine could not install is a failure of the work the
task performed. The module's own failure signal is preserved alongside, because `failed_when`
replaces it rather than adding to it.

The counts are then printed rather than asserted. A converged machine is offered nothing, so there
is no number here worth failing on that `failed_when` has not already caught — but a registered
result nobody prints is a proof nobody can read.

## State

- `present` (default) — check the machine was told, then ask, take, and report.
- `absent` — **not implemented.** There is nothing to remove: the role writes no configuration,
  and uninstalling updates is not what a proof of a server's reachability would undo. The
  framework loader refuses the state by name, saying which files it searched.
- `clean` — present and deliberately empty. The role stages nothing on the guest.

## Design invariants

- **Idempotent without arranging to be.** A second run finds nothing left to install and reports
  no change, because the first run installed it.
- **No WSUS configuration is written.** Every registry operation in this role is a `win_reg_stat`
  read.
- **Silence is never success.** The single refusal exists precisely because the failure mode this
  role is most exposed to is a scan that succeeds against nothing.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
(cd .compose/ansible-framework && ansible-lint applications/wsus_client)
```

The role's own report task is the acceptance evidence, and it emits four aggregates: how many
updates WSUS offered, how many installed, how many failed, and whether a reboot is pending. A
non-zero offered count on a machine with no route to Microsoft is the proof that matters — it can
only have come from the server under test.
