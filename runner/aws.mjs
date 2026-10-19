// In-sandbox AWS helper. Credentials come from the AgentCore execution role (IMDS).
//   node aws.mjs put <key> <file>        upload a file under the run prefix
//   node aws.mjs get <key|s3-uri> <file|->  download an object (streamed; '-' = stdout)
//   node aws.mjs stop                    stop this runtime session (releases the sandbox)
// Configuration is read from the environment written by the client at submit time.
import fs from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { BedrockAgentCoreClient, StopRuntimeSessionCommand } from '@aws-sdk/client-bedrock-agentcore';

const env = process.env;
const [, , cmd, a, b] = process.argv;
const s3 = new S3Client({ region: env.BENCH_S3_REGION });

if (cmd === 'put') {
  await s3.send(new PutObjectCommand({ Bucket: env.BENCH_BUCKET, Key: a, Body: fs.readFileSync(b) }));
} else if (cmd === 'get') {
  const m = a.match(/^s3:\/\/([^/]+)\/(.+)$/);
  const [Bucket, Key] = m ? [m[1], m[2]] : [env.BENCH_BUCKET, a];
  const r = await s3.send(new GetObjectCommand({ Bucket, Key }));
  await pipeline(r.Body, b === '-' ? process.stdout : fs.createWriteStream(b));
} else if (cmd === 'stop') {
  const ac = new BedrockAgentCoreClient({ region: env.BENCH_REGION });
  await ac.send(new StopRuntimeSessionCommand({
    agentRuntimeArn: env.BENCH_RUNTIME_ARN, runtimeSessionId: env.BENCH_SESSION_ID, qualifier: 'DEFAULT',
  }));
} else if (cmd === 'secret') {
  // Print one Secrets Manager secret string (used by harnesses that need an API key).
  // The SDK is installed only by harnesses that use this, so it is imported lazily.
  const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
  const sm = new SecretsManagerClient({ region: env.BENCH_REGION });
  // "<id>:<STAGE>" picks a version stage (e.g. bench/kiro-api-key:KEY1); plain "<id>" is AWSCURRENT.
  const [id, stage] = a.split(':');
  const r = await sm.send(new GetSecretValueCommand({ SecretId: id, ...(stage ? { VersionStage: stage } : {}) }));
  process.stdout.write(r.SecretString);
} else if (cmd === 'bedrock-token') {
  // Print a short-term Bedrock API key minted from the execution role, for clients that
  // only speak bearer auth to bedrock-runtime's OpenAI-compatible endpoint (e.g. Codex).
  // Installed only by harnesses that use it, so imported lazily.
  const { getTokenProvider } = await import('@aws/bedrock-token-generator');
  process.stdout.write(await getTokenProvider({ region: a || env.BENCH_MODEL_REGION || env.BENCH_REGION })());
} else {
  console.error('usage: aws.mjs put|get <key> <file> | stop | secret <id>');
  process.exit(2);
}
