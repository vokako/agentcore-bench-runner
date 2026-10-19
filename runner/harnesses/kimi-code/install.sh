# Kimi Code CLI from a pinned offline bundle, not from npm latest, so reruns get the same bytes.
# The bundle (npm install --omit=optional --ignore-scripts of @moonshot-ai/kimi-code@<version>, with
# its package-lock.json) lives at s3://$BENCH_BUCKET/$BENCH_ARTIFACTS/kimi-code/<version>/ and in
# vendor/harness/kimi-code/<version>/. It is pure JS plus per-platform prebuilds, so one bundle
# serves x86_64 and aarch64. Runs after runner/install.sh, with /opt/bench-node on PATH.
KIMI_VERSION=${BENCH_KIMI_VERSION:-2.1.1}
# Build and upload the bundle with scripts/build_harness_bundle.sh kimi-code <version>; the tarball is
# checked against the SHA256SUMS uploaded next to it.
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/kimi-code/$KIMI_VERSION/SHA256SUMS" /tmp/kimi-code.sums
KIMI_SHA256=$(awk -v f="kimi-code-$KIMI_VERSION.tgz" '$2==f{print $1}' /tmp/kimi-code.sums)
[ -n "$KIMI_SHA256" ] || { echo "no kimi-code $KIMI_VERSION bundle in SHA256SUMS (run scripts/build_harness_bundle.sh)" >&2; exit 2; }
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/kimi-code/$KIMI_VERSION/kimi-code-$KIMI_VERSION.tgz" /tmp/kimi-code.tgz
GOT=$(node -e 'const c=require("crypto"),fs=require("fs");process.stdout.write(c.createHash("sha256").update(fs.readFileSync("/tmp/kimi-code.tgz")).digest("hex"))')
[ "$GOT" = "$KIMI_SHA256" ] || { echo "kimi-code bundle sha256 mismatch: $GOT" >&2; exit 2; }
mkdir -p /opt/bench-kimi && tar --no-same-owner -xzf /tmp/kimi-code.tgz -C /opt/bench-kimi && rm -f /tmp/kimi-code.tgz
# Short-term Bedrock API keys for the bedrock-runtime OpenAI-compatible route (runner/aws.mjs bedrock-token).
cd /opt/bench && quiet npm install --silent @aws/bedrock-token-generator && cd /
echo "kimi=$(node /opt/bench-kimi/kimi-code/node_modules/@moonshot-ai/kimi-code/dist/main.mjs --version 2>/dev/null | head -1)"
