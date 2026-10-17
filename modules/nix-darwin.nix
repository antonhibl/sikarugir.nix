/*
  Usage (in your nix-darwin config, with home-manager already wired in):

  ```nix
  {
  imports = [
      home-manager.darwinModules.home-manager
      sikarugir-nix.darwinModules.default
  ];

  programs.sikarugir = {
      enable = true;
      user = "username"; # the macOS account these instances belong to
      instances.SatisfactoryCX = {
        engine = "WS12WineCX24.0.7_7";
        runPath = "/Program Files/Epic Games/SatisfactoryEarlyAccess/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe";
      };
  };
  }
  ```
*/
{ config, lib, ... }:

let
  cfg = config.programs.sikarugir;
  versions = import ../lib/versions.nix;
  instanceOptions = import ../lib/options.nix { inherit lib versions; };

  instanceType = lib.types.submodule ({ name, ... }: {
    options = instanceOptions;
    config = {
      name = lib.modules.mkDefault name;
    };
  });
in
{
  options.programs.sikarugir = {
    enable = lib.options.mkEnableOption "declarative Sikarugir instances";

    user = lib.options.mkOption {
      type = lib.types.str;
      example = "username";
      description = ''
        Which macOS user account (as declared in `home-manager.users.<name>`)
        these instances belong to. Sikarugir instances are per-user (with
        their own writable prefixes and save data), so unlike a typical
        system-wide nix-darwin option this always targets exactly
        one account.
      '';
    };

    instancesDirectory = lib.options.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/Users/username/Applications/Sikarugir";
      description = ''
        Passed through to the home-manager module's
        `programs.sikarugir.instancesDirectory` (see
        ../modules/home-manager.nix). Leave as `null` to use that module's
        own default (`~/Applications/Sikarugir` for the target `user`).
      '';
    };

    instances = lib.options.mkOption {
      type = lib.types.attrsOf instanceType;
      default = { };
      description = ''
        Declarative Sikarugir instances. Uses an identical option schema to the
        home-manager module's `programs.sikarugir.instances` (see ../lib/options.nix),
        since this just forwards to it.
      '';
    };

    shortcuts = lib.options.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Passed through to the home-manager module's `programs.sikarugir.shortcuts`
        (see ../modules/home-manager.nix for the options each takes).
      '';
    };

    removedInstances = lib.options.mkOption {
      type = lib.types.enum [ "trash" "keep" ];
      default = "trash";
      description = ''
        Passed through to the home-manager module's
        `programs.sikarugir.removedInstances`: whether a removed instance's
        `.app` is moved to the Trash or kept in place.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.users.${cfg.user} = { lib, ... }: {
      imports = [ ./home-manager.nix ];
      programs.sikarugir = {
        enable = true;
        inherit (cfg) instances removedInstances shortcuts;
      } // lib.attrsets.optionalAttrs (cfg.instancesDirectory != null) {
        inherit (cfg) instancesDirectory;
      };
    };
  };
}
