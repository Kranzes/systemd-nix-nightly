{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systemd = {
      url = "github:systemd/systemd";
      flake = false;
    };
    flake-compat = {
      url = "https://git.lix.systems/lix-project/flake-compat/archive/main.tar.gz";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          systemd = pkgs.systemd.overrideAttrs (old: {
            version = "${lib.versions.major (lib.fileContents "${inputs.systemd}/meson.version")}-${inputs.systemd.shortRev}";
            src = inputs.systemd;
            patches = [
              ./patches/0001-Don-t-try-to-unmount-nix-or-nix-store.patch
              ./patches/0002-Change-usr-share-zoneinfo-to-etc-zoneinfo.patch
              ./patches/0003-add-rootprefix-to-lookup-dir-paths.patch
              ./patches/0004-path-util.h-add-placeholder-for-DEFAULT_PATH_NORMAL.patch
              ./patches/0005-core-don-t-taint-on-unmerged-usr.patch
            ]
            ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isGnu) [
              ./patches/0006-timesyncd-disable-NSCD-when-DNSSEC-validation-is-dis.patch
            ];
            mesonFlags = builtins.filter (f: !lib.hasPrefix "-Dtime-epoch=" f) old.mesonFlags ++ [
              (lib.mesonOption "time-epoch" (toString inputs.systemd.lastModified))
            ];
          });

          # Rebase ./patches from the revision recorded in patches/.base-revision
          # onto the revision locked in flake.lock, then re-export them in
          # nixpkgs' format. Run after `nix flake update systemd`.
          rebase-patches = pkgs.writeShellApplication {
            name = "rebase-patches";
            runtimeInputs = [
              pkgs.gitMinimal
              pkgs.jq
              pkgs.coreutils
              pkgs.diffutils
            ];
            text = lib.fileContents ./rebase-patches.sh;
          };
        }
      );

      # Swap only the systemd package inside the test VMs instead of overlaying
      # all of nixpkgs to avoid rebuilds.
      checks = forAllSystems (
        system:
        let
          inherit (inputs.self.packages.${system}) systemd;
        in
        {
          systemd-package = systemd;
        }
        // lib.mapAttrs (_: test: test.extendNixOS { module.systemd.package = lib.mkForce systemd; }) (
          lib.filterAttrs (_: test: test ? extendNixOS) (
            removeAttrs systemd.passthru.nixosTests (
              [
                # OOMs the runner, remove once the splitting is in place: https://github.com/NixOS/nixpkgs/pull/557715
                "switchTest"
                # RACES
                "systemd-boot-bootCountingSpecialisation"
                "systemd-confinement"
                "systemd-timesyncd-nscd-dnssec"
              ]
              ++ lib.optionals (system != "x86_64-linux") [
                # Broken in nixpkgs on non-x86. Drop when fixed upstream.
                "systemd-boot-garbage-collect-entry"
                "systemd-boot-garbageCollectEntryWithBootCounting"
                "systemd-boot-memtestSortKey"
                "systemd-binfmt-basic"
                "systemd-binfmt-chroot"
                "systemd-binfmt-ldPreload"
                "systemd-binfmt-preserveArgvZero"
                "systemd-boot-specialisation"
              ]
            )
          )
        )
      );
    };
}
