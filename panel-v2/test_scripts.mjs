import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const { Drafts, ScriptSession, byteLength, validName } = require("./scripts-model.js");

class Storage {
  constructor() {
    this.values = new Map();
    this.failGet = false;
    this.failSet = false;
    this.failRemove = false;
  }

  get length() {
    if (this.failGet) throw new Error("storage unavailable");
    return this.values.size;
  }
  key(index) { return [...this.values.keys()][index] ?? null; }
  getItem(key) {
    if (this.failGet) throw new Error("storage unavailable");
    return this.values.get(key) ?? null;
  }
  setItem(key, value) {
    if (this.failSet) throw new Error("quota exceeded");
    this.values.set(key, String(value));
  }
  removeItem(key) {
    if (this.failRemove) throw new Error("storage unavailable");
    this.values.delete(key);
  }
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function api(remote = null) {
  const calls = { read: 0, write: [], run: [], remove: [] };
  return {
    calls,
    setRemote(value) { remote = value; },
    methods: {
      async read() { calls.read += 1; return remote; },
      async write(name, source) {
        calls.write.push([name, source]);
        remote = source;
        return { status: "ok", compiled: true };
      },
      async run(name) { calls.run.push(name); return { status: "ok" }; },
      async remove(name) { calls.remove.push(name); remote = null; },
    },
  };
}

test("validates device script names and utf-8 byte length", () => {
  assert.equal(validName("autoexec"), true);
  assert.equal(validName("clock.v2-test_1"), true);
  assert.equal(validName(".hidden"), false);
  assert.equal(validName("with space"), false);
  assert.equal(validName("a".repeat(33)), false);
  assert.equal(byteLength("aé🙂"), 7);
});

test("recovers persisted case-sensitive source after reload", () => {
  const storage = new Storage();
  const first = new Drafts(storage);
  assert.equal(first.put("clock.local", "autoexec", { source: "Print('MiXeD')", base: "print('old')" }), true);

  const reloaded = new Drafts(storage);
  assert.deepEqual(reloaded.get("clock.local", "autoexec"), {
    name: "autoexec",
    source: "Print('MiXeD')",
    base: "print('old')",
  });
});

test("lists only the requested device drafts", () => {
  const storage = new Storage();
  const drafts = new Drafts(storage);
  drafts.put("one", "beta", { source: "b", base: null });
  drafts.put("one", "alpha", { source: "a", base: "old" });
  drafts.put("two", "alpha", { source: "other", base: null });

  assert.deepEqual(drafts.list("one"), [
    { name: "alpha", source: "a", base: "old" },
    { name: "beta", source: "b", base: null },
  ]);
});

test("uses memory when storage is unavailable or full", () => {
  const storage = new Storage();
  storage.failSet = true;
  const drafts = new Drafts(storage);

  assert.equal(drafts.put("one", "autoexec", { source: "print('safe')", base: null }), false);
  assert.match(drafts.error, /quota exceeded/);
  assert.deepEqual(drafts.get("one", "autoexec"), { name: "autoexec", source: "print('safe')", base: null });

  storage.failGet = true;
  assert.deepEqual(drafts.list("one"), [{ name: "autoexec", source: "print('safe')", base: null }]);
  assert.match(drafts.error, /storage unavailable/);
});

test("a stale tab cannot silently overwrite another tab draft", () => {
  const storage = new Storage();
  const first = new Drafts(storage);
  const second = new Drafts(storage);
  assert.equal(first.get("one", "autoexec"), null);
  assert.equal(second.get("one", "autoexec"), null);

  assert.equal(first.put("one", "autoexec", { source: "first", base: "device" }), true);
  assert.equal(second.put("one", "autoexec", { source: "second", base: "device" }), false);
  assert.match(second.error, /draft conflict/);
  assert.equal(second.get("one", "autoexec").source, "second");
  assert.equal(new Drafts(storage).get("one", "autoexec").source, "first");
});

test("listing does not let a conflicted tab overwrite the winning draft", () => {
  const storage = new Storage();
  const first = new Drafts(storage);
  const second = new Drafts(storage);
  first.get("one", "autoexec");
  second.get("one", "autoexec");
  first.put("one", "autoexec", { source: "winner", base: "device" });
  assert.equal(second.put("one", "autoexec", { source: "stale", base: "device" }), false);

  assert.equal(second.list("one")[0].source, "stale");
  assert.equal(second.put("one", "autoexec", { source: "stale again", base: "device" }), false);
  assert.match(second.error, /draft conflict/);
  assert.equal(new Drafts(storage).get("one", "autoexec").source, "winner");
});

test("listing skips corrupt records without hiding later valid drafts", () => {
  const storage = new Storage();
  const drafts = new Drafts(storage);
  storage.setItem(drafts.key("one", "broken"), "{not json");
  storage.setItem(drafts.key("one", "valid"), JSON.stringify({ name: "valid", source: "safe", base: null }));

  assert.deepEqual(drafts.list("one"), [{ name: "valid", source: "safe", base: null }]);
  assert.match(drafts.error, /json|stored draft/);
});

test("loads a draft before the device source", () => {
  const storage = new Storage();
  const drafts = new Drafts(storage);
  drafts.put("one", "autoexec", { source: "edited", base: "device" });
  const session = new ScriptSession(drafts, "one", "autoexec", "new device", api().methods);

  assert.equal(session.source, "edited");
  assert.equal(session.base, "device");
  assert.equal(session.remote, "new device");
  assert.equal(session.dirty, true);
  assert.equal(session.durable, true);
});

test("reports an unreadable draft store as not durable", () => {
  const storage = new Storage();
  storage.failGet = true;
  const session = new ScriptSession(new Drafts(storage), "one", "autoexec", "device", api().methods);

  assert.equal(session.source, "device");
  assert.equal(session.durable, false);
});

test("keeps failed draft durability across script sessions and exposes an unload guard", () => {
  const storage = new Storage();
  storage.failSet = true;
  const drafts = new Drafts(storage);
  assert.equal(drafts.put("one", "alpha", { source: "unsafe", base: "device" }), false);
  assert.equal(drafts.hasUnsafeDrafts(), true);
  assert.equal(drafts.hasUnsafeDrafts("one"), true);
  assert.equal(drafts.hasUnsafeDrafts("two"), false);

  drafts.get("two", "beta");
  const reopened = new ScriptSession(drafts, "one", "alpha", "device", api().methods);
  assert.equal(reopened.source, "unsafe");
  assert.equal(reopened.durable, false);
  assert.match(drafts.error, /quota exceeded/);

  storage.failSet = false;
  assert.equal(drafts.put("one", "alpha", { source: "unsafe", base: "device" }), true);
  assert.equal(drafts.hasUnsafeDrafts(), false);
});

test("an untouched save rereads but performs no flash write", async () => {
  const remote = api("same");
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "same", remote.methods);

  assert.deepEqual(await session.save(), { written: false, response: null, source: "same" });
  assert.equal(remote.calls.read, 1);
  assert.deepEqual(remote.calls.write, []);
  assert.equal(session.dirty, false);
});

