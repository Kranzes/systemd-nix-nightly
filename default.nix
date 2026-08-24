let
  sources = import ./lon.nix;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;
in
{
  inherit sources;
  checks =
    lib.recurseIntoAttrs
      (pkgs.systemd.overrideAttrs {
        # TODO
      }).passthru.nixosTests;
}
