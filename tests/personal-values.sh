#!/usr/bin/env bash
#
# tests/personal-values.sh — check `personal-values`: no value of our own Pi
# (hostname, key, address, port, repo, timezone, keymap, user, machine) in
# the library's code. Others run this library on their own Pi, so every such
# value belongs in hosts/neptun, the README's example section or a test
# fixture that names it explicitly (spec §9 AC1, plan D23).
#
# Scanned: lib/ modules/ templates/ ci/ .github/ rpi-*.sh devenv.nix
# devenv.yaml secretspec.toml devenv.local.nix.example, and flake.nix minus
# the lines that wire our host in (nixosConfigurations.neptun, `neptun = `,
# ./hosts/neptun). Not scanned: hosts/, tests/ (fixtures; the neptun-specific
# ones are reviewed by hand), README.md, HANDOFF.md, docs/ (history).
# The library's own address, github:GRBurst/nix-raspi (also as
# github.com/GRBurst/nix-raspi), is allowed: consumers' flakes name it.
#
#   bash tests/personal-values.sh       (run on the repository root's copy)
#
# Prints `FAIL: personal value in library code:` and the `file:line:text` of
# every hit, exits 1; exits 0 when there is none. The same path list is the
# source of checks.x86_64-linux.personal-values in flake.nix: keep both equal.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# hostname, port, address, repo, timezone, keymap, the key's own part
# (the ed25519 header before it is common to every key), user, machine
personal='neptun|(^|[^0-9])2222([^0-9]|$)|192\.168\.100\.|GRBurst/nix-raspi|Europe/Berlin|"neo"|AAAAC3NzaC1lZDI1NTE5AAAAIKxv8UiT62T7|pallon|andromeda'
library_url='github(:|\.com/)GRBurst/nix-raspi'
flake_wiring='nixosConfigurations\.neptun|neptun = |\./hosts/neptun'

paths=()
for p in lib modules templates ci .github rpi-*.sh devenv.nix devenv.yaml secretspec.toml devenv.local.nix.example; do
    [ -e "$p" ] && paths+=("$p")
done

# hits [GREP_V_ERE]: file:line:text of every personal value in `paths` (and in
# flake.nix); a line that only names the library's address is not a hit.
hits() {
    local l t
    {
        grep -rnI -E -- "$personal" "${paths[@]}" || true
        grep -nI -E -- "$personal" flake.nix | grep -v -E -- "$flake_wiring" | sed 's/^/flake.nix:/' || true
    } | while IFS= read -r l; do
        t=${l#*:*:}
        # shellcheck disable=SC2001 # a regex substitution, not a literal one
        t=$(sed -E "s#$library_url##g" <<<"$t")
        if grep -q -E -- "$personal" <<<"$t"; then printf '%s\n' "$l"; fi
    done
}

found=$(hits)
if [ -n "$found" ]; then
    echo "FAIL: personal value in library code:"
    printf '%s\n' "$found"
    exit 1
fi
echo "personal-values: none in ${paths[*]} and flake.nix"
