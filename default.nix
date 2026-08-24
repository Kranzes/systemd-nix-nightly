let
  sources = import ./lon.nix;
  pkgs = import sources.nixpkgs {
    overlays = [
      (final: prev: {
        systemd = prev.systemd.overrideAttrs (old: {
          version = sources.systemd.shortRev;
          src = sources.systemd;
          patches = [
            ./patches/0001-Don-t-try-to-unmount-nix-or-nix-store.patch
            ./patches/0002-Change-usr-share-zoneinfo-to-etc-zoneinfo.patch
            ./patches/0003-add-rootprefix-to-lookup-dir-paths.patch
            ./patches/0004-path-util.h-add-placeholder-for-DEFAULT_PATH_NORMAL.patch
            ./patches/0005-core-don-t-taint-on-unmerged-usr.patch
          ]
          ++ prev.lib.optionals (prev.stdenv.hostPlatform.isLinux && prev.stdenv.hostPlatform.isGnu) [
            ./patches/0006-timesyncd-disable-NSCD-when-DNSSEC-validation-is-dis.patch
          ];
          mesonFlags = builtins.filter (f: !prev.lib.hasPrefix "-Dtime-epoch=" f) old.mesonFlags ++ [
            (prev.lib.mesonOption "time-epoch" (toString sources.systemd.lastModified))
          ];
        });
      })
    ];
  };
  inherit (pkgs) lib;

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
    text = ''
      repo=$(git rev-parse --show-toplevel)
      patches_dir=$repo/patches
      base=$(cat "$patches_dir/.base-revision")
      target=$(jq -r '.sources.systemd.revision' "$repo/lon.lock")

      if [ "$base" = "$target" ]; then
        echo "patches are already based on $target"
        exit 0
      fi

      tmp=$(mktemp -d)
      on_err() {
        echo "rebase failed; work tree left at $tmp/systemd" >&2
        echo "resolve the conflict, then run:" >&2
        echo "  git am --continue # or git rebase --continue, whichever stage failed" >&2
        echo "  git -c format.signoff=false format-patch $target --no-numbered --zero-commit --no-signature -o $patches_dir" >&2
        echo "  echo $target > $patches_dir/.base-revision" >&2
      }
      trap on_err ERR

      export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
      export GIT_AUTHOR_NAME=rebase-patches GIT_AUTHOR_EMAIL=rebase-patches@localhost
      export GIT_COMMITTER_NAME=rebase-patches GIT_COMMITTER_EMAIL=rebase-patches@localhost

      git init -q -b main "$tmp/systemd"
      cd "$tmp/systemd"
      git fetch -q --depth=1 https://github.com/systemd/systemd "$base" "$target"
      git switch -qc patched "$base"
      git am -3 "$patches_dir"/*.patch
      git rebase --onto "$target" "$base"

      export_dir=$tmp/patches
      git -c format.signoff=false format-patch "$target" --no-numbered --zero-commit --no-signature -o "$export_dir" > /dev/null

      if diff -r -q --exclude=.base-revision "$patches_dir" "$export_dir" > /dev/null; then
        echo "patches apply unchanged on $target; keeping base at $base"
      else
        rm -f "$patches_dir"/*.patch
        cp "$export_dir"/*.patch "$patches_dir"
        echo "$target" > "$patches_dir/.base-revision"
      fi

      cd /
      rm -rf "$tmp"
    '';
  };
in
{
  packages = lib.recurseIntoAttrs {
    inherit (pkgs) systemd;
    inherit rebase-patches;
  };

  checks = lib.recurseIntoAttrs pkgs.systemd.passthru.nixosTests;
}