test("a failed save keeps the local draft and original rejection", async () => {
  const storage = new Storage();
  const drafts = new Drafts(storage);
  const compileError = Object.assign(new Error("unexpected token"), { body: { code: "script_will_not_compile" } });
  const methods = {
    async read() { return "old"; },
    async write() { throw compileError; },
    async run() { assert.fail("run must not be called"); },
  };
  const session = new ScriptSession(drafts, "one", "autoexec", "old", methods);
  session.edit("broken(");

  await assert.rejects(session.save(), (error) => error === compileError);
  assert.equal(drafts.get("one", "autoexec").source, "broken(");
  assert.equal(session.dirty, true);
  assert.equal(session.busy, false);
});

test("detects changed and deleted device sources as conflicts", async (t) => {
  await t.test("changed", async () => {
    const remote = api("old");
    const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", remote.methods);
    session.edit("mine");
    remote.setRemote("theirs");
    await assert.rejects(session.save(), /script changed on device/);
    assert.equal(session.remote, "theirs");
    assert.equal(session.conflict, true);
    assert.deepEqual(remote.calls.write, []);
  });

  await t.test("deleted", async () => {
    const remote = api("old");
    const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", remote.methods);
    session.edit("mine");
    remote.setRemote(null);
    await assert.rejects(session.save(), /script changed on device/);
    assert.equal(session.remote, null);
    assert.equal(session.conflict, true);
  });
});

test("overwrite resolves a device conflict", async () => {
  const remote = api("old");
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", remote.methods);
  session.edit("mine");
  remote.setRemote("theirs");

  const result = await session.save({ overwrite: true });
  assert.equal(result.written, true);
  assert.deepEqual(remote.calls.write, [["autoexec", "mine"]]);
  assert.equal(session.remote, "mine");
  assert.equal(session.dirty, false);
  assert.equal(session.conflict, false);
});

