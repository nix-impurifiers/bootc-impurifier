# SPDX-License-Identifier: MIT
{ ... }:
{ lib, inputs, ... }: {
  flake.lib = lib.mkForce {
    bootc-impurifier =
      { pkgs }:
      import ../../../nix {
        inherit pkgs;
        coreSrc = inputs.impurifier;
        rpmSrc = inputs.rpm-adapter;
        sourceInfo = inputs.self;
      };
  };
  perSystem =
    { pkgs, ... }:
    let
      impurifier = import ../../../nix {
        inherit pkgs;
        coreSrc = inputs.impurifier;
        rpmSrc = inputs.rpm-adapter;
        sourceInfo = inputs.self;
      };
    in
    {
      formatter = pkgs.nixfmt-tree;
      packages.default = impurifier.package;
      packages.native-client = impurifier.nativeClient;
      checks =
        import ../../../tests {
          inherit pkgs impurifier;
          coreSrc = inputs.impurifier;
        }
        // {
          bundled-vm =
            (import ../../../tests {
              inherit pkgs impurifier;
              coreSrc = inputs.impurifier;
              bundled = true;
            }).native-vm;
        };
    };
}
