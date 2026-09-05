import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { withFixtureAndRunner } from "../support/harness.mjs";

describe("GitHub Security Boundary & Immutability Gates", () => {
  it("strictly forbids delete_repository, push, deploy or arbitrary tool expansion", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const { tools } = await client.listTools();
      const names = tools.map((t) => t.name);

      assert.equal(names.includes("delete_repository"), false, "delete_repository must NOT exist");
      assert.equal(names.includes("github_delete_repository"), false, "github_delete_repository must NOT exist");
      assert.equal(names.includes("git_push"), false, "git_push must NOT exist");
      assert.equal(names.includes("push"), false, "push must NOT exist");
      assert.equal(names.includes("deploy"), false, "deploy must NOT exist");
      assert.equal(names.includes("transfer_repository"), false, "transfer_repository must NOT exist");
      assert.equal(names.includes("archive_repository"), false, "archive_repository must NOT exist");
    });
  });

  it("rejects arbitrary URL / arbitrary REST path parameter via strict schema", async () => {
    await withFixtureAndRunner({}, async (client) => {
      // Trying to inject arbitrary URL or arbitrary REST path to github_repository_info
      const resInfo = await client.callTool({
        name: "github_repository_info",
        arguments: {
          organization: "CosmGrid",
          repository: "local-mcp-dev-runner",
          url: "https://evil.com/leak",
          path: "/user/repos",
          method: "DELETE"
        }
      });
      assert.equal(resInfo.isError, true, "Must reject extra arguments");

      // Trying to inject arbitrary arguments to github_repository_create
      const resCreate = await client.callTool({
        name: "github_repository_create",
        arguments: {
          organization: "CosmGrid",
          name: "local-mcp-dev-runner",
          visibility: "private",
          url: "https://evil.com",
          token: "TEST_LEAKED_SYNTHETIC_TOKEN",
          auto_init: true
        }
      });
      assert.equal(resCreate.isError, true, "Must reject extra arguments");
    });
  });

  it("fails closed when GitHub capability is not enabled in projects.json", async () => {
    await withFixtureAndRunner({ projects: {} }, async (client) => {
      const res = await client.callTool({
        name: "github_repository_info",
        arguments: {
          organization: "CosmGrid",
          repository: "local-mcp-dev-runner"
        }
      });
      assert.equal(res.isError, true);
      const text = res.content?.[0]?.text || "";
      assert.ok(text.includes("GITHUB_CAPABILITY_DISABLED"), "Must report GITHUB_CAPABILITY_DISABLED");
    });
  });

  it("fails closed when organization is not allowed", async () => {
    const fixtureOptions = {
      projects: {}
    };
    await withFixtureAndRunner(fixtureOptions, async (client, fixture) => {
      // Configure github enabled with only CosmGrid
      const reg = await fixture.readRegistry();
      reg.github = {
        enabled: true,
        allowedOrganizations: ["CosmGrid"]
      };
      await fixture.writeRegistry(reg);

      const res = await client.callTool({
        name: "github_repository_info",
        arguments: {
          organization: "UnauthorizedOrg",
          repository: "some-repo"
        }
      });
      assert.equal(res.isError, true);
      const text = res.content?.[0]?.text || "";
      assert.ok(text.includes("GITHUB_ORG_NOT_ALLOWED"), "Must fail-closed with GITHUB_ORG_NOT_ALLOWED");
    });
  });

  it("ensures token does not appear in MCP output even on credential failure", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const reg = await fixture.readRegistry();
      reg.github = {
        enabled: true,
        allowedOrganizations: ["CosmGrid"]
      };
      await fixture.writeRegistry(reg);

      const res = await client.callTool({
        name: "github_repository_info",
        arguments: {
          organization: "CosmGrid",
          repository: "test"
        }
      });
      assert.equal(res.isError, true);
      const text = res.content?.[0]?.text || "";
      assert.ok(!text.includes("ghp_"), "Must not leak any token prefix");
      assert.ok(!text.includes("Bearer"), "Must not leak Authorization bearer");
      assert.ok(text.includes("GITHUB_CREDENTIAL_MISSING"));
    });
  });
});
