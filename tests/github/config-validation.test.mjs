import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  getGithubConfig,
  validateOrganization,
  validateRepoName,
  validateVisibility
} from "../../scripts/github-config.mjs";

describe("GitHub Config & Validation", () => {
  describe("getGithubConfig", () => {
    it("throws GITHUB_CAPABILITY_DISABLED if registry is missing or null", () => {
      assert.throws(() => getGithubConfig(null), /GITHUB_CAPABILITY_DISABLED/);
      assert.throws(() => getGithubConfig({}), /GITHUB_CAPABILITY_DISABLED/);
    });

    it("throws GITHUB_CAPABILITY_DISABLED if github.enabled is false or not a boolean", () => {
      assert.throws(() => getGithubConfig({ github: { enabled: false } }), /GITHUB_CAPABILITY_DISABLED/);
      assert.throws(() => getGithubConfig({ github: { enabled: "true" } }), /GITHUB_CAPABILITY_DISABLED/);
    });

    it("throws GITHUB_CAPABILITY_DISABLED if allowedOrganizations is empty or not an array", () => {
      assert.throws(() => getGithubConfig({ github: { enabled: true, allowedOrganizations: [] } }), /GITHUB_CAPABILITY_DISABLED/);
      assert.throws(() => getGithubConfig({ github: { enabled: true, allowedOrganizations: "CosmGrid" } }), /GITHUB_CAPABILITY_DISABLED/);
    });

    it("loads valid configuration successfully", () => {
      const config = getGithubConfig({
        github: {
          enabled: true,
          allowedOrganizations: ["CosmGrid", "CosmGrid-Labs"]
        }
      });
      assert.equal(config.enabled, true);
      assert.deepEqual(config.allowedOrganizations, ["CosmGrid", "CosmGrid-Labs"]);
    });
  });

  describe("validateOrganization", () => {
    const allowed = ["CosmGrid"];

    it("accepts allowed organization name", () => {
      assert.equal(validateOrganization("CosmGrid", allowed), "CosmGrid");
      // case-insensitive matching in allowlist
      assert.equal(validateOrganization("cosmgrid", allowed), "cosmgrid");
    });

    it("throws GITHUB_ORG_NOT_ALLOWED for unauthorized organization (fail-closed)", () => {
      assert.throws(
        () => validateOrganization("OtherOrg", allowed),
        /GITHUB_ORG_NOT_ALLOWED.*Fail-closed/
      );
      assert.throws(
        () => validateOrganization("EvilOrg", allowed),
        /GITHUB_ORG_NOT_ALLOWED/
      );
    });

    it("throws GITHUB_INVALID_ORG_NAME for malformed organization names", () => {
      assert.throws(() => validateOrganization("", allowed), /GITHUB_INVALID_ORG_NAME/);
      assert.throws(() => validateOrganization("-invalid", allowed), /GITHUB_INVALID_ORG_NAME/);
      assert.throws(() => validateOrganization("invalid-", allowed), /GITHUB_INVALID_ORG_NAME/);
      assert.throws(() => validateOrganization("org/injection", allowed), /GITHUB_INVALID_ORG_NAME/);
      assert.throws(() => validateOrganization("org..dot", allowed), /GITHUB_INVALID_ORG_NAME/);
      assert.throws(() => validateOrganization("a".repeat(40), allowed), /GITHUB_INVALID_ORG_NAME/);
    });
  });

  describe("validateRepoName", () => {
    it("accepts valid repository names", () => {
      assert.equal(validateRepoName("local-mcp-dev-runner"), "local-mcp-dev-runner");
      assert.equal(validateRepoName("my_project.v2"), "my_project.v2");
      assert.equal(validateRepoName("SimpleRepo"), "SimpleRepo");
    });

    it("rejects invalid or dangerous repository names", () => {
      assert.throws(() => validateRepoName(""), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("."), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName(".."), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("repo.git"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("-leading-hyphen"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("trailing-hyphen-"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("repo with spaces"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("repo/slash"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("repo;rm -rf"), /GITHUB_INVALID_REPO_NAME/);
      assert.throws(() => validateRepoName("a".repeat(101)), /GITHUB_INVALID_REPO_NAME/);
    });
  });

  describe("validateVisibility", () => {
    it("accepts public and private", () => {
      assert.equal(validateVisibility("public"), "public");
      assert.equal(validateVisibility("private"), "private");
      assert.equal(validateVisibility("PUBLIC"), "public");
      assert.equal(validateVisibility("PRIVATE"), "private");
    });

    it("rejects internal and arbitrary strings", () => {
      assert.throws(() => validateVisibility("internal"), /GITHUB_INVALID_VISIBILITY/);
      assert.throws(() => validateVisibility("secret"), /GITHUB_INVALID_VISIBILITY/);
      assert.throws(() => validateVisibility(""), /GITHUB_INVALID_VISIBILITY/);
      assert.throws(() => validateVisibility(123), /GITHUB_INVALID_VISIBILITY/);
    });
  });
});
