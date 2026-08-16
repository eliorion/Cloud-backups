# About this project — a guide for reviewers

*A plain-language companion to [README.md](README.md). If you are evaluating this repository as a work
sample, read this first. It assumes no familiarity with NixOS, ZFS, or S3.*

---

## In one paragraph

A production Kubernetes cluster needs somewhere safe to put its backups. This project is that
somewhere: a self-hosted, S3-compatible storage system running on **four physical machines spread
across three locations**, built so that whoever destroys the production cluster still cannot destroy
its backups. All four machines are defined as code — no machine was configured by hand — and the whole
lifecycle, from bare metal to running service, is driven by a single command-line tool written for the
purpose.

---

## The problem, in plain terms

Most backup systems share something with the system they protect: the same credentials, the same
network, the same administrator account, the same cloud project. That is fine against a failed hard
drive. It is useless against ransomware.

An attacker who gets administrator access to a system typically gets its backups in the same motion —
same login, same network path, one `delete` away. The backup and the thing it protects die together.

So the design starts from one rule, and everything else follows from it:

> **A backup that shares credentials, network, or administrative reach with the system it protects
> dies with that system.**

This backup tier therefore shares *nothing* with production: a different operating system, different
identities, a different network posture, no common control plane. And because the storage software
used here has no built-in way to make data permanent, the guarantee is built one layer down — in the
filesystem, using read-only snapshots that the storage service's own credentials have no permission to
delete. An attacker holding a valid write key can erase every live file and still not touch the
history. To actually destroy it they would need operating-system root access on three machines in
three different buildings, simultaneously.

---

## What was built

| | |
|---|---|
| **Machines** | 4 — three holding data (one per location, a full mirror), one acting as a gateway |
| **Locations** | 3 physical sites, connected over a private encrypted network |
| **Defined as code** | ~2 600 lines of Nix across 22 files: operating system, disk partitioning, encryption, firewall, services |
| **Operations tooling** | A 1 761-line command-line tool with 12 subcommands and an interactive menu, covering provisioning, deployment, rollback, unlocking, and credential management |
| **Written design record** | 7 documents, ~33 000 words — architecture decisions, a phased build plan, and the per-machine runbooks actually followed during the build |
| **History** | 48 commits over 7 weeks |

Two of those numbers matter more than the rest. The **design record was written before the build**, not
after — it contains six formal architecture decisions, each recording what was chosen, why, *and what
was rejected*. And the **operations tooling exists because the architecture demanded it**: the design
rules out any central orchestrator, so the machine lifecycle had to be built by hand rather than
delegated to Kubernetes or Ansible.

---

## What this demonstrates

Each claim below links to the evidence, so nothing has to be taken on trust.

