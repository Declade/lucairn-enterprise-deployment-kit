# shellcheck shell=bash
#
# contrib/clients/opencode/pins.sh — the verified OpenCode 1.19.0 binaries. SOURCE it.
# Read by install.sh (before an install is moved into place) AND by opencode.sh (before
# every start, before the keys are handed over).
#
# oc_pinned_sha256 <platform> — prints the sha256 of bin/opencode[.exe] inside the npm
# package opencode-<platform>@1.19.0, or fails for a platform without a pin. Recorded
# 2026-10-14 from the registry tarballs, each first checked against the sha512 recorded
# for it in package-lock.json. darwin-arm64 and windows-x64 are the builds the setup was
# verified with (the windows-x64 one is identical to opencode.exe in the GitHub release
# asset opencode-windows-x64.zip).
oc_pinned_sha256() {
  case "$1" in
    darwin-arm64)  printf '%s\n' 476151a6c8b56e084d223d71a9312479e3b95547f8d8649b3489577059f9c5b4 ;;
    darwin-x64)    printf '%s\n' 87875bda5a6156c4cff482e3799b10e65dd3cebb890d3de33adacbbeae5ef042 ;;
    linux-arm64)   printf '%s\n' 1e392db1d558a9eebaef618d4da3927f8b61fbcbd9a19513ed77f911142415df ;;
    linux-x64)     printf '%s\n' 135ac3f86c43f2a22328a3554fec5f0bc57d71576077902661bc38dac34871fd ;;
    windows-x64)   printf '%s\n' bb731f311416df16691fa16763eb87657c4a5f5f3bcff5202718c416e8f7ab1a ;;
    windows-arm64) printf '%s\n' 8c19744a387a5567a27b314a9771cc723b72dec7ebba18edf98dce3465694c48 ;;
    *) return 1 ;;
  esac
}
