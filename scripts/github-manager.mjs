/**
 * High-level Restricted GitHub Repository Manager.
 *
 * Enforces:
 *   - Configuration gating (must be enabled in projects.json).
 *   - Organization allowlist gating (fail-closed).
 *   - Input sanitization (repo name, visibility).
 *   - Non-destructive idempotency on create:
 *       A. Not exists -> create.
 *       B. Exists with identical visibility -> return ALREADY_EXISTS (no-op).
 *       C. Exists with conflicting visibility -> throw GITHUB_VISIBILITY_CONFLICT.
 *   - Complete audit trail with credential redaction.
 */

import { getGithubConfig, validateOrganization, validateRepoName, validateVisibility } from "./github-config.mjs";
import { writeGithubAudit } from "./github-audit.mjs";

export async function getRepositoryInfo({
  registry,
  organization,
  repository,
  tokenReader,
  client,
  runtimeRoot
}) {
  const config = getGithubConfig(registry);
  const org = validateOrganization(organization, config.allowedOrganizations);
  const repo = validateRepoName(repository);

  let token;
  try {
    token = await tokenReader();
  } catch (err) {
    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_info",
        organization: org,
        repository: repo,
        requestedVisibility: null,
        result: "FAILED",
        errorCategory: "GITHUB_CREDENTIAL_MISSING",
        status: null
      }).catch(() => {});
    }
    throw err;
  }

  try {
    const data = await client.getRepository({ owner: org, repo, token });
    const exists = data !== null && typeof data === "object";

    const result = {
      exists,
      owner: exists ? (data.owner?.login || org) : org,
      name: exists ? data.name : repo,
      visibility: exists ? (data.visibility || (data.private ? "private" : "public")) : null,
      defaultBranch: exists ? (data.default_branch || null) : null,
      fork: exists ? Boolean(data.fork) : null,
      archived: exists ? Boolean(data.archived) : null,
      repositoryUrl: exists ? (data.html_url || null) : null
    };

    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_info",
        organization: org,
        repository: repo,
        requestedVisibility: null,
        result: "SUCCESS",
        errorCategory: null,
        status: exists ? "FOUND" : "NOT_FOUND"
      });
    }

    return result;
  } catch (error) {
    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_info",
        organization: org,
        repository: repo,
        requestedVisibility: null,
        result: "FAILED",
        errorCategory: error?.category || "GITHUB_API_ERROR",
        status: null
      }).catch(() => {});
    }
    throw error;
  }
}

export async function createRepository({
  registry,
  organization,
  name,
  visibility,
  description = null,
  tokenReader,
  client,
  runtimeRoot
}) {
  const config = getGithubConfig(registry);
  const org = validateOrganization(organization, config.allowedOrganizations);
  const repoName = validateRepoName(name);
  const targetVisibility = validateVisibility(visibility);

  let token;
  try {
    token = await tokenReader();
  } catch (err) {
    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_create",
        organization: org,
        repository: repoName,
        requestedVisibility: targetVisibility,
        result: "FAILED",
        errorCategory: "GITHUB_CREDENTIAL_MISSING",
        status: null
      }).catch(() => {});
    }
    throw err;
  }

  // Idempotency Step 1: probe existing repository
  let existing = null;
  try {
    existing = await client.getRepository({ owner: org, repo: repoName, token });
  } catch (err) {
    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_create",
        organization: org,
        repository: repoName,
        requestedVisibility: targetVisibility,
        result: "FAILED",
        errorCategory: err?.category || "PROBE_FAILED",
        status: null
      }).catch(() => {});
    }
    throw err;
  }

  if (existing) {
    const existingVis = existing.visibility || (existing.private ? "private" : "public");
    if (existingVis !== targetVisibility) {
      const conflictMsg =
        `GITHUB_VISIBILITY_CONFLICT: Repository "${org}/${repoName}" already exists with visibility "${existingVis}", ` +
        `which conflicts with requested visibility "${targetVisibility}". Manual intervention required.`;
      if (runtimeRoot) {
        await writeGithubAudit(runtimeRoot, {
          operation: "github_repository_create",
          organization: org,
          repository: repoName,
          requestedVisibility: targetVisibility,
          result: "FAILED",
          errorCategory: "GITHUB_VISIBILITY_CONFLICT",
          status: "CONFLICT"
        }).catch(() => {});
      }
      throw new Error(conflictMsg);
    }

    // Existing and matches requested visibility -> idempotent return
    const result = {
      created: false,
      status: "ALREADY_EXISTS",
      owner: existing.owner?.login || org,
      name: existing.name,
      visibility: existingVis,
      repositoryUrl: existing.html_url || `https://github.com/${org}/${repoName}`,
      cloneUrl: existing.clone_url || `https://github.com/${org}/${repoName}.git`,
      defaultBranch: existing.default_branch || null
    };

    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_create",
        organization: org,
        repository: repoName,
        requestedVisibility: targetVisibility,
        result: "ALREADY_EXISTS",
        errorCategory: null,
        status: "ALREADY_EXISTS"
      });
    }

    return result;
  }

  // Idempotency Step 2: create new repository
  try {
    const created = await client.createOrgRepository({
      org,
      name: repoName,
      visibility: targetVisibility,
      description,
      auto_init: false,
      token
    });

    const result = {
      created: true,
      status: "CREATED",
      owner: created.owner?.login || org,
      name: created.name,
      visibility: created.visibility || (created.private ? "private" : "public"),
      repositoryUrl: created.html_url || `https://github.com/${org}/${repoName}`,
      cloneUrl: created.clone_url || `https://github.com/${org}/${repoName}.git`,
      defaultBranch: created.default_branch || null
    };

    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_create",
        organization: org,
        repository: repoName,
        requestedVisibility: targetVisibility,
        result: "SUCCESS",
        errorCategory: null,
        status: "CREATED"
      });
    }

    return result;
  } catch (error) {
    if (runtimeRoot) {
      await writeGithubAudit(runtimeRoot, {
        operation: "github_repository_create",
        organization: org,
        repository: repoName,
        requestedVisibility: targetVisibility,
        result: "FAILED",
        errorCategory: error?.category || "GITHUB_CREATE_FAILED",
        status: null
      }).catch(() => {});
    }
    throw error;
  }
}
