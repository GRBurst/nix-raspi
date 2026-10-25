# rpi-ci: the CI entry point (ci/rpi-ci.sh) with the scripts it dispatches
# to and the shared rpi-lib.sh/rpi-fp.sh, for `nix run .#rpi-ci -- <cmd>`
# (a consumer: `nix run --inputs-from . rpi#rpi-ci -- <cmd>`).
#
# libexec/rpi-ci keeps the repository layout (ci/*.sh, rpi-lib.sh,
# rpi-fp.sh), so the scripts find ../rpi-lib.sh and the lib finds rpi-fp.sh
# as in a checkout. The tools the scripts call are prepended to PATH (a CI
# runner may lack cachix, or have other versions). nix is deliberately NOT
# bundled: it must be the runner's (its config, its daemon).
{ lib, stdenvNoCC, makeWrapper, bash, git, jq, coreutils, gnugrep, gnused, findutils, util-linux, cachix }:
stdenvNoCC.mkDerivation {
  name = "rpi-ci";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ./. ../rpi-lib.sh ../rpi-fp.sh ];
  };
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/rpi-ci/ci
    cp ci/*.sh $out/libexec/rpi-ci/ci/
    cp rpi-lib.sh rpi-fp.sh $out/libexec/rpi-ci/
    makeWrapper ${lib.getExe bash} $out/bin/rpi-ci \
      --add-flags $out/libexec/rpi-ci/ci/rpi-ci.sh \
      --prefix PATH : ${lib.makeBinPath [
        bash git jq coreutils gnugrep gnused findutils util-linux cachix
      ]}
    runHook postInstall
  '';
  meta.mainProgram = "rpi-ci";
}
