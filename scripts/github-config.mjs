/**
 * Restricted GitHub configuration and input validation.
 *
 * Enforces:
 *   1. Explicit organization allowlist (fail-closed if org is not allowed).
 *   2. Strict repository naming matching GitHub requirements.
 *   3. Strict visibility restrictions (public or private only).
 *   4. Zero shell syntax, zero control characters, zero path traversal.
 */

const ORG_NAME_PATTERN = /^[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}$/;
const REPO_NAME_PATTERN = /^[a-zA-Z0-9_.-]+$/;
const ALLOWED_VISIBILITIES = new Set(["public", "private"]);

export function validateOrganization(organization, allowedOrganizations = []) {
  if (typeof organization !== "string" || organization.trim().length === 0) {
    throw new Error("GITHUB_INVALID_ORG_NAME: Organization name must be a non-empty string.");
  }
  const org = organization.trim();
  if (!ORG_NAME_PATTERN.test(org) || org.endsWith("-")) {
    throw new Error(`GITHUB_INVALID_ORG_NAME: Organization name "${org}" contains invalid characters.`);
  }

  const allowedList = Array.isArray(allowedOrganizations) ? allowedOrganizations : [];
  const isAllowed = allowedList.some((allowed) => allowed.toLowerCase() === org.toLowerCase());
  if (!isAllowed) {
    throw new Error(
      `GITHUB_ORG_NOT_ALLOWED: Organization "${org}" is not in the allowedOrganizations list. ` +
      `Allowed organizations: [${allowedList.join(", ")}]. Fail-closed.`
    );
  }
  return org;
}

export function validateRepoName(name) {
  if (typeof name !== "string" || name.trim().length === 0) {
    throw new Error("GITHUB_INVALID_REPO_NAME: Repository name must be a non-empty string.");
  }
  const repo = name.trim();
  if (repo.length > 100) {
    throw new Error(`GITHUB_INVALID_REPO_NAME: Repository name "${repo}" exceeds maximum length of 100 characters.`);
  }
  if (repo === "." || repo === ".." || repo.toLowerCase().endsWith(".git")) {
    throw new Error(`GITHUB_INVALID_REPO_NAME: Repository name "${repo}" is reserved or invalid.`);
  }
  if (!REPO_NAME_PATTERN.test(repo) || repo.startsWith("-") || repo.endsWith("-")) {
    throw new Error(`GITHUB_INVALID_REPO_NAME: Repository name "${repo}" contains invalid characters.`);
  }
  return repo;
}

export function validateVisibility(visibility) {
  if (typeof visibility !== "string") {
    throw new Error("GITHUB_INVALID_VISIBILITY: Visibility must be a string.");
  }
  const normalized = visibility.trim().toLowerCase();
  if (!ALLOWED_VISIBILITIES.has(normalized)) {
    throw new Error(
      `GITHUB_INVALID_VISIBILITY: Visibility "${visibility}" is not supported. ` +
      `Only "public" and "private" are allowed.`
    );
  }
  return normalized;
}

export function getGithubConfig(registry) {
  if (!registry || typeof registry !== "object") {
    throw new Error("GITHUB_CAPABILITY_DISABLED: Configuration registry is not available.");
  }
  const config = registry.github;
  if (!config || typeof config !== "object" || config.enabled !== true) {
    throw new Error("GITHUB_CAPABILITY_DISABLED: GitHub management capability is disabled in projects.json.");
  }
  const allowedOrgs = Array.isArray(config.allowedOrganizations) ? config.allowedOrganizations : [];
  if (allowedOrgs.length === 0) {
    throw new Error("GITHUB_CAPABILITY_DISABLED: No allowedOrganizations configured in projects.json github settings.");
  }
  return {
    enabled: true,
    allowedOrganizations: allowedOrgs
  };
}
