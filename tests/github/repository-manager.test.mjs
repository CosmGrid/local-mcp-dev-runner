import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { getRepositoryInfo, createRepository } from "../../scripts/github-manager.mjs";
import { githubAuditLogPath } from "../../scripts/github-audit.mjs";

describe("GitHub Repository Manager & Idempotency", () => {
  let runtimeRoot;
  const FAKE_TOKEN = "ghp_SecretTokenXYZ123456";

  beforeEach(async () => {
    runtimeRoot = await mkdtemp(path.join(tmpdir(), "lmdr-gh-mgr-"));
  });

  afterEach(async () => {
    if (runtimeRoot) {
      await rm(runtimeRoot, { recursive: true, force: true }).catch(() => {});
    }
  });

  const validRegistry = {
    github: {
      enabled: true,
      allowedOrganizations: ["CosmGrid"]
    }
  };

  it("handles repository lookup success", async () => {
    const fakeClient = {
      async getRepository({ owner, repo, token }) {
        assert.equal(owner, "CosmGrid");
        assert.equal(repo, "local-mcp-dev-runner");
        assert.equal(token, FAKE_TOKEN);
        return {
          id: 123,
          name: "local-mcp-dev-runner",
          owner: { login: "CosmGrid" },
          visibility: "public",
          private: false,
          default_branch: "main",
          fork: false,
          archived: false,
          html_url: "https://github.com/CosmGrid/local-mcp-dev-runner"
        };
      }
    };

    const res = await getRepositoryInfo({
      registry: validRegistry,
      organization: "CosmGrid",
      repository: "local-mcp-dev-runner",
      tokenReader: async () => FAKE_TOKEN,
      client: fakeClient,
      runtimeRoot
    });

    assert.equal(res.exists, true);
    assert.equal(res.owner, "CosmGrid");
    assert.equal(res.name, "local-mcp-dev-runner");
    assert.equal(res.visibility, "public");
    assert.equal(res.defaultBranch, "main");
    assert.equal(res.fork, false);
    assert.equal(res.archived, false);
    assert.equal(res.repositoryUrl, "https://github.com/CosmGrid/local-mcp-dev-runner");

    // Verify audit log
    const logContent = await readFile(githubAuditLogPath(runtimeRoot), "utf8");
    assert.ok(logContent.includes("github_repository_info"));
    assert.ok(logContent.includes("SUCCESS"));
    assert.ok(!logContent.includes(FAKE_TOKEN), "Token must NEVER appear in audit log");
  });

  it("handles repository lookup when repository does not exist", async () => {
    const fakeClient = {
      async getRepository() {
        return null; // 404
      }
    };

    const res = await getRepositoryInfo({
      registry: validRegistry,
      organization: "CosmGrid",
      repository: "non-existent-repo",
      tokenReader: async () => FAKE_TOKEN,
      client: fakeClient,
      runtimeRoot
    });

    assert.equal(res.exists, false);
    assert.equal(res.owner, "CosmGrid");
    assert.equal(res.name, "non-existent-repo");
    assert.equal(res.visibility, null);
    assert.equal(res.defaultBranch, null);
    assert.equal(res.repositoryUrl, null);
  });

  it("creates a new public repository", async () => {
    let createdPayload = null;
    const fakeClient = {
      async getRepository() {
        return null; // not exists initially
      },
      async createOrgRepository(payload) {
        createdPayload = payload;
        return {
          id: 456,
          name: payload.name,
          owner: { login: payload.org },
          visibility: payload.visibility,
          private: payload.visibility === "private",
          html_url: `https://github.com/${payload.org}/${payload.name}`,
          clone_url: `https://github.com/${payload.org}/${payload.name}.git`,
          default_branch: "main"
        };
      }
    };

    const res = await createRepository({
      registry: validRegistry,
      organization: "CosmGrid",
      name: "new-public-repo",
      visibility: "public",
      description: "A test public repo",
      tokenReader: async () => FAKE_TOKEN,
      client: fakeClient,
      runtimeRoot
    });

    assert.equal(res.created, true);
    assert.equal(res.status, "CREATED");
    assert.equal(res.owner, "CosmGrid");
    assert.equal(res.name, "new-public-repo");
    assert.equal(res.visibility, "public");
    assert.equal(createdPayload.visibility, "public");
    assert.equal(createdPayload.description, "A test public repo");
    assert.equal(createdPayload.auto_init, false);
  });

  it("creates a new private repository", async () => {
    const fakeClient = {
      async getRepository() {
        return null;
      },
      async createOrgRepository(payload) {
        return {
          id: 789,
          name: payload.name,
          owner: { login: payload.org },
          visibility: "private",
          private: true,
          html_url: `https://github.com/${payload.org}/${payload.name}`,
          clone_url: `https://github.com/${payload.org}/${payload.name}.git`,
          default_branch: null
        };
      }
    };

    const res = await createRepository({
      registry: validRegistry,
      organization: "CosmGrid",
      name: "new-private-repo",
      visibility: "private",
      tokenReader: async () => FAKE_TOKEN,
      client: fakeClient,
      runtimeRoot
    });

    assert.equal(res.created, true);
    assert.equal(res.status, "CREATED");
    assert.equal(res.visibility, "private");
  });

  it("idempotently handles repository that already exists with matching visibility", async () => {
    let createCalled = false;
    const fakeClient = {
      async getRepository({ owner, repo }) {
        return {
          name: repo,
          owner: { login: owner },
          visibility: "private",
          private: true,
          html_url: `https://github.com/${owner}/${repo}`,
          clone_url: `https://github.com/${owner}/${repo}.git`,
          default_branch: "main"
        };
      },
      async createOrgRepository() {
        createCalled = true;
      }
    };

    const res = await createRepository({
      registry: validRegistry,
      organization: "CosmGrid",
      name: "existing-repo",
      visibility: "private",
      tokenReader: async () => FAKE_TOKEN,
      client: fakeClient,
      runtimeRoot
    });

    assert.equal(createCalled, false, "Must NOT call createOrgRepository when already exists");
    assert.equal(res.created, false);
    assert.equal(res.status, "ALREADY_EXISTS");
    assert.equal(res.owner, "CosmGrid");
    assert.equal(res.name, "existing-repo");
    assert.equal(res.visibility, "private");
  });

  it("throws GITHUB_VISIBILITY_CONFLICT when repository exists with differing visibility", async () => {
    const fakeClient = {
      async getRepository({ owner, repo }) {
        return {
          name: repo,
          owner: { login: owner },
          visibility: "public",
          private: false,
          html_url: `https://github.com/${owner}/${repo}`,
          clone_url: `https://github.com/${owner}/${repo}.git`
        };
      }
    };

    await assert.rejects(
      () => createRepository({
        registry: validRegistry,
        organization: "CosmGrid",
        name: "existing-repo",
        visibility: "private", // conflicts with existing public
        tokenReader: async () => FAKE_TOKEN,
        client: fakeClient,
        runtimeRoot
      }),
      /GITHUB_VISIBILITY_CONFLICT/
    );
  });

  it("fails closed when tokenReader throws GITHUB_CREDENTIAL_MISSING", async () => {
    await assert.rejects(
      () => getRepositoryInfo({
        registry: validRegistry,
        organization: "CosmGrid",
        repository: "test",
        tokenReader: async () => {
          throw new Error("GITHUB_CREDENTIAL_MISSING: token not in keychain");
        },
        client: {},
        runtimeRoot
      }),
      /GITHUB_CREDENTIAL_MISSING/
    );

    await assert.rejects(
      () => createRepository({
        registry: validRegistry,
        organization: "CosmGrid",
        name: "test",
        visibility: "public",
        tokenReader: async () => {
          throw new Error("GITHUB_CREDENTIAL_MISSING: token not in keychain");
        },
        client: {},
        runtimeRoot
      }),
      /GITHUB_CREDENTIAL_MISSING/
    );
  });
});
