# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  rpmSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  native = pkgs.bootc;
  rpm = import (rpmSrc + "/nix") { inherit pkgs coreSrc; };
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "bootc-impurifier";
  };
  sdk = pkgs.linkFarm "bootc-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
  ];
  nativeClient = native;
  package = pkgs.writeShellApplication {
    name = "bootc-impurifier";
    runtimeInputs = [
      pkgs.nix
      pkgs.python3
      native
      pkgs.ostree-full
    ];
    text = ''exec ${sdk}/python/bin/python3 ${../src}/cli.py "$@"'';
  };
  safe = value: builtins.match "[A-Za-z0-9_][A-Za-z0-9_.+-]*" value != null;
  makeDeployment =
    {
      pkg,
      name ? pkg.pname,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      hardware ? null,
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
    }:
    assert lib.assertMsg (safe name && safe program) "invalid application or executable name";
    let
      appSdk =
        if bundledNixStore == null then
          sdk
        else
          pkgs.linkFarm "bootc-python-sdk" [
            {
              name = "python";
              path = pkgs.python3;
            }
          ];
      bundle = core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; };
    in
    pkgs.runCommand "${name}-${pkg.version}-bootc-deployment"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        test -x ${pkg}/bin/${program}
        implementation=$out/rootfs/usr/share/bootc-impurifier/apps/${name}
        mkdir -p "$implementation" $out/rootfs/usr/bin
        cp ${../src/launch.py} "$implementation/launch.py"
        cp ${../src/common.py} "$implementation/common.py"
        cp ${coreSrc}/src/engine.py "$implementation/engine.py"
        cp ${../LICENSE} "$implementation/LICENSE"
        ${lib.optionalString (bundledNixStore != null) ''
          cp ${bundle}/usr/lib/bootc-impurifier/nix-store "$implementation/nix-store"
          mkdir -p "$implementation/share/licenses/bundled-nix"
          cp -r ${bundle}/usr/share/licenses/bootc-impurifier/bundled-nix/. "$implementation/share/licenses/bundled-nix/"
        ''}
        cp ${
          pkgs.writeText "deployment.json" (
            builtins.toJSON {
              inherit name;
              schema = 1;
            }
          )
        } $out/deployment.json
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit name program offline;
              inherit (pkg) version;
              installable = toString pkg;
              sdk = toString appSdk;
              nixBin = "${pkgs.nix}/bin";
              implementationDigest =
                builtins.hashFile "sha256" ../src/launch.py
                + builtins.hashFile "sha256" ../src/common.py
                + builtins.hashFile "sha256" (coreSrc + "/src/engine.py");
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
            }
          )
        } "$implementation/application.json"
        cat > $out/rootfs/usr/bin/${program} <<'PY'
        #!${pkgs.python3}/bin/python3
        import runpy
        import sys
        sys.dont_write_bytecode = True
        sys.path.insert(0, '/usr/share/bootc-impurifier/apps/${name}')
        runpy.run_path('/usr/share/bootc-impurifier/apps/${name}/launch.py', run_name='__main__')
        PY
        chmod 755 $out/rootfs/usr/bin/${program}
        ${lib.optionalString offline ''
          cp -r ${core.offlineCache pkg} "$implementation/cache"
          cp -r ${core.offlineCache appSdk} "$implementation/sdk-cache"
        ''}
      '';
  makeApplicationTree =
    args:
    let
      deployment = makeDeployment args;
    in
    pkgs.runCommand "bootc-application-tree"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p $out
        cp -r ${deployment}/rootfs/. $out/
      '';
  makeImage =
    {
      base,
      applications,
      extraContents ? [ ],
      name ? "nix-impurified",
      tag ? "latest",
      offline ? false,
    }:
    assert lib.assertMsg (
      pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    ) "bootc impurifier currently supports x86_64 Linux";
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9._/-]*" name != null
      && builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}" tag != null
    ) "invalid image name or tag";
    let
      trees = map (args: makeApplicationTree (args // { inherit offline; })) applications;
      names = map (args: args.name or args.pkg.pname) applications;
      programs = map (args: args.program or (args.pkg.meta.mainProgram or args.pkg.pname)) applications;
      policy = pkgs.writeText "local-image-policy.json" (
        builtins.toJSON {
          default = [ { type = "reject"; } ];
          transports = {
            oci."${builtins.unsafeDiscardStringContext (toString base)}" = [
              { type = "insecureAcceptAnything"; }
            ];
          };
        }
      );
    in
    assert lib.assertMsg (
      builtins.length names == builtins.length (lib.unique names)
      && builtins.length programs == builtins.length (lib.unique programs)
    ) "duplicate application or executable name";
    pkgs.runCommand "${name}-bootc-image"
      {
        nativeBuildInputs = [
          pkgs.skopeo
          pkgs.umoci
          pkgs.jq
        ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        skopeo --tmpdir "$TMPDIR" --policy ${policy} inspect --config oci:${base} > base-config.json
        jq -e '.config.Labels["org.containers.bootc"] == "1" and .config.Labels["ostree.bootable"] == "true"' base-config.json >/dev/null
        skopeo --tmpdir "$TMPDIR" --policy ${policy} copy oci:${base} oci:$out:${tag}
        mkdir root
        ${lib.concatMapStringsSep "\n" (tree: ''
          cp -r ${tree}/. root/
          chmod -R u+w root
        '') (trees ++ extraContents)}
        tar -C root --sort=name --mtime=@1 --owner=0 --group=0 -cf layer.tar .
        umoci raw add-layer --compress gzip --image $out:${tag} --history.created 1970-01-01T00:00:01Z layer.tar
        umoci gc --layout $out
      '';
in
{
  inherit
    package
    native
    nativeClient
    sdk
    makeImage
    makeApplicationTree
    ;
  inherit (rpm) buildRpm;
  makeNetImage = args: makeImage (args // { offline = false; });
  makeOfflineImage = args: makeImage (args // { offline = true; });
}