test("a lost save response retry skips the write when device already has the source", async () => {
  const remote = api("old");
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", remote.methods);
  session.edit("saved despite lost response");
  remote.setRemote("saved despite lost response");

  assert.deepEqual(await session.save(), {
    written: false,
    response: null,
    source: "saved despite lost response",
  });
  assert.deepEqual(remote.calls.write, []);
  assert.equal(session.base, "saved despite lost response");
  assert.equal(session.dirty, false);
  assert.equal(session.conflict, false);
});

test("an edit during save remains dirty against the saved snapshot", async () => {
  const gate = deferred();
  const storage = new Storage();
  const drafts = new Drafts(storage);
  const methods = {
    async read() { return "old"; },
    async write(name, source) { await gate.promise; return { status: "ok", name, source }; },
    async run() {},
  };
  const session = new ScriptSession(drafts, "one", "autoexec", "old", methods);
  session.edit("snapshot");
  const saving = session.save();
  await Promise.resolve();
  session.edit("later edit");
  gate.resolve();
  assert.equal((await saving).source, "snapshot");

  assert.equal(session.base, "snapshot");
  assert.equal(session.remote, "snapshot");
  assert.equal(session.source, "later edit");
  assert.equal(session.dirty, true);
  assert.equal(drafts.get("one", "autoexec").source, "later edit");
});

test("save and run does not run after save failure", async () => {
  let runs = 0;
  const methods = {
    async read() { return "old"; },
    async write() { throw new Error("compile failed"); },
    async run() { runs += 1; },
  };
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", methods);
  session.edit("broken");

  await assert.rejects(session.saveAndRun(), /compile failed/);
  assert.equal(runs, 0);
});

test("save and run runs after the saved snapshot while preserving later edits", async () => {
  const gate = deferred();
  const events = [];
  const methods = {
    async read() { return "old"; },
    async write(name, source) { events.push(["write", name, source]); await gate.promise; return { status: "ok" }; },
    async run(name) { events.push(["run", name]); return { ran: true }; },
  };
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", methods);
  session.edit("snapshot");
  const operation = session.saveAndRun();
  await Promise.resolve();
  session.edit("later");
  gate.resolve();

  assert.deepEqual(await operation, { written: true, response: { status: "ok" }, source: "snapshot", runResponse: { ran: true } });
  assert.deepEqual(events, [["write", "autoexec", "snapshot"], ["run", "autoexec"]]);
  assert.equal(session.source, "later");
  assert.equal(session.dirty, true);
});

test("run saved never writes", async () => {
  const remote = api("old");
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", remote.methods);
  session.edit("unsaved");

  assert.deepEqual(await session.runSaved(), { status: "ok" });
  assert.deepEqual(remote.calls.write, []);
  assert.deepEqual(remote.calls.run, ["autoexec"]);
});

test("discard removes the draft and resets to the latest remote", async () => {
  const storage = new Storage();
  const drafts = new Drafts(storage);
  const remote = api("old");
  const session = new ScriptSession(drafts, "one", "autoexec", "old", remote.methods);
  session.edit("mine");
  remote.setRemote("latest");
  await assert.rejects(session.save(), /script changed on device/);

  session.discardDraft();
  assert.equal(session.source, "latest");
  assert.equal(session.base, "latest");
  assert.equal(session.dirty, false);
  assert.equal(drafts.get("one", "autoexec"), null);
});

test("discarding a tab-conflicted draft does not remove the other tab draft", () => {
  const storage = new Storage();
  const first = new Drafts(storage);
  const second = new Drafts(storage);
  first.get("one", "autoexec");
  const session = new ScriptSession(second, "one", "autoexec", "device", api().methods);
  first.put("one", "autoexec", { source: "first", base: "device" });
  session.edit("second");

  assert.equal(session.discardDraft(), false);
  assert.equal(session.conflict, true);
  assert.equal(session.source, "device");
  assert.equal(new Drafts(storage).get("one", "autoexec").source, "first");
});

test("rejects concurrent operations", async () => {
  const gate = deferred();
  const methods = {
    async read() { await gate.promise; return "old"; },
    async write() { assert.fail("unchanged source must not write"); },
    async run() {},
  };
  const session = new ScriptSession(new Drafts(new Storage()), "one", "autoexec", "old", methods);
  const saving = session.save();

  await assert.rejects(session.runSaved(), /script operation already in progress/);
  await assert.rejects(session.save(), /script operation already in progress/);
  gate.resolve();
  await saving;
});
