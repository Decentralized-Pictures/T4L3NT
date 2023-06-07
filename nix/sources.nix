let
  opam-nix-integration = import (
    fetchTarball {
      url = "https://github.com/vapourismo/opam-nix-integration/archive/80284cbf47b5829e3f08679f755f58730149839c.tar.gz";
      sha256 = "0crbjmcr7m29pkkqa63nmc0nnx7g243agkngi0ggyy2sbpy15ydp";
    }
  );

  rust-overlay = import (
    fetchTarball {
      url = "https://github.com/oxalica/rust-overlay/archive/b91706f9d5a68fecf97b63753da8e9670dff782b.tar.gz";
      sha256 = "1c34aihrnwv15l8hyggz92rk347z05wwh00h33iw5yyjxkvb8mqc";
    }
  );

  pkgs =
    import
    (fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/6025d713d198ec296eaf27a1f2f78983eccce4d8.tar.gz";
      sha256 = "0fa6nd1m5lr4fnliw21ppc4qdd4s85x448967333dvmslnvj35xi";
    })
    {overlays = [opam-nix-integration.overlay rust-overlay];};
in {
  inherit opam-nix-integration rust-overlay pkgs;
}