| Capability | Where to see it |
|---|---|
| **Threat modelling** — designing against a named adversary rather than a vague sense of risk | [Threat model](documentations/00-garage-backup-cluster.md#2-threat-model-and-the-blast-radius-principle): a table of concrete attacks, each with its vector and its specific defence |
| **Architectural decision-making** — recording rejected options, not just chosen ones | [Six ADRs](documentations/00-garage-backup-cluster.md#4-decision-records), each structured decision / why / rejected alternatives |
| **Infrastructure as code** — reproducible machines with atomic rollback | [`flake.nix`](flake.nix): one list of hosts derives every machine configuration, an install-time variant of each, and the deployment map. Adding a machine is one line |
| **Storage and filesystem engineering** — encryption, snapshots, separation of duties | [`modules/zfs-sanoid.nix`](modules/zfs-sanoid.nix) and [`hosts/disko-node-a.nix`](hosts/disko-node-a.nix), where one machine's two security domains are expressed as one declarative disk layout |
| **Secrets management** — encrypted at rest, committed safely, decrypted at boot | [`modules/sops.nix`](modules/sops.nix): each machine's identity is a dedicated key; a compromised machine cannot read any other's secrets. A missing key fails at build time, so it cannot brick a machine in production |
| **Network security** — deny-by-default, least privilege | [`modules/garage.nix`](modules/garage.nix): every listener bound to the private overlay address only, with production granted exactly one port and never the administrative one |
| **Tooling and developer experience** — building the tool the job required | [`scripts/fleet`](scripts/fleet) |
| **Technical writing** — documentation someone else could actually follow | [The seven documents](README.md#documentation), including runbooks where the ordering is load-bearing and the text explains why |

---

## Engineering judgment: three examples

Anyone can list technologies. These are three moments where the work required a judgment call, and
what each one shows.

### Reading a bug through three layers to find the real cause

Encrypted configuration files were being produced that worked perfectly on the development machine and
could not be read by any of the servers. The only visible symptom appeared much later, at machine
startup, as a generic failure message — with every service that needed a password failing at once.

The cause was three layers below the symptom: the development container runs emulated on a different
processor architecture, and the emulation layer mistranslates one specific hand-optimised encryption
routine. The encryption tool was, in effect, producing subtly corrupt output while reporting success —
and it could still read its own output, which is why local testing never caught it.

The fix was to rebuild the encryption tools from source with the hand-optimised routine disabled, and
route every path that encrypts anything through those builds. **What it shows:** debugging past the
symptom to the actual mechanism, and recognising that a tool verifying its own output proves nothing.

### Replacing a clever design with a boring one

Each machine's identity was originally derived from a key it already had — elegant, and one fewer thing
to manage. It did not work: the derivation could not be performed at the moment in startup when it was
needed, so the very first deployment to a new machine failed.

It was replaced with the obvious approach: generate a dedicated key per machine in advance and install
it during provisioning. **What it shows:** willingness to discard a clever design once evidence
contradicts it, and preference for fewer moving parts over elegance.

### Correcting a security claim the design could not support

The design originally stored the disk-encryption password on the machine so it could restart
unattended — and then claimed the design protected against machine theft. Reviewing this honestly, it
did not: the machine held both the encrypted data and the means to decrypt it, so a stolen machine
would simply unlock itself. On the remote unattended sites — exactly where theft is most plausible —
it was the worst of both options, because the password was stored *and* still had to be typed after a
restart.

It was changed so no password is stored anywhere, and a command was added to supply it remotely, so a
restart at a remote site costs one command instead of a site visit. The threat model was rewritten to
state what at-rest encryption actually buys. **What it shows:** auditing your own design against its
own claims, and choosing a documented, deliberate cost over a comfortable but false guarantee.

*(All three are written up with full technical detail in the
[README](README.md#three-things-i-changed-my-mind-about).)*

---

## How to evaluate this in ten minutes

1. **[The trade-off table](README.md#design-trade-offs)** — eight decisions, each with what was chosen,
   what was rejected, and *what the choice cost*. The fourth column is the one worth reading.
2. **[The threat model](documentations/00-garage-backup-cluster.md#2-threat-model-and-the-blast-radius-principle)**
   — the reasoning the whole system is built on.
3. **[`flake.nix`](flake.nix)** — the architecture in one file. Note the comment density: the code
   records *why*, not *what*.
4. **[Current state, honestly](README.md#current-state-honestly)** — where the running system differs
   from the design target, stated plainly rather than glossed over.

If you read only one thing, read the fourth column of the trade-off table and the honest-status
section. Together they show the habit this project is really evidence of: stating costs and gaps
explicitly instead of presenting the work as finished and flawless.

---

## What is deliberately not done

Stated so the gaps read as decisions rather than oversights:

- **Not a second Kubernetes cluster.** The machines cooperate only as a storage cluster. Building a
  second Kubernetes cluster would have recreated the shared-fate problem the project exists to avoid.
- **Not high availability.** This is cold/warm disaster recovery, not failover.
- **The backup jobs live elsewhere.** The scheduled jobs that *write* to this store are managed in the
  production cluster's own repository. This repository is the vault, not the depositor.
- **Currently running below the design target.** Two data machines instead of three, replication
  factor 2 instead of 3, because one machine is offline long-term. The
  [status table](README.md#current-state-honestly) lists every such gap.
- **One manual step by design.** Unlocking encrypted storage after a restart requires a human typing a
  password that exists nowhere on the fleet. That cost is accepted deliberately — see the third example
  above.

---

## Stack

**Operating system and storage** — NixOS · OpenZFS (native encryption, read-only snapshots, sanoid)
**Storage service** — Garage (S3-compatible, geo-distributed)
**Provisioning and deployment** — disko · nixos-anywhere · deploy-rs
**Secrets** — SOPS · age · sops-nix
**Networking** — Tailscale (WireGuard overlay, deny-by-default access control) · nftables
**Boot security** — LUKS2 · TPM2 · Secure Boot via lanzaboote · systemd-cryptenroll
**Tooling** — Bash · Nix flakes · devcontainers

---

<!-- TODO: replace with your name and preferred contact details before sharing this link. -->
*Questions about any decision here are welcome — every one of them is written down somewhere in this
repository, and I am happy to walk through the reasoning.*
