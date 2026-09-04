/**
 * Output-schema contract tests (A3 / OUTPUT-SCHEMA work package).
 *
 * Two concerns are verified here:
 *
 *  1. TOOL DISCOVERY (OUTPUT_SCHEMA_COVERAGE = 22/22)
 *     Every one of the 22 baseline tools must advertise an `outputSchema`
 *     that is a strict JSON object schema. This is what lets MCP clients
 *     (ChatGPT, Claude, etc.) parse tool results reliably instead of scraping
 *     free-form text.
 *
 *  2. STRUCTURED RESULT VALIDATION
 *     For every tool that can safely succeed inside the fixture, we call it for
 *     real, take the `structuredContent` the SDK extracted, and validate it
 *     against that tool's own declared `outputSchema`. This proves the declared
 *     schema is not decorative — it matches what the handler actually returns.
 *
 * The fixture is fully HOME-isolated (see tests/support/harness.mjs); no real
 * repositories or registries are touched.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createFixture, openRunner } from "./support/harness.mjs";
import { EXPECTED_TOOLS } from "./inventory.test.mjs";

/**
 * Minimal JSON-schema validator covering the draft-07 subset our output
 * schemas actually use: type object/array/string/integer/number/boolean,
 * `enum`, nullable via `type: ["string","null"]`, `items`, `required`, and
 * `additionalProperties: false`. Returns a list of human-readable errors
 * (empty array means the instance is valid).
 */
