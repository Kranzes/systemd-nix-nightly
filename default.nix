let
  sources = import ./lon.nix;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;

  systemd = pkgs.systemd.overrideAttrs (old: {
    version = "${lib.versions.major (lib.fileContents "${sources.systemd}/meson.version")}-${sources.systemd.shortRev}";
    src = sources.systemd;
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
      (lib.mesonOption "time-epoch" (toString sources.systemd.lastModified))
    ];
  });

  # Rebase ./patches from the revision recorded in patches/.base-revision onto
  # the revision locked in lon.lock, then re-export them in nixpkgs' format.
  # Run after `lon update systemd`.
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
in
{
  packages = lib.recurseIntoAttrs {
    inherit
      systemd
      rebase-patches
      ;
  };

  # Swap only the systemd package inside the test VMs instead of overlaying
  # all of nixpkgs to avoid rebuilds.
  checks = lib.recurseIntoAttrs (
    lib.mapAttrs (_: test: test.extendNixOS { module.systemd.package = lib.mkForce systemd; }) (
      removeAttrs systemd.passthru.nixosTests [
        # The nixpkgs test lacks the wait_for_unit("systemd-bless-boot.service")
        # its sibling bootCounting test has, so it races the entry rename.
        # Drop when fixed upstream.
        "systemd-boot-bootCountingSpecialisation"
        # checkperms.py probes writability with a fixed filename. systemd main
        # makes /dev/hugepages writable in the MountAPIVFS sandboxes. The test
        # units share that mount and run concurrently, so their probes collide
        # on unlink. Drop when checkperms.py is fixed upstream.
        "systemd-confinement"
      ]
    )
  );
}
