{
  description = "GHC WebAssembly development tools for inference";

  inputs = {
    ghc-wasm-meta.url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
    nixpkgs.follows = "ghc-wasm-meta/nixpkgs";
  };

  outputs = { ghc-wasm-meta, nixpkgs, ... }:
    let
      forSystems = nixpkgs.lib.genAttrs (builtins.attrNames ghc-wasm-meta.packages);
    in
    {
      devShells = forSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ ghc-wasm-meta.packages.${system}.all_9_10 ];
        };
      });

      checks = forSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          wasm = ghc-wasm-meta.packages.${system};
        in
        {
          wasm-toolchain = pkgs.runCommand "inference-wasm-toolchain-check"
            { nativeBuildInputs = [ wasm.wasm32-wasi-ghc-9_10 wasm.wasmtime ]; }
            ''
              printf 'main :: IO ()\nmain = putStrLn "wasm-ok"\n' > Main.hs
              wasm32-wasi-ghc Main.hs -o smoke.wasm
              test "$(HOME="$TMPDIR" wasmtime run smoke.wasm)" = wasm-ok
              touch "$out"
            '';
        });
    };
}