function typeName(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function typeMatches(value, type) {
  switch (type) {
    case "null": return value === null;
    case "string": return typeof value === "string";
    case "boolean": return typeof value === "boolean";
    case "integer": return typeof value === "number" && Number.isInteger(value);
    case "number": return typeof value === "number" && !Number.isNaN(value);
    case "array": return Array.isArray(value);
    case "object": return typeof value === "object" && value !== null && !Array.isArray(value);
    default: return false;
  }
}

function validate(instance, schema, path = "$") {
  const errors = [];
  if (schema === true) return errors;
  if (schema === false) {
    errors.push(`${path}: no value permitted`);
    return errors;
  }

  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : null;
  if (types) {
    const matched = types.some((t) => typeMatches(instance, t));
    if (!matched) {
      errors.push(`${path}: expected type ${JSON.stringify(types)} but got ${typeName(instance)}`);
      return errors; // type mismatch: do not recurse into the value
    }
  }

  if (schema.enum && !schema.enum.includes(instance)) {
    errors.push(`${path}: value ${JSON.stringify(instance)} is not in enum ${JSON.stringify(schema.enum)}`);
  }

  const isObject = typeof instance === "object" && instance !== null && !Array.isArray(instance);
  if (isObject) {
    const props = schema.properties || {};
    const required = schema.required || [];
    for (const key of required) {
      if (!(key in instance)) errors.push(`${path}: missing required property "${key}"`);
    }
    for (const key of Object.keys(instance)) {
      if (key in props) {
        errors.push(...validate(instance[key], props[key], `${path}.${key}`));
      } else if (schema.additionalProperties === false) {
        errors.push(`${path}: additional property "${key}" is not allowed`);
      }
    }
  }

  if (Array.isArray(instance) && schema.items) {
    instance.forEach((item, i) => {
      errors.push(...validate(item, schema.items, `${path}[${i}]`));
    });
  }

  return errors;
}

describe("output schema — tool discovery", () => {
  it("exposes a strict outputSchema for all 24 tools", async () => {
    await createFixture().then(async (fixture) => {
      const handle = await openRunner(fixture);
      try {
        const { tools } = await handle.client.listTools();
        assert.equal(tools.length, EXPECTED_TOOLS.length,
          `expected ${EXPECTED_TOOLS.length} tools, got ${tools.length}`);

        const actualNames = tools.map((t) => t.name).sort();
        const expectedNames = [...EXPECTED_TOOLS].sort();
        assert.deepEqual(actualNames, expectedNames,
          "tool name set must match the pinned baseline exactly");

        const seen = new Set();
        let coverage = 0;
        for (const tool of tools) {
          assert.ok(!(seen.has(tool.name)), `duplicate tool name: ${tool.name}`);
          seen.add(tool.name);

          assert.ok(tool.outputSchema, `${tool.name} must declare an outputSchema`);
          assert.equal(tool.outputSchema.type, "object",
            `${tool.name} outputSchema root must be "object"`);
          assert.equal(tool.outputSchema.additionalProperties, false,
            `${tool.name} outputSchema must be strict (additionalProperties: false)`);
          assert.ok(tool.outputSchema.properties && typeof tool.outputSchema.properties === "object",
            `${tool.name} outputSchema must declare properties`);
          assert.ok(Array.isArray(tool.outputSchema.required) && tool.outputSchema.required.length > 0,
            `${tool.name} outputSchema must declare at least one required field`);
          assert.ok(tool.inputSchema, `${tool.name} must still declare an inputSchema`);

          coverage += 1;
        }
        assert.equal(coverage, EXPECTED_TOOLS.length,
          `OUTPUT_SCHEMA_COVERAGE expected ${EXPECTED_TOOLS.length}, got ${coverage}`);
      } finally {
        await handle.close();
        await fixture.cleanup();
      }
    });
  });
});

describe("output schema — structured result validation", () => {
  /** Fetch tools/list once and index outputSchema by name. */
  async function loadSchemaMap(client) {
    const { tools } = await client.listTools();
    const map = {};
    for (const t of tools) map[t.name] = t.outputSchema;
    return map;
  }

  /** Call a tool, assert success, and validate its structuredContent against its schema. */
  async function assertStructured(client, schemas, name, args) {
    const res = await client.callTool({ name, arguments: args });
    assert.notEqual(res.isError, true, `${name} should succeed; got error: ${JSON.stringify(res.content)}`);
    assert.ok(res.structuredContent != null, `${name} must return structuredContent`);
    const errors = validate(res.structuredContent, schemas[name]);
    assert.equal(errors.length, 0,
      `${name} structuredContent failed its own outputSchema:\n  ${errors.join("\n  ")}`);
    return res.structuredContent;
  }

  it("validates real results for the file-write chain, read paths, git, and worktree tools", async () => {
    await createFixture().then(async (fixture) => {
      const handle = await openRunner(fixture);
      try {
        const client = handle.client;
        const schemas = await loadSchemaMap(client);

        // list_projects
        const lp = await assertStructured(client, schemas, "list_projects", {});
        assert.ok(Array.isArray(lp.projects) && lp.projects.length >= 2,
          "list_projects.projects must be a non-empty array");

        // project_info on the READ_ONLY source repo
        const pi = await assertStructured(client, schemas, "project_info", { project: "fixture-source" });
        assert.equal(pi.project, "fixture-source");
        assert.equal(pi.git.isGit, true, "fixture-source is a git repo");
        assert.equal(pi.mode, "READ_ONLY");

        // list_directory on the READ_WRITE sandbox
        const ld = await assertStructured(client, schemas, "list_directory", { project: "fixture-sandbox", path: "." });
        assert.ok(Array.isArray(ld.entries), "list_directory.entries must be an array");
        assert.equal(ld.truncated, false, "fixture sandbox listing should not be truncated");

        // file_info
        const fi = await assertStructured(client, schemas, "file_info",
          { project: "fixture-sandbox", path: "notes.txt" });
        assert.equal(fi.path, "notes.txt");
        assert.ok(typeof fi.bytes === "number" && fi.bytes > 0, "file_info.bytes must be a positive integer");
        assert.ok(/^[0-9a-f]{64}$/.test(fi.sha256), "file_info.sha256 must be a 64-char hex digest");

        // read_file
        const rf = await assertStructured(client, schemas, "read_file",
          { project: "fixture-sandbox", path: "notes.txt" });
        assert.equal(rf.content, "hello sandbox\n");

        // create_file
        const newPath = "sc-validate.txt";
        const cf = await assertStructured(client, schemas, "create_file",
          { project: "fixture-sandbox", path: newPath, content: "alpha" });
        assert.equal(cf.created, true);
        assert.equal(cf.bytes, 5, "create_file.bytes must equal the written content length");
        assert.ok(/^[0-9a-f]{64}$/.test(cf.sha256), "create_file.sha256 must be a 64-char hex digest");
        const createdSha = cf.sha256;

        // replace_text (expectedSha256 is the concurrency guard = current file sha)
        const rt = await assertStructured(client, schemas, "replace_text",
          { project: "fixture-sandbox", path: newPath, expectedSha256: cf.sha256, oldText: "alpha", newText: "betadelta" });
        assert.equal(rt.replaced, true);
        assert.equal(rt.previousSha256, cf.sha256, "previousSha256 must equal the pre-replacement sha256");
        assert.notEqual(rt.sha256, cf.sha256, "replace_text.sha256 must differ after the content change");
        assert.equal(rt.bytes, 9, "replace_text.bytes must equal the new content length (betadelta)");

        // read_file reflects the change
        const rf2 = await assertStructured(client, schemas, "read_file",
          { project: "fixture-sandbox", path: newPath });
        assert.equal(rf2.content, "betadelta");

        // delete_file (expectedSha256 = current file sha after the replace)
        const df = await assertStructured(client, schemas, "delete_file",
          { project: "fixture-sandbox", path: newPath, expectedSha256: rt.sha256 });
        assert.equal(df.deleted, true);

        // git_status on the source repo
        const gs = await assertStructured(client, schemas, "git_status", { project: "fixture-source" });
        assert.equal(typeof gs.status, "string", "git_status.status must be a string");

        // git_worktree_create from the source repo (branch must be mcp/-prefixed)
        const wtc = await assertStructured(client, schemas, "git_worktree_create",
          { project: "fixture-source", branch: "mcp/sc-worktree" });
        assert.equal(wtc.created, true);
        assert.equal(wtc.mode, "READ_WRITE", "worktree must be the only writable surface");
        assert.equal(wtc.sourceProject, "fixture-source");
        assert.equal(wtc.branch, "mcp/sc-worktree");
        assert.ok(typeof wtc.root === "string" && wtc.root.length > 0, "worktree root must be a path");
        assert.ok(typeof wtc.project === "string" && wtc.project.length > 0, "worktree must return its project key");

        // git_worktree_remove (uses the worktree's own project key)
        const wtr = await assertStructured(client, schemas, "git_worktree_remove",
          { project: wtc.project });
        assert.equal(wtr.removed, true);
        assert.equal(wtr.sourceProject, "fixture-source");
        assert.equal(wtr.branch, "mcp/sc-worktree");
        assert.equal(wtr.project, wtc.project, "remove must report the same worktree project key");
      } finally {
        await handle.close();
        await fixture.cleanup();
      }
    });
  });

  it("keeps run_script denied and emits no structuredContent", async () => {
    await createFixture().then(async (fixture) => {
      const handle = await openRunner(fixture);
      try {
        const res = await handle.client.callTool({
          name: "run_script",
          arguments: { project: "fixture-sandbox", script: "build" }
        });
        assert.equal(res.isError, true, "run_script must remain denied by default");
        assert.equal(res.structuredContent, undefined,
          "denied run_script must not emit structuredContent");
      } finally {
        await handle.close();
        await fixture.cleanup();
      }
    });
  });

  it("keeps github repository tools fail-closed without credential/config and emits no structuredContent", async () => {
    await createFixture().then(async (fixture) => {
      const handle = await openRunner(fixture);
      try {
        const schemas = await loadSchemaMap(handle.client);

        const resInfo = await handle.client.callTool({
          name: "github_repository_info",
          arguments: { organization: "CosmGrid", repository: "test-repo" }
        });
        assert.equal(resInfo.isError, true, "github_repository_info must fail-closed by default");
        assert.equal(resInfo.structuredContent, undefined);

        const resCreate = await handle.client.callTool({
          name: "github_repository_create",
          arguments: { organization: "CosmGrid", name: "test-repo", visibility: "private" }
        });
        assert.equal(resCreate.isError, true, "github_repository_create must fail-closed by default");
        assert.equal(resCreate.structuredContent, undefined);

        // Validate sample successful payloads against the actual exposed schemas
        const sampleInfo = {
          exists: true,
          owner: "CosmGrid",
          name: "test-repo",
          visibility: "private",
          defaultBranch: "main",
          fork: false,
          archived: false,
          repositoryUrl: "https://github.com/CosmGrid/test-repo"
        };
        const infoErrors = validate(sampleInfo, schemas.github_repository_info);
        assert.equal(infoErrors.length, 0, `sample info schema validation failed: ${infoErrors.join(", ")}`);

        const sampleCreate = {
          created: true,
          status: "CREATED",
          owner: "CosmGrid",
          name: "test-repo",
          visibility: "private",
          repositoryUrl: "https://github.com/CosmGrid/test-repo",
          cloneUrl: "https://github.com/CosmGrid/test-repo.git",
          defaultBranch: "main"
        };
        const createErrors = validate(sampleCreate, schemas.github_repository_create);
        assert.equal(createErrors.length, 0, `sample create schema validation failed: ${createErrors.join(", ")}`);
      } finally {
        await handle.close();
        await fixture.cleanup();
      }
    });
  });
});
