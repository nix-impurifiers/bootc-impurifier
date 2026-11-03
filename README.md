# bootc-impurifier

Build bootable OCI images containing Nix-backed application commands, then
prepare their closures without changing immutable image files. Original code
is MIT. Native bootc and OSTree own image import, staging, boot and rollback.

```nix
imp = inputs.bootc-impurifier.lib.bootc-impurifier { inherit pkgs; };
image = imp.makeOfflineImage {
  base = myBootcBase; # A single-image OCI layout, already fetched or built.
  applications = [{ pkg = pkgs.hello; }];
  name = "my-host";
  tag = "v1";
};
```

`makeImage` accepts `base`, `applications`, optional `name`, `tag`, `offline`, and `extraContents` (additional root filesystem
trees, for example host driver files).
`makeNetImage` and `makeOfflineImage` choose transport for every application.
Each application accepts `pkg`, optional `name`, `program`, and explicit
`hardware` library mappings. `makeApplicationTree` exposes one application's
`/usr` tree for users composing their own Containerfile. An image derives from
its supplied base; inherited applications remain inherited. Use a base without
an application to produce an image that removes it.

The factory uses Skopeo and umoci to add a real OCI filesystem layer while
preserving the base image configuration and bootability metadata. It includes
only the requested filesystem trees rather than their Nix store closures; offline caches are
application data and net images require their closures to be available normally.
It preserves the user's base operating system rather than provisioning Nix.
Providing Nix through an impure package remains deferred installer work.

Install the helper on an existing bootc host with working Nix and persistent
`/nix` and user state. Build and stage the image through native tools:

```sh
sudo bootc switch --transport oci /path/to/image
sudo bootc-impurifier prepare
# Reboot normally once preparation succeeds.
sudo bootc rollback
# Delete unwanted native deployments before releasing their roots:
sudo bootc-impurifier prune --owner YOUR_USER
```

`prepare` reads the staged deployment, a queued rollback target, or the booted
deployment when neither exists. Root imports Nix output data through the trusted host Nix executable,
with unsigned-cache acceptance scoped to that explicit import. It runs no
application code and changes no global daemon trust setting. Failed preparation
leaves native staging unchanged: recover by making the closure available or
staging an offline image, then prepare it before rebooting.

Root identities follow application content across native image changes and
rollback. Pruning reads native `bootc status --json`, including pinned/other
OSTree deployments; it releases a closure only after no deployment retains that
application descriptor. `--owner` also prunes that user's obsolete library
captures after dropping privileges. Repeat it for other users as needed.
Launchers run as the calling user and leave image-owned files unchanged.

## Native VM coverage

The fixture produces its base in a real VM with native RPM ownership of the
actual NixOS release file, native OSTree composition, and native OCI export.
Consumers boot real Btrfs/OSTree deployments and exercise image corruption
rejection, net/offline recovery, preparation privileges, unchanged owned files,
upgrades, native rollback, pinned-image retention and deletion, driver library
replacement across reboot, removal, and Nix GC retention/release. The fixture supplies genuine FHS SDK tools, managed SELinux reference
policy and container tooling; kernel SELinux enforcement is separate coverage.
The NixOS kernel/initrd is supplied externally, so this does not test installing
a bootloader or bootc's disk installer.

This adapter currently covers x86_64 Linux application commands on the native
OSTree backend. Services/accounts, composefs-only storage, remote signing and
registries, concurrent administration and other architectures require separate
coverage. `buildRpm` is also exported for native fixture/provider packages;
`package`, `native`, `nativeClient`, and `sdk` expose the tooling outputs.

## Native payloads and bundled clients

`makeImage { base; applications = [ ]; extraContents = [ nativeTree ]; }`
composes a prepared filesystem tree without a Nix application SDK or engine.
The producer supplies a bootc-compatible base and files that work in that
base; this does not relocate binaries. Native payloads use bootc's image
ownership, upgrades, rollback and image replacement. The VM boots native-only
application layers, executes a static proof, upgrades, rolls back and removes
it. The installed proof also runs in a separate root without `/nix`; the
NixOS base itself still uses its existing store and host tools.

Nix-backed application constructors also accept `bundledNixStore` (a supplied
static ELF executable) and `bundledNixNotices` (upstream notice files). The
application carries the client privately and uses a Python-only SDK. Launch
prefers a compatible external client, then the bundle, before registering roots
or capturing hardware. Explicit `IMPURIFIER_NIX_STORE` disables fallback.
Trusted preparation still uses host tools and never executes the image-owned
client as root. An existing store, daemon and initial SDK preparation remain
required. The separate bundled VM repeats the native lifecycle with an
incompatible external candidate; this is not a Nix installer.
