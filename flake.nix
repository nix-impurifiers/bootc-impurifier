# SPDX-License-Identifier: MIT
{
  description = "Native bootc deployments backed by Nix application closures";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    impurifier = {
      url = "github:nix-impurifiers/impurifier";
      flake = false;
    };
    rpm-adapter = {
      url = "github:nix-impurifiers/rpm-impurifier/8a8f1180114a8997a34c046af87f283e3e2df916";
      flake = false;
    };
    caisson.url = "github:nix-caisson/caisson";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };
  outputs =
    inputs@{ caisson, ... }:
    let
      lib = caisson.lib.caisson.mkLib {
        inherit (caisson.lib.caisson.pins.flake inputs) sources root;
        name = "bootc-impurifier";
        defaultEcosystemSrc = sources: { nixpkgs-lib = sources.nixpkgs; };
        systems = [ "x86_64-linux" ];
        projects = { inherit caisson; };
        configs = lib: lib.caisson.mkModules ./configs;
        pkgSets = lib: lib.caisson.nixpkgs.mkConfigurations { };
      };
    in
    lib.caisson.flake-parts.mkTopConfiguration { };
}
