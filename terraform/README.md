# terraform/ — NOT ACTIVE

Reserved deploy layer. This repo will eventually consume the
**proxmox-terraform-framework** (the way the wazuh stack's `wazuh.tfvars` does) to
provision the target VM, with Ansible handling configuration. The deploy platform is
not ready; nothing in this directory is executed, validated, or wired to CI.

Skeleton files carry stub headers only, so the repo (and the future `*-template`)
reserves the shape without asserting design decisions prematurely:

- `main.tf` — future root module consuming the framework
- `variables.tf` / `outputs.tf` — future interface
- `environments/int.tfvars.example` — per-env variable pattern placeholder

When the platform lands: shape these against the framework's consumption contract,
then delete this notice.
