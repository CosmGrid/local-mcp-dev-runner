/**
 * Output hygiene for run_script.
 *
 * Redaction here is OUTPUT HYGIENE, NOT A SECURITY BOUNDARY. A secret that
 * reaches stdout has already been read by the child process; the real controls
 * are the SBPL filesystem policy, the environment allowlist and network denial.
 * This module only stops secrets from being echoed back into a chat transcript.
 *
 * Everything is deterministic and side-effect free so it can be unit tested
 * without a sandbox.
 */

const ANSI_PATTERN = /[\u001B\u009B][[\]()#;?]*(?:(?:(?:[a-zA-Z\d]*(?:;[-a-zA-Z\d\/#&.:=?%@~_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-ntqry=><~]))/g;

/** Default per-stream cap: 256 KiB, head and tail preserved. */
export const DEFAULT_MAX_STREAM_BYTES = 256 * 1024;
/** No single line may exceed this before it is folded, so one runaway line cannot dominate. */
export const DEFAULT_MAX_LINE_BYTES = 8 * 1024;

export const TRUNCATION_MARKER = "\n…[truncated]…\n";
export const LINE_TRUNCATION_MARKER = "…[truncated]…";

/**
 * Credential-shaped substrings. Deliberately conservative: each pattern needs a
 * recognisable prefix so that ordinary paths, hashes and script names survive.
 */
export const REDACTION_PATTERNS = Object.freeze([
  { label: "openai-key", pattern: /sk-[A-Za-z0-9_-]{16,}/g },
  { label: "github-token", pattern: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g },
  { label: "github-fine-grained", pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g },
  { label: "aws-access-key-id", pattern: /\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{12,}\b/g },
  { label: "aws-secret-access-key", pattern: /(?<=\baws_secret_access_key\s*[=:]\s*)[^\s"']{20,}/gi },
  { label: "slack-token", pattern: /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/g },
  { label: "stripe-key", pattern: /\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}\b/g },
  { label: "google-api-key", pattern: /\bAIza[0-9A-Za-z_-]{30,}\b/g },
  { label: "sendgrid-key", pattern: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g },
  { label: "jwt", pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g },
  { label: "private-key-block", pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g },
  { label: "bearer-header", pattern: /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}/gi },
  { label: "basic-auth-url", pattern: /\b[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s:@\/]+:[^\s@\/]+@/g },
  { label: "assigned-secret", pattern: /\b(?:api[_-]?key|secret|password|passwd|token|credential)s?\s*[=:]\s*["']?[^\s"']{8,}["']?/gi }
]);

/** Remove terminal escape sequences and normalise CRLF line endings. */
export function stripAnsi(value) {
  return String(value ?? "")
    .replace(ANSI_PATTERN, "")
    .replace(/\r\n?/g, "\n");
}

/** Replace credential-shaped substrings with a labelled placeholder. */
export function redact(value) {
  let output = String(value ?? "");
  for (const { label, pattern } of REDACTION_PATTERNS) {
    output = output.replace(pattern, (match) => `[redacted:${label}]`);
  }
  return output;
}

const encoder = new TextEncoder();

function byteLength(value) {
  return encoder.encode(value).length;
}

/**
 * Byte-safe head/tail slice. Slices on a UTF-8 boundary by walking the string
 * once so a multi-byte character is never cut in half.
 */
function headTail(value, headBytes, tailBytes) {
  if (headBytes + tailBytes >= byteLength(value)) return value;
  const chars = Array.from(value);
  let head = "";
  let used = 0;
  for (const ch of chars) {
    const size = byteLength(ch);
    if (used + size > headBytes) break;
    head += ch;
    used += size;
  }
  let tail = "";
  used = 0;
  for (let i = chars.length - 1; i >= 0; i -= 1) {
    const size = byteLength(chars[i]);
    if (used + size > tailBytes) break;
    tail = chars[i] + tail;
    used += size;
  }
  return `${head}${TRUNCATION_MARKER}${tail}`;
}

function capLines(value, maxLineBytes) {
  return String(value ?? "")
    .split("\n")
    .map((line) => {
      if (byteLength(line) <= maxLineBytes) return line;
      return `${headTail(line, maxLineBytes, 0)}${LINE_TRUNCATION_MARKER}`;
    })
    .join("\n");
}

/**
 * Sanitise one output stream.
 *
 * @param {string|Buffer} raw
 * @param {object} [options]
 * @param {number} [options.maxBytes]
 * @param {number} [options.maxLineBytes]
 * @returns {{ text: string, truncated: boolean, bytes: number, bytesKept: number }}
 */
export function sanitizeOutput(raw, options = {}) {
  const maxBytes = options.maxBytes ?? DEFAULT_MAX_STREAM_BYTES;
  const maxLineBytes = options.maxLineBytes ?? DEFAULT_MAX_LINE_BYTES;

  const isBuffer = Buffer.isBuffer(raw);
  const bytes = isBuffer ? raw.length : byteLength(String(raw ?? ""));

  // Binary output is replaced by a placeholder instead of being decoded into
  // mojibake: build tools happily emit non-text bytes and dumping them into a
  // chat transcript helps nobody.
  if (isBuffer && looksBinary(raw)) {
    return {
      text: `[binary output omitted: ${bytes} bytes]`,
      truncated: true,
      bytes,
      bytesKept: byteLength(`[binary output omitted: ${bytes} bytes]`)
    };
  }

  let text = isBuffer ? raw.toString("utf8") : String(raw ?? "");
  text = replaceLoneSurrogates(text);
  text = stripAnsi(text);
  text = capLines(text, maxLineBytes);
  text = redact(text);

  let truncated = false;
  if (byteLength(text) > maxBytes) {
    const headBytes = Math.floor(maxBytes * 0.4);
    const tailBytes = Math.floor(maxBytes * 0.4);
    text = headTail(text, headBytes, tailBytes);
    truncated = true;
  }

  return { text, truncated, bytes, bytesKept: byteLength(text) };
}

/**
 * Heuristic binary detection for raw Buffers. A stream is treated as binary
 * when it contains a NUL byte or when more than 10% of its bytes are control
 * characters outside the usual whitespace set.
 */
function looksBinary(buffer) {
  if (buffer.length === 0) return false;
  if (buffer.includes(0)) return true;
  let suspicious = 0;
  const limit = Math.min(buffer.length, 8192);
  for (let i = 0; i < limit; i += 1) {
    const byte = buffer[i];
    if (byte < 0x20 && byte !== 0x09 && byte !== 0x0a && byte !== 0x0d) suspicious += 1;
    if (byte === 0x7f) suspicious += 1;
  }
  return suspicious / limit > 0.1;
}

/**
 * Replace unpaired surrogates (produced when UTF-8 decoding half-succeeds) with
 * U+FFFD so downstream JSON serialisation cannot throw or emit lone escapes.
 */
function replaceLoneSurrogates(value) {
  return String(value ?? "").replace(
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]/g,
    (match) => match.replace(/[\uD800-\uDFFF]/g, "\uFFFD")
  );
}
