# run.hs compiled, with the tools its shebang names on PATH. The deploy job
# caches this closure, which leaves out GHC (about 3 GiB unpacked) and needs no
# nixpkgs evaluation to run. Keep the packages in step with run.hs's shebang.
{ pkgs ? import <nixpkgs> { } }:
let
  ghc = pkgs.haskellPackages.ghcWithPackages (p: [ p.turtle p.base64-bytestring p.aeson ]);
in
pkgs.runCommand "run-hs" { nativeBuildInputs = [ ghc pkgs.makeWrapper ]; } ''
  mkdir -p $out/bin
  cp ${../run.hs} run.hs
  ghc -O0 -o $out/bin/run-hs run.hs
  wrapProgram $out/bin/run-hs --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nodejs_22 pkgs.gh pkgs.git pkgs.curl ]}
''
