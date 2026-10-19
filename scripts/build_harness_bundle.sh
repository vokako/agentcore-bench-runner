#!/usr/bin/env bash
# Build a pinned offline bundle for an npm-based harness from the lockfile committed in
# runner/harnesses/<harness>/bundle/<version>/, then upload it with its SHA256SUMS to
# s3://<results_bucket>/<results_prefix>/artifacts/<dir>/<version>/ (read from config.json).
#
#   scripts/build_harness_bundle.sh kimi-code 2.1.1
#   scripts/build_harness_bundle.sh qoder-cn 1.1.70 arm64
#   scripts/build_harness_bundle.sh codebuddy 2.164.0 arm64
#   CONFIG=config.instances.json scripts/build_harness_bundle.sh ...   # another config
#   NO_UPLOAD=1 scripts/build_harness_bundle.sh ...                   # build only
#
# `npm ci` installs exactly the versions and integrity hashes in the lockfile, so the installed tree
# matches the one the published results ran on. The tarball bytes differ from the original
# (timestamps), which is why install.sh checks the SHA256SUMS uploaded next to the bundle;
# SHA256SUMS.original records the hashes of the bundles the published results used.
# Needs Node >= 22.19, npm, tar, and the AWS CLI (for upload).
set -euo pipefail
HARNESS=${1:?harness (kimi-code | qoder-cn | codebuddy)}
VERSION=${2:?version}
ARCH=${3:-arm64}   # target CPU of the sandbox: arm64 (microVM) or x64
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/runner/harnesses/$HARNESS/bundle/$VERSION
[ -f "$SRC/package-lock.json" ] || { echo "no lockfile at $SRC" >&2; exit 2; }

case "$HARNESS" in
  kimi-code) DIR=kimi-code;      FILE=kimi-code-$VERSION.tgz;                NPMFLAGS="--omit=optional" ;;
  qoder-cn)  DIR=qoderclicn;     FILE=qoderclicn-$VERSION-linux-$ARCH.tgz;     NPMFLAGS="--os=linux --cpu=$ARCH --libc=glibc" ;;
  codebuddy) DIR=codebuddy-code; FILE=codebuddy-code-$VERSION-linux-$ARCH.tgz; NPMFLAGS="--os=linux --cpu=$ARCH --libc=glibc" ;;
  *) echo "unknown harness $HARNESS" >&2; exit 2 ;;
esac

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$DIR"
cp "$SRC/package.json" "$SRC/package-lock.json" "$WORK/$DIR/"
# shellcheck disable=SC2086
(cd "$WORK/$DIR" && npm ci --ignore-scripts --no-audit --no-fund $NPMFLAGS)
# npm ci installs every os/cpu match in the lockfile, musl variants included (the original bundles were
# built with npm install on a glibc host, which skipped them). The sandboxes are glibc, so drop packages
# marked musl-only or named *musl* (e.g. @img/sharp-linuxmusl-arm64).
(cd "$WORK/$DIR" && node -e '
  const fs=require("fs"); const l=JSON.parse(fs.readFileSync("package-lock.json"));
  for (const [p,e] of Object.entries(l.packages||{})) {
    const musl = (Array.isArray(e.libc) && !e.libc.includes("glibc")) || /musl/.test(p.split("node_modules/").pop());
    if (p && musl && fs.existsSync(p)) { fs.rmSync(p,{recursive:true}); console.log("pruned "+p); } }')
OUT=${OUT_DIR:-$ROOT/vendor/harness/$DIR/$VERSION}
mkdir -p "$OUT"
tar -czf "$OUT/$FILE" -C "$WORK" "$DIR"
cp "$SRC/package-lock.json" "$OUT/"
(cd "$OUT" && sha256sum "$FILE" > SHA256SUMS && cat SHA256SUMS)

[ -n "${NO_UPLOAD:-}" ] && { echo "built $OUT/$FILE (not uploaded)"; exit 0; }
CFG=${CONFIG:-$ROOT/config.json}
read -r BUCKET REGION PREFIX < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["results_bucket"], c["results_region"], c.get("results_prefix","bench-runner"))' "$CFG")
DEST=s3://$BUCKET/$PREFIX/artifacts/$DIR/$VERSION/
for f in "$FILE" SHA256SUMS package-lock.json; do aws s3 cp --region "$REGION" "$OUT/$f" "$DEST$f"; done
echo "uploaded to $DEST"
