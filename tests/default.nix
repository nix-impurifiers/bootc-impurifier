# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
let
  fixture = import ./fixture.nix { inherit pkgs impurifier; };
  disk = pkgs.runCommand "tukit-empty-btrfs.raw" { nativeBuildInputs = [ pkgs.btrfs-progs ]; } ''
    truncate -s 8192M $out
    mkfs.btrfs -f -L nixos $out
  '';
  start = ''
    import os
    import subprocess
    root_disk = str((machine.state_dir / "btrfs-root.qcow2").resolve())
    subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-f", "qcow2", "-b", "${disk}", "-F", "raw", root_disk], check=True)
    os.environ["NIX_DISK_IMAGE"] = root_disk
    start_all()
    machine.wait_for_unit("multi-user.target", timeout=60)
  '';
  producer = pkgs.testers.runNixOSTest {
    name = "bootc-native-base";
    globalTimeout = 600;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = fixture;
    testScript =
      { nodes, ... }:
      start
      + ''
        machine.succeed("${nodes.machine.system.build.ostree-bootstrap}")
        machine.succeed("mkdir -p /var/lib/bootc-images; rpm-ostree compose container-encapsulate --repo /ostree/repo --label org.containers.bootc=1 nixos/base oci:/var/lib/bootc-images/base")
        machine.copy_from_machine("/var/lib/bootc-images/base", "base")
      '';
  };
  base =
    pkgs.runCommand "bootc-native-test-base"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        cp -r ${producer}/base/base $out
      '';
  app = pkgs.writeShellScriptBin "bootc-app" "echo bootc-one" // {
    pname = "bootc-app";
    version = "1";
  };
  app2 = pkgs.writeShellScriptBin "bootc-app" "echo bootc-two" // {
    pname = "bootc-app";
    version = "2";
  };
  net = impurifier.makeNetImage {
    inherit base;
    applications = [ { pkg = app; } ];
  };
  offline = impurifier.makeOfflineImage {
    inherit base;
    applications = [ { pkg = app; } ];
  };
  upgrade = impurifier.makeOfflineImage {
    inherit base;
    applications = [ { pkg = app2; } ];
  };
  hardwareFixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware =
    version:
    impurifier.makeOfflineImage {
      inherit base;
      applications = [
        {
          pkg = hardwareFixture.tool;
          hardware = hardwareFixture.hardware;
        }
      ];
      extraContents = [ (hardwareFixture.driver version) ];
    };
  empty = impurifier.makeImage {
    inherit base;
    applications = [ ];
  };

in
{
  native-vm = pkgs.testers.runNixOSTest {
    name = "bootc-native-contract";
    globalTimeout = 900;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = fixture;
    testScript =
      { nodes, ... }:
      start
      + ''
        import shlex
        import json
        machine.succeed("mkdir -p /var/lib/bootc-images; cp -r ${net} /var/lib/bootc-images/net; cp -r ${offline} /var/lib/bootc-images/offline; cp -r ${upgrade} /var/lib/bootc-images/upgrade; cp -r ${empty} /var/lib/bootc-images/empty; cp -r ${hardware "1"} /var/lib/bootc-images/hardware1; cp -r ${hardware "2"} /var/lib/bootc-images/hardware2")
        machine.succeed("${nodes.machine.system.build.ostree-bootstrap}")
        def boot_default():
            option = machine.succeed("entry=$(grep -H '^version ' /boot/loader/entries/*.conf | sort -k2,2nr | head -n1 | cut -d: -f1); grep '^options ' \"$entry\"").strip().split('ostree=')[1].split()[0]
            machine.shutdown()
            os.environ["QEMU_KERNEL_PARAMS"] = "ostree=" + option
            machine.start()
            machine.wait_for_unit("multi-user.target", timeout=60)
        def user(command):
            return "su - consumer -c " + shlex.quote(command)
        def finalize():
            machine.succeed("PATH=/usr/bin:/usr/sbin:$PATH ostree admin finalize-staged")
        boot_default()
        machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
        machine.succeed("cp -r /var/lib/bootc-images/net /var/lib/bootc-images/tampered; chmod -R u+w /var/lib/bootc-images/tampered")
        machine.succeed("${pkgs.python3}/bin/python3 -c \"import json,pathlib; root=pathlib.Path('/var/lib/bootc-images/tampered'); index=json.loads((root/'index.json').read_text()); manifest=json.loads((root/'blobs/sha256'/index['manifests'][0]['digest'].split(':')[1]).read_text()); p=root/'blobs/sha256'/manifest['layers'][-1]['digest'].split(':')[1]; b=bytearray(p.read_bytes()); b[len(b)//2]^=1; p.write_bytes(b)\"")
        machine.fail("bootc switch --transport oci /var/lib/bootc-images/tampered")
        assert json.loads(machine.succeed("bootc status --json"))['status']['staged'] is None
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/net")
        machine.fail("bootc-impurifier prepare")
        machine.succeed("test ! -e /usr/bin/bootc-app")
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/offline")
        machine.fail(user("bootc-impurifier prepare"))
        machine.succeed("bootc-impurifier prepare; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test ! -e /usr/bin/bootc-app")
        finalize()
        boot_default()
        checksum = machine.succeed("find /usr/share/bootc-impurifier/apps/bootc-app -type f -exec sha256sum {} + | sort")
        assert machine.succeed(user("/usr/bin/bootc-app")).strip() == "bootc-one"
        assert machine.succeed("find /usr/share/bootc-impurifier/apps/bootc-app -type f -exec sha256sum {} + | sort") == checksum
        machine.succeed("ostree admin pin 0")
        app_one = json.loads(machine.succeed("bootc status --json"))['status']['booted']['ostree']['checksum']
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/upgrade; bootc-impurifier prepare")
        assert machine.succeed(user("/usr/bin/bootc-app")).strip() == "bootc-one"
        finalize()
        boot_default()
        assert machine.succeed(user("/usr/bin/bootc-app")).strip() == "bootc-two"
        machine.succeed("bootc rollback; bootc-impurifier prepare")
        finalize()
        boot_default()
        assert machine.succeed(user("/usr/bin/bootc-app")).strip() == "bootc-one"
        machine.succeed("ostree admin undeploy 1; bootc-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/empty; bootc-impurifier prepare")
        finalize()
        boot_default()
        machine.succeed("test ! -e /usr/bin/bootc-app; bootc-impurifier prune --owner consumer; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
        status = json.loads(machine.succeed("bootc status --json"))['status']
        assert status['rollback']['ostree']['checksum'] == app_one
        assert status['rollback']['pinned']
        machine.succeed("ostree admin pin --unpin 1; ostree admin undeploy 1; bootc-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/hardware1; bootc-impurifier prepare")
        finalize()
        boot_default()
        assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/hardware2; bootc-impurifier prepare")
        assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
        finalize()
        boot_default()
        assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "2"
        machine.succeed("bootc rollback; bootc-impurifier prepare")
        finalize()
        boot_default()
        assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
        machine.succeed("bootc switch --transport oci /var/lib/bootc-images/empty; bootc-impurifier prepare")
        finalize()
        boot_default()
        machine.succeed("ostree admin undeploy 1; bootc-impurifier prune --owner consumer; nix-store --gc; test ! -e /usr/bin/hardware-tool; test ! -e ${builtins.unsafeDiscardStringContext (toString hardwareFixture.tool)}")
      '';
  };
}
