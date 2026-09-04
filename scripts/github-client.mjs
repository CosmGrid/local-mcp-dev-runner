/**
 * Restricted GitHub API Client.
 *
 * Exposes ONLY:
 *   1. getRepository (GET /repos/{owner}/{repo})
 *   2. createOrgRepository (POST /orgs/{org}/repos)
 *
 * Security:
 *   - Host locked to https://api.github.com by default.
 *   - Strict request timeout.
 *   - Full credential redaction on errors and exceptions.
 *   - No arbitrary paths, no arbitrary HTTP methods.
 */

export const DEFAULT_GITHUB_API_BASE = "https://api.github.com";
const DEFAULT_TIMEOUT_MS = 10000;

function redactToken(text, token) {
  if (!text || typeof text !== "string") return text;
  if (!token || typeof token !== "string" || token.length < 4) return text;
  return text.replaceAll(token, "[REDACTED_GITHUB_TOKEN]");
}

function normalizeError(error, token) {
  const rawMessage = error?.message ?? String(error);
  const cleanMessage = redactToken(rawMessage, token);
  const name = error?.name || "Error";

  if (name === "TimeoutError" || cleanMessage.includes("aborted") || cleanMessage.includes("timeout")) {
    const err = new Error(`GITHUB_TIMEOUT: Request to GitHub API timed out (${cleanMessage})`);
    err.category = "GITHUB_TIMEOUT";
    return err;
  }
  if (name === "SyntaxError" || cleanMessage.includes("JSON")) {
    const err = new Error(`GITHUB_MALFORMED_RESPONSE: Failed to parse GitHub API JSON response (${cleanMessage})`);
    err.category = "GITHUB_MALFORMED_RESPONSE";
    return err;
  }
  if (cleanMessage.includes("fetch failed") || cleanMessage.includes("ENOTFOUND") || cleanMessage.includes("ECONNREFUSED") || cleanMessage.includes("ECONNRESET")) {
    const err = new Error(`GITHUB_NETWORK_ERROR: Network error communicating with GitHub API (${cleanMessage})`);
    err.category = "GITHUB_NETWORK_ERROR";
    return err;
  }

  const err = new Error(cleanMessage);
  err.category = "GITHUB_API_ERROR";
  return err;
}

export class GitHubApiClient {
  constructor({ apiBaseUrl = DEFAULT_GITHUB_API_BASE, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
    this.apiBaseUrl = apiBaseUrl.replace(/\/+$/, "");
    this.timeoutMs = timeoutMs;
  }

  async getRepository({ owner, repo, token }) {
    if (!token) {
      throw new Error("GITHUB_CREDENTIAL_MISSING: Authentication token is required for GitHub API calls.");
    }
    const targetUrl = `${this.apiBaseUrl}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await fetch(targetUrl, {
        method: "GET",
        headers: {
          "Accept": "application/vnd.github+json",
          "Authorization": `Bearer ${token}`,
          "X-GitHub-Api-Version": "2022-11-28",
          "User-Agent": "local-mcp-dev-runner"
        },
        signal: controller.signal
      });

      if (response.status === 404) {
        return null;
      }

      if (response.status === 401) {
        throw new Error("GITHUB_AUTH_FAILED: GitHub API authentication failed (HTTP 401). Please check credentials.");
      }

      if (response.status === 403) {
        throw new Error("GITHUB_FORBIDDEN: Access forbidden by GitHub API (HTTP 403). Check organization permissions.");
      }

      if (!response.ok) {
        let errBody = "";
        try {
          const bodyJson = await response.json();
          errBody = bodyJson?.message || JSON.stringify(bodyJson);
        } catch {
          errBody = await response.text().catch(() => "");
        }
        throw new Error(`GITHUB_API_ERROR: GitHub API responded with status ${response.status} (${errBody})`);
      }

      return await response.json();
    } catch (err) {
      throw normalizeError(err, token);
    } finally {
      clearTimeout(timer);
    }
  }

  async createOrgRepository({ org, name, visibility, description, token }) {
    if (!token) {
      throw new Error("GITHUB_CREDENTIAL_MISSING: Authentication token is required for GitHub API calls.");
    }
    const targetUrl = `${this.apiBaseUrl}/orgs/${encodeURIComponent(org)}/repos`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    const payload = {
      name,
      visibility,
      auto_init: false
    };
    if (description) {
      payload.description = description;
    }

    try {
      const response = await fetch(targetUrl, {
        method: "POST",
        headers: {
          "Accept": "application/vnd.github+json",
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
          "X-GitHub-Api-Version": "2022-11-28",
          "User-Agent": "local-mcp-dev-runner"
        },
        body: JSON.stringify(payload),
        signal: controller.signal
      });

      if (response.status === 401) {
        throw new Error("GITHUB_AUTH_FAILED: GitHub API authentication failed (HTTP 401). Please check credentials.");
      }

      if (response.status === 403) {
        throw new Error("GITHUB_FORBIDDEN: Access forbidden by GitHub API (HTTP 403). Check organization permissions.");
      }

      if (response.status === 409) {
        throw new Error(`GITHUB_CONFLICT: Repository already exists or conflict occurred on GitHub (HTTP 409).`);
      }

      if (response.status === 422) {
        let errBody = "";
        try {
          const bodyJson = await response.json();
          errBody = bodyJson?.message || JSON.stringify(bodyJson);
        } catch {
          errBody = await response.text().catch(() => "");
        }
        throw new Error(`GITHUB_VALIDATION_FAILED: GitHub repository validation failed (HTTP 422): ${errBody}`);
      }

      if (!response.ok) {
        let errBody = "";
        try {
          const bodyJson = await response.json();
          errBody = bodyJson?.message || JSON.stringify(bodyJson);
        } catch {
          errBody = await response.text().catch(() => "");
        }
        throw new Error(`GITHUB_API_ERROR: GitHub API create failed with status ${response.status} (${errBody})`);
      }

      return await response.json();
    } catch (err) {
      throw normalizeError(err, token);
    } finally {
      clearTimeout(timer);
    }
  }
}
