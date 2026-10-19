# CodeBuddy Code CLI from a pinned offline bundle (npm install --os=linux --cpu=arm64 --ignore-scripts
# of @tencent-ai/codebuddy-code@<version>, with its package-lock.json), stored at
# s3://$BENCH_BUCKET/$BENCH_ARTIFACTS/codebuddy-code/<version>/ and vendor/harness/codebuddy-code/<version>/.
# Runs after runner/install.sh, with /opt/bench-node on PATH.
CBC_VERSION=${BENCH_CODEBUDDY_VERSION:-2.164.0}
ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64;; x86_64) ARCH=x64;; esac
F=codebuddy-code-$CBC_VERSION-linux-$ARCH.tgz
# Build and upload with scripts/build_harness_bundle.sh codebuddy <version> <arm64|x64>.
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/codebuddy-code/$CBC_VERSION/SHA256SUMS" /tmp/cbc.sums
SHA=$(awk -v f="$F" '$2==f{print $1}' /tmp/cbc.sums)
[ -n "$SHA" ] || { echo "no $F in SHA256SUMS (run scripts/build_harness_bundle.sh codebuddy $CBC_VERSION $ARCH)" >&2; exit 2; }
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/codebuddy-code/$CBC_VERSION/$F" /tmp/$F
GOT=$(node -e 'const c=require("crypto"),fs=require("fs");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' /tmp/$F)
[ "$GOT" = "$SHA" ] || { echo "codebuddy-code bundle sha256 mismatch: $GOT" >&2; exit 2; }
mkdir -p /opt/bench-cbc && tar --no-same-owner -xzf /tmp/$F -C /opt/bench-cbc && rm -f /tmp/$F
cd /opt/bench && quiet npm install --silent @aws-sdk/client-secrets-manager && cd /
echo "codebuddy=$(node /opt/bench-cbc/codebuddy-code/node_modules/@tencent-ai/codebuddy-code/bin/codebuddy --version 2>/dev/null | head -1)"
