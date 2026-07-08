#!/usr/bin/env bash
set -Eeuo pipefail

# NeoFreeBird builder with required flags.
# Usage: build.sh [--sideloaded | --rootless | --trollstore | --rootfull]

is_tty=0
if [[ -t 1 ]]; then is_tty=1; fi
bold='' green='' reset=''
if [[ "$is_tty" -eq 1 ]]; then
  if command -v tput >/dev/null 2>&1; then
    bold="$(tput bold || true)"
    green="$(tput setaf 2 || true)"
    reset="$(tput sgr0 || true)"
  else
    bold='\033[1m'; green='\033[32m'; reset='\033[0m'
  fi
fi

say() { if [[ -n "${bold}${green}${reset}" ]]; then printf "%b%s%b\n" "${bold}${green}" "$1" "${reset}"; else printf "%s\n" "$1"; fi; }
err() { printf "Error: %s\n" "$1" >&2; }
die() { err "$1"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--sideloaded | --rootless | --trollstore | --rootfull] [-t | --twitter-branding] [--resource-pack ZIP]
TL;DR: You need to select one flag to build NeoFreeBird.

Flags (required):
  --sideloaded   Compile NeoFreeBird as a .ipa so you can sideload it with AltStore, Sideloadly or similar.
  --rootless     Compile NeoFreeBird as a .deb file that does not require a jailbreak.
  --trollstore   Compile NeoFreeBird as a .tipa so you can install it using TrollStore.
  --rootfull     Compile NeoFreeBird as a .deb file that requires a jailbreak.

Options:
  -t, --twitter-branding  Set's the app's display name to Twitter (IPA builds only)
  --resource-pack ZIP     (macOS only) Apply a theme pack ZIP (IPA builds only)
  -h, --help              Show this help
EOF
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found in PATH"; }

require_cmd bash
require_cmd make

CYAN_BIN=""; if command -v cyan >/dev/null 2>&1; then CYAN_BIN="cyan"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/branding/ipa-branding.sh"

MODE=""
TWITTER_BRANDING=0
RESOURCE_PACK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sideloaded|--sideloaded=*)
      [[ -n "$MODE" ]] && die "Multiple flags provided. Choose one."
      MODE="sideloaded"; shift
      ;;
    --rootless|--rootless=*)
      [[ -n "$MODE" ]] && die "Multiple flags provided. Choose one."
      MODE="rootless"; shift
      ;;
    --trollstore)
      [[ -n "$MODE" ]] && die "Multiple flags provided. Choose one."
      MODE="trollstore"; shift
      ;;
    --rootfull)
      [[ -n "$MODE" ]] && die "Multiple flags provided. Choose one."
      MODE="rootfull"; shift
      ;;
    -t|--twitter-branding)
      TWITTER_BRANDING=1; shift
      ;;
    --resource-pack)
      [[ $# -ge 2 ]] || die "--resource-pack requires a path argument."
      RESOURCE_PACK="$2"; shift 2
      ;;
    --resource-pack=*)
      RESOURCE_PACK="${1#*=}"; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      # no positional args expected
      die "Unexpected argument: $1"
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  usage
  exit 2
fi

if [[ "$MODE" != "sideloaded" && "$MODE" != "trollstore" ]]; then
  if [[ "$TWITTER_BRANDING" -eq 1 ]]; then
    say "Skipping --twitter-branding: branding only applies to IPA builds (--sideloaded/--trollstore)."
    TWITTER_BRANDING=0
  fi
  if [[ -n "$RESOURCE_PACK" ]]; then
    say "Skipping --resource-pack: branding only applies to IPA builds (--sideloaded/--trollstore)."
    RESOURCE_PACK=""
  fi
fi

if [[ -n "$RESOURCE_PACK" && ! -f "$RESOURCE_PACK" ]]; then
  die "--resource-pack file not found: $RESOURCE_PACK"
fi

clean_tree() {
  if [[ -d .theos ]]; then rm -rf .theos; fi
  if [[ -f Makefile ]]; then make clean || true; fi
}

case "$MODE" in
  sideloaded)
    say "Preparing to compile NeoFreeBird. Argument added: --sideloaded."
    clean_tree
    make SIDELOADED=1
    if [[ $? -ne 0 ]]; then
      die "An error occurred when building."
    fi
    if [[ -e ./packages/com.atebits.Tweetie2.ipa ]]; then
      say "Building the IPA."
      if command -v cyan >/dev/null 2>&1; then
        cyan -i packages/com.atebits.Tweetie2.ipa -o packages/NeoFreeBird-sideloaded --ignore-encrypted \
          -uwf .theos/obj/debug/zxPluginsInject.dylib .theos/obj/debug/libbhFLEX.dylib \
          .theos/obj/debug/BHTwitter.dylib layout/Library/Application\ Support/BHT/BHTwitter.bundle
        apply_ipa_branding "$(ls -t packages/*.ipa 2>/dev/null | head -n1)"
      else
        say "Skipping cyan step because it is not installed."
      fi
      say "NeoFreeBird has been successfully built. Enjoy!"
    else
      err "packages/com.atebits.Tweetie2.ipa not found."
    fi
    ;;
  rootless)
    say "Preparing to compile NeoFreeBird. Argument added: --rootless."
    clean_tree
    export THEOS_PACKAGE_SCHEME="rootless"
    make package
    say "NeoFreeBird has been successfully built. Enjoy!"
    ;;
  trollstore)
    say "Preparing to compile NeoFreeBird. Argument added: --trollstore."
    clean_tree
    make
    if [[ $? -ne 0 ]]; then
      die "An error occurred when building."
    fi
    if [[ -e ./packages/com.atebits.Tweetie2.ipa ]]; then
      say "Merging NeoFreeBird to provided Twitter IPA."
      if command -v cyan >/dev/null 2>&1; then
        cyan -i packages/com.atebits.Tweetie2.ipa -o packages/NeoFreeBird-trollstore.tipa --ignore-encrypted \
          -uwf .theos/obj/debug/BHTwitter.dylib .theos/obj/debug/libbhFLEX.dylib layout/Library/Application\ Support/BHT/BHTwitter.bundle
        apply_ipa_branding "$(ls -t packages/*.tipa 2>/dev/null | head -n1)"
      else
        say "Skipping cyan step because it is not installed."
      fi
      say "NeoFreeBird has been successfully built. Enjoy!"
    else
      err "packages/com.atebits.Tweetie2.ipa not found."
    fi
    ;;
  rootfull)
    say "Preparing to compile NeoFreeBird. Argument added: --rootfull."
    clean_tree
    unset THEOS_PACKAGE_SCHEME || true
    make package
    say "NeoFreeBird has been successfully built. Enjoy!"
    ;;
  *)
    die "Unknown mode: $MODE"
    ;;
esac
