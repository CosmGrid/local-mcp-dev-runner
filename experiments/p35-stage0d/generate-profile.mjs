#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function printHelp() {
  console.log(`Usage: generate-profile.mjs --allowed-dir <path> --helper-bin <path> --run-id <id> --output <path>`);
}

function parseArgs(args) {
  const parsed = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--allowed-dir' && i + 1 < args.length) {
      parsed.allowedDir = args[++i];
    } else if (arg === '--share-dir' && i + 1 < args.length) {
      parsed.shareDir = args[++i];
    } else if (arg === '--helper-bin' && i + 1 < args.length) {
      parsed.helperBin = args[++i];
    } else if (arg === '--run-id' && i + 1 < args.length) {
      parsed.runId = args[++i];
    } else if (arg === '--output' && i + 1 < args.length) {
      parsed.output = args[++i];
    } else if (arg === '--test-injection') {
      parsed.testInjection = true;
    }
  }
  return parsed;
}

export function validateInput({ allowedDir, helperBin, shareDir, runId }) {
  if (!runId || typeof runId !== 'string') {
    throw new Error('INVALID_RUN_ID: run-id is missing');
  }
  if (!/^[a-zA-Z0-9_-]{6,64}$/.test(runId)) {
    throw new Error('INVALID_RUN_ID: run-id must match ^[a-zA-Z0-9_-]{6,64}$');
  }

  // Check for SBPL injection characters
  const forbiddenChars = /["\\\r\n\0]/;
  if (forbiddenChars.test(allowedDir)) {
    throw new Error('INJECTION_DETECTED: allowedDir contains forbidden SBPL characters');
  }
  if (forbiddenChars.test(helperBin)) {
    throw new Error('INJECTION_DETECTED: helperBin contains forbidden SBPL characters');
  }
  if (shareDir && forbiddenChars.test(shareDir)) {
    throw new Error('INJECTION_DETECTED: shareDir contains forbidden SBPL characters');
  }

  if (!fs.existsSync(allowedDir)) {
    throw new Error(`ALLOWED_DIR_NOT_FOUND: ${allowedDir}`);
  }
  if (!fs.existsSync(helperBin)) {
    throw new Error(`HELPER_BIN_NOT_FOUND: ${helperBin}`);
  }

  const canonicalAllowed = fs.realpathSync(allowedDir);
  const canonicalHelper = fs.realpathSync(helperBin);

  const effectiveShareDir = shareDir || path.join(canonicalAllowed, 'share');
  if (forbiddenChars.test(effectiveShareDir)) {
    throw new Error('INJECTION_DETECTED: shareDir contains forbidden SBPL characters');
  }
  if (!fs.existsSync(effectiveShareDir)) {
    throw new Error(`SHARE_DIR_NOT_FOUND: ${effectiveShareDir}`);
  }

  const canonicalShare = fs.realpathSync(effectiveShareDir);

  if (forbiddenChars.test(canonicalAllowed) || forbiddenChars.test(canonicalHelper) || forbiddenChars.test(canonicalShare)) {
    throw new Error('INJECTION_DETECTED: canonical path contains forbidden SBPL characters');
  }

  // Ensure helperBin is inside canonicalAllowed
  const relHelper = path.relative(canonicalAllowed, canonicalHelper);
  if (relHelper.startsWith('..') || path.isAbsolute(relHelper)) {
    throw new Error(`HELPER_NOT_IN_ALLOWED: helper ${canonicalHelper} is not within allowed directory ${canonicalAllowed}`);
  }

  // Strict share scope validation: canonicalShare must strictly equal realpath(canonicalAllowed + "/share")
  const expectedShare = fs.realpathSync(path.join(canonicalAllowed, 'share'));
  if (canonicalShare !== expectedShare) {
    throw new Error(`INVALID_SHARE_SCOPE: share ${canonicalShare} is not exact expected canonicalAllowed/share ${expectedShare}`);
  }
  const relShare = path.relative(canonicalAllowed, canonicalShare);
  if (relShare !== 'share') {
    throw new Error(`INVALID_SHARE_SCOPE: share ${canonicalShare} relative path is ${relShare}, expected exact 'share'`);
  }

  return {
    canonicalAllowed,
    canonicalHelper,
    canonicalShare,
    runId
  };
}

export function renderProfile(canonicalAllowed, canonicalHelper, canonicalShareOrRunId, maybeRunId) {
  let canonicalShare;
  let runId;
  if (maybeRunId !== undefined) {
    canonicalShare = canonicalShareOrRunId;
    runId = maybeRunId;
  } else {
    canonicalShare = path.join(canonicalAllowed, 'share');
    runId = canonicalShareOrRunId;
  }
  const EXTENSION_CLASS = "com.apple.app-sandbox.read-write";
  return `;; Stage 0D Host Helper Seatbelt Profile (FUSE Extension Delta, run-id: ${runId})
(version 1)
(deny default)

(import "system.sb")

;; Process execution policy: allow fork and only the specific helper binary
(allow process-fork)
(allow process-exec (literal "${canonicalHelper}"))

;; Filesystem containment: allow read/write strictly inside the per-run allowed directory
(allow file-read* file-write* (subpath "${canonicalAllowed}"))

;; VirtioFS / Fuse sandbox extension capability (Approved R5 Delta)
(allow generic-issue-extension
  (extension-class "com.apple.virtualization.extension.fuse"))

;; VirtioFS / Path sandbox extension capability (Approved R7 Delta)
(allow file-issue-extension
  (require-all
    (extension-class "${EXTENSION_CLASS}")
    (subpath "${canonicalShare}")))
`;
}

async function main() {
  const args = process.argv.slice(2);
  const parsed = parseArgs(args);

  if (parsed.testInjection) {
    try {
      validateInput({ allowedDir: '/tmp/"(allow default)', helperBin: '/tmp/test', runId: 'test1234' });
      console.error('FAIL: allowedDir injection not caught');
      process.exit(1);
    } catch (e) {
      if (!e.message.includes('INJECTION_DETECTED')) {
        console.error('FAIL: unexpected error for injection test:', e);
        process.exit(1);
      }
    }
    try {
      validateInput({ allowedDir: '/tmp', helperBin: '/tmp/test', shareDir: '/tmp/share"(allow default)', runId: 'test1234' });
      console.error('FAIL: shareDir quote injection not caught');
      process.exit(1);
    } catch (e) {
      if (!e.message.includes('INJECTION_DETECTED')) {
        console.error('FAIL: unexpected error for share quote injection test:', e);
        process.exit(1);
      }
    }
    try {
      validateInput({ allowedDir: '/tmp', helperBin: '/tmp/test', shareDir: '/tmp/share\\(allow default)', runId: 'test1234' });
      console.error('FAIL: shareDir backslash injection not caught');
      process.exit(1);
    } catch (e) {
      if (!e.message.includes('INJECTION_DETECTED')) {
        console.error('FAIL: unexpected error for share backslash injection test:', e);
        process.exit(1);
      }
    }
    try {
      validateInput({ allowedDir: '/tmp', helperBin: '/tmp/test', shareDir: '/tmp/share\n(allow default)', runId: 'test1234' });
      console.error('FAIL: shareDir newline injection not caught');
      process.exit(1);
    } catch (e) {
      if (!e.message.includes('INJECTION_DETECTED')) {
        console.error('FAIL: unexpected error for share newline injection test:', e);
        process.exit(1);
      }
    }
    try {
      validateInput({ allowedDir: '/tmp', helperBin: '/tmp/test', runId: 'bad id; rm -rf /' });
      console.error('FAIL: invalid run-id not caught');
      process.exit(1);
    } catch (e) {
      if (!e.message.includes('INVALID_RUN_ID')) {
        console.error('FAIL: unexpected error for run-id test:', e);
        process.exit(1);
      }
    }
    console.log('PROFILE_INJECTION_TEST=PASS');
    process.exit(0);
  }

  if (!parsed.allowedDir || !parsed.helperBin || !parsed.runId || !parsed.output) {
    printHelp();
    process.exit(2);
  }

  try {
    const validated = validateInput(parsed);
    const content = renderProfile(validated.canonicalAllowed, validated.canonicalHelper, validated.canonicalShare, validated.runId);
    fs.writeFileSync(parsed.output, content, 'utf8');
    console.log(`PROFILE_GENERATED=${parsed.output}`);
  } catch (err) {
    console.error(`GENERATE_PROFILE_ERROR: ${err.message}`);
    process.exit(1);
  }
}

const isDirectRun = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectRun) {
  main();
}
