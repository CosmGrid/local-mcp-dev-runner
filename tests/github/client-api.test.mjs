import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { GitHubApiClient } from "../../scripts/github-client.mjs";

describe("GitHubApiClient HTTP & Network Gate", () => {
  let server;
  let serverUrl;
  let serverHandler = (req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  };

  before(async () => {
    server = http.createServer((req, res) => {
      serverHandler(req, res);
    });
    await new Promise((resolve) => {
      server.listen(0, "127.0.0.1", () => {
        const port = server.address().port;
        serverUrl = `http://127.0.0.1:${port}`;
        resolve();
      });
    });
  });

  after(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  const FAKE_TOKEN = "TEST_SYNTHETIC_GITHUB_TOKEN_VALUE_FOR_MOCK";

  it("throws GITHUB_CREDENTIAL_MISSING if token is missing", async () => {
    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test", token: null }),
      /GITHUB_CREDENTIAL_MISSING/
    );
    await assert.rejects(
      () => client.createOrgRepository({ org: "CosmGrid", name: "test", visibility: "public", token: "" }),
      /GITHUB_CREDENTIAL_MISSING/
    );
  });

  it("handles 200 OK repository lookup", async () => {
    serverHandler = (req, res) => {
      assert.equal(req.method, "GET");
      assert.equal(req.url, "/repos/CosmGrid/test-repo");
      assert.equal(req.headers["authorization"], `Bearer ${FAKE_TOKEN}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        id: 1001,
        name: "test-repo",
        owner: { login: "CosmGrid" },
        visibility: "public",
        private: false,
        default_branch: "main",
        fork: false,
        archived: false,
        html_url: "https://github.com/CosmGrid/test-repo"
      }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    const repo = await client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN });
    assert.equal(repo.name, "test-repo");
    assert.equal(repo.owner.login, "CosmGrid");
    assert.equal(repo.visibility, "public");
  });

  it("handles 404 as null (not found)", async () => {
    serverHandler = (req, res) => {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: "Not Found" }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    const repo = await client.getRepository({ owner: "CosmGrid", repo: "missing-repo", token: FAKE_TOKEN });
    assert.equal(repo, null);
  });

  it("handles 401 Unauthorized with GITHUB_AUTH_FAILED", async () => {
    serverHandler = (req, res) => {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: "Bad credentials" }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN }),
      /GITHUB_AUTH_FAILED/
    );
  });

  it("handles 403 Forbidden with GITHUB_FORBIDDEN", async () => {
    serverHandler = (req, res) => {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: "Resource not accessible by integration" }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN }),
      /GITHUB_FORBIDDEN/
    );
  });

  it("handles 409 Conflict with GITHUB_CONFLICT", async () => {
    serverHandler = (req, res) => {
      res.writeHead(409, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: "Repository already exists" }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.createOrgRepository({ org: "CosmGrid", name: "test-repo", visibility: "public", token: FAKE_TOKEN }),
      /GITHUB_CONFLICT/
    );
  });

  it("handles 422 Validation Failed with GITHUB_VALIDATION_FAILED", async () => {
    serverHandler = (req, res) => {
      res.writeHead(422, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: "Repository creation failed: name already exists" }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.createOrgRepository({ org: "CosmGrid", name: "test-repo", visibility: "public", token: FAKE_TOKEN }),
      /GITHUB_VALIDATION_FAILED/
    );
  });

  it("handles malformed JSON with GITHUB_MALFORMED_RESPONSE", async () => {
    serverHandler = (req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("Not a valid json response {{{");
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN }),
      /GITHUB_MALFORMED_RESPONSE/
    );
  });

  it("handles timeout with GITHUB_TIMEOUT", async () => {
    serverHandler = (req, res) => {
      // Intentional delay longer than client timeout
      setTimeout(() => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      }, 300);
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl, timeoutMs: 50 });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN }),
      /GITHUB_TIMEOUT/
    );
  });

  it("handles network unavailable with GITHUB_NETWORK_ERROR", async () => {
    // Port 1 is reserved and usually closed/unreachable
    const client = new GitHubApiClient({ apiBaseUrl: "http://127.0.0.1:1" });
    await assert.rejects(
      () => client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN }),
      /GITHUB_NETWORK_ERROR/
    );
  });

  it("strictly redacts token so it never appears in error messages or stacks", async () => {
    serverHandler = (req, res) => {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ message: `Internal error reflecting token: ${FAKE_TOKEN}` }));
    };

    const client = new GitHubApiClient({ apiBaseUrl: serverUrl });
    try {
      await client.getRepository({ owner: "CosmGrid", repo: "test-repo", token: FAKE_TOKEN });
      assert.fail("Should have thrown");
    } catch (err) {
      assert.ok(!err.message.includes(FAKE_TOKEN), "Token must not appear in error message");
      assert.ok(!err.stack.includes(FAKE_TOKEN), "Token must not appear in error stack");
      assert.ok(err.message.includes("[REDACTED_GITHUB_TOKEN]"), "Token should be replaced by redacted placeholder");
    }
  });
});
