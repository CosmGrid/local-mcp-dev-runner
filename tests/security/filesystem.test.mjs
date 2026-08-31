/**
 * Filesystem security gate.
 *
 * Every assertion here runs against a throwaway project registry under a
 * throwaway HOME. The real registry (~/.config/local-mcp-dev-runner/projects.json)
 * and the real business repositories are never touched.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir, stat, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  assertDenied,
  assertOk,
  sha256,
  withFixtureAndRunner
} from "../support/harness.mjs";

describe("read-only project policy", () => {
  it("refuses to create a file in a READ_ONLY project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: { project: "fixture-source", path: "new.txt", content: "nope" }
      });
      assertDenied(result, /Project is read-only/);
    });
  });

  it("refuses to create a directory in a READ_ONLY project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "create_directory",
        arguments: { project: "fixture-source", path: "newdir" }
      });
      assertDenied(result, /Project is read-only/);
    });
  });

  it("refuses replace_text in a READ_ONLY project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "replace_text",
        arguments: {
          project: "fixture-source",
          path: "app.js",
          expectedSha256: "0".repeat(64),
          oldText: "value = 1",
          newText: "value = 2"
        }
      });
      assertDenied(result, /Project is read-only/);
    });
  });

  it("refuses delete_file in a READ_ONLY project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "delete_file",
        arguments: { project: "fixture-source", path: "app.js", expectedSha256: "0".repeat(64) }
      });
      assertDenied(result, /Project is read-only/);
    });
  });

  it("still allows reading a READ_ONLY project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-source", path: "README.md" }
      });
      assert.match(assertOk(result).content, /fixture source/);
    });
  });
});

describe("writable sandbox policy", () => {
  it("creates and reads back a new file", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const created = assertOk(
        await client.callTool({
          name: "create_file",
          arguments: {
            project: "fixture-sandbox",
            path: "hello.txt",
            content: "hello fixture\n"
          }
        })
      );

      assert.equal(created.created, true);
      assert.equal(created.bytes, "hello fixture\n".length);
      assert.equal(created.sha256, sha256("hello fixture\n"));
      assert.equal(
        await readFile(path.join(fixture.sandboxDir, "hello.txt"), "utf8"),
        "hello fixture\n"
      );

      const read = assertOk(
        await client.callTool({
          name: "read_file",
          arguments: { project: "fixture-sandbox", path: "hello.txt" }
        })
      );
      assert.equal(read.content, "hello fixture\n");
    });
  });

  it("creates nested directories", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      assertOk(
        await client.callTool({
          name: "create_directory",
          arguments: { project: "fixture-sandbox", path: "a/b/c" }
        })
      );
      const info = await stat(path.join(fixture.sandboxDir, "a", "b", "c"));
      assert.equal(info.isDirectory(), true);
    });
  });
});

describe("overwrite and concurrency protection", () => {
  it("blocks creating a file that already exists", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: {
          project: "fixture-sandbox",
          path: "notes.txt",
          content: "overwrite attempt"
        }
      });
      assertDenied(result, /Target file already exists/);
    });
  });

  it("blocks replace_text when the expected SHA-256 is stale", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "replace_text",
        arguments: {
          project: "fixture-sandbox",
          path: "notes.txt",
          expectedSha256: "a".repeat(64),
          oldText: "hello",
          newText: "goodbye"
        }
      });
      assertDenied(result, /SHA-256 mismatch/);
    });
  });

  it("applies replace_text when the expected SHA-256 is current", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const before = await readFile(path.join(fixture.sandboxDir, "notes.txt"), "utf8");
      const info = assertOk(
        await client.callTool({
          name: "file_info",
          arguments: { project: "fixture-sandbox", path: "notes.txt" }
        })
      );
      assert.equal(info.sha256, sha256(before));

      const replaced = assertOk(
        await client.callTool({
          name: "replace_text",
          arguments: {
            project: "fixture-sandbox",
            path: "notes.txt",
            expectedSha256: info.sha256,
            oldText: "hello",
            newText: "goodbye"
          }
        })
      );

      assert.equal(replaced.replaced, true);
      assert.equal(
        await readFile(path.join(fixture.sandboxDir, "notes.txt"), "utf8"),
        "goodbye sandbox\n"
      );
    });
  });

  it("blocks delete_file when the expected SHA-256 is stale", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "delete_file",
        arguments: {
          project: "fixture-sandbox",
          path: "notes.txt",
          expectedSha256: "b".repeat(64)
        }
      });
      assertDenied(result, /SHA-256 mismatch/);
    });
  });

  it("deletes a file only when the exact current SHA-256 is supplied", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const info = assertOk(
        await client.callTool({
          name: "file_info",
          arguments: { project: "fixture-sandbox", path: "notes.txt" }
        })
      );

      const deleted = assertOk(
        await client.callTool({
          name: "delete_file",
          arguments: {
            project: "fixture-sandbox",
            path: "notes.txt",
            expectedSha256: info.sha256
          }
        })
      );

      assert.equal(deleted.deleted, true);
      await assert.rejects(() => readFile(path.join(fixture.sandboxDir, "notes.txt")));
    });
  });
});

describe("path escape defence", () => {
  it("blocks a relative path that escapes the project root", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-sandbox", path: "../outside/outside-secret.txt" }
      });
      assertDenied(result, /Path escapes registered project root/);
    });
  });

  it("blocks an absolute path", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-sandbox", path: "/etc/hosts" }
      });
      assertDenied(result, /Absolute paths are not allowed/);
    });
  });

  it("blocks a NUL byte in the path", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-sandbox", path: "notes.txt\0" }
      });
      assertDenied(result, /NUL byte/);
    });
  });

  it("blocks reading a file through a symlink that points outside the project", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      await fixture.linkOutside("leak.txt");

      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-sandbox", path: "leak.txt" }
      });
      assertDenied(result, /Path escapes registered project root/);
    });
  });

  it("blocks writing through a symlinked directory that points outside the project", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      await fixture.linkDirOutside("linkdir");

      // The parent-escape guard fires before the symlink guard, and both deny the write.
      const result = await client.callTool({
        name: "create_file",
        arguments: {
          project: "fixture-sandbox",
          path: "linkdir/escaped.txt",
          content: "escaped"
        }
      });
      assertDenied(result, /Parent path escapes registered project root/);
    });
  });

  it("blocks writing through a symlinked directory that stays inside the project", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      await fixture.linkDirInside("aliasdir", "realdir");

      const result = await client.callTool({
        name: "create_file",
        arguments: {
          project: "fixture-sandbox",
          path: "aliasdir/via-symlink.txt",
          content: "escaped"
        }
      });
      assertDenied(result, /Writes through symlinked directories are blocked/);
    });
  });

  it("blocks replacing a file reached through a symlink", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      await writeFile(path.join(fixture.sandboxDir, "real.txt"), "real content\n");
      await symlink(
        path.join(fixture.sandboxDir, "real.txt"),
        path.join(fixture.sandboxDir, "alias.txt")
      );

      const result = await client.callTool({
        name: "replace_text",
        arguments: {
          project: "fixture-sandbox",
          path: "alias.txt",
          expectedSha256: sha256("real content\n"),
          oldText: "real",
          newText: "changed"
        }
      });
      assertDenied(result, /Writes through symlinks are blocked/);
    });
  });

  it("blocks directory creation through a symlink", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      await fixture.linkDirOutside("linkdir");

      const result = await client.callTool({
        name: "create_directory",
        arguments: { project: "fixture-sandbox", path: "linkdir/nested" }
      });
      assertDenied(result, /Directory creation through symlinks is blocked|symlink/i);
    });
  });
});

describe("sensitive path defence", () => {
  it("blocks reading .env even when it exists", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      assert.equal(await fixture.exists(".env"), true, "fixture .env must exist for this test");

      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-sandbox", path: ".env" }
      });
      assertDenied(result, /Sensitive path is blocked/);
    });
  });

  it("blocks creating .env", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: { project: "fixture-sandbox", path: ".env", content: "LEAK=1" }
      });
      assertDenied(result, /Sensitive path is blocked/);
    });
  });

  it("blocks creating a private key", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: { project: "fixture-sandbox", path: "certs/server.key", content: "x" }
      });
      assertDenied(result, /Sensitive path is blocked/);
    });
  });

  it("blocks reading .git internals", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "fixture-source", path: ".git/config" }
      });
      assertDenied(result, /Sensitive path is blocked/);
    });
  });

  it("hides .env from directory listings", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const listed = assertOk(
        await client.callTool({
          name: "list_directory",
          arguments: { project: "fixture-sandbox", path: "." }
        })
      );
      const names = listed.entries.map((entry) => entry.name);
      assert.equal(names.includes(".env"), false, `.env leaked into listing: ${names.join(", ")}`);
      assert.equal(names.includes("notes.txt"), true);
    });
  });

  it("hides .git from directory listings of a repository", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const listed = assertOk(
        await client.callTool({
          name: "list_directory",
          arguments: { project: "fixture-source", path: "." }
        })
      );
      const names = listed.entries.map((entry) => entry.name);
      assert.equal(names.includes(".git"), false, `.git leaked into listing: ${names.join(", ")}`);
    });
  });

  it("excludes sensitive matches from search_text and find_files", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const searched = assertOk(
        await client.callTool({
          name: "search_text",
          arguments: {
            project: "fixture-sandbox",
            path: ".",
            query: "PLANTED_SECRET"
          }
        })
      );
      assert.equal(searched.results.length, 0, "search_text reached into .env");

      const found = assertOk(
        await client.callTool({
          name: "find_files",
          arguments: { project: "fixture-sandbox", path: ".", nameContains: "env" }
        })
      );
      assert.equal(found.results.length, 0, "find_files reached into .env");
    });
  });
});

describe("registry integrity", () => {
  it("refuses unknown project names", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "read_file",
        arguments: { project: "does-not-exist", path: "README.md" }
      });
      assertDenied(result, /Unknown project/);
    });
  });

  it("lists registered projects with their access mode", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const listed = assertOk(await client.callTool({ name: "list_projects", arguments: {} }));
      const byName = Object.fromEntries(listed.map((entry) => [entry.name, entry.mode]));
      assert.equal(byName["fixture-source"], "READ_ONLY");
      assert.equal(byName["fixture-sandbox"], "READ_WRITE");
    });
  });

  it("never writes into the fixture source repository", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const before = await readdir(path.join(fixture.sourceDir, ".git")).catch(() => []);
      await client.callTool({
        name: "create_file",
        arguments: { project: "fixture-source", path: "should-not-exist.txt", content: "x" }
      });
      const after = await readdir(path.join(fixture.sourceDir, ".git"));
      assert.deepEqual(after, before);
      await assert.rejects(() =>
        readFile(path.join(fixture.sourceDir, "should-not-exist.txt"), "utf8")
      );
    });
  });
});

describe("write size limits", () => {
  it("blocks content larger than the safe write limit", async () => {
    await withFixtureAndRunner({}, async (client, fixture) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: {
          project: "fixture-sandbox",
          path: "big.txt",
          content: "x".repeat(500 * 1024 + 1)
        }
      });
      assertDenied(result, /exceeds safe write limit/);

      await assert.rejects(() => readFile(path.join(fixture.sandboxDir, "big.txt"), "utf8"));
    });
  });
});
