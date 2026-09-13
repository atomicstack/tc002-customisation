(function (root, factory) {
  const model = factory();
  if (typeof module === "object" && module.exports) module.exports = model;
  else root.TC002ScriptsModel = model;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";

  const prefix = "tc002.script-draft.v1:";

  function validName(name) {
    return typeof name === "string" && /^[a-zA-Z0-9_-][a-zA-Z0-9._-]{0,31}$/.test(name);
  }

  function byteLength(source) {
    return new TextEncoder().encode(String(source)).length;
  }

  function copy(record) {
    return record === null ? null : {
      name: record.name,
      source: record.source,
      base: record.base,
    };
  }

  function parse(raw, expectedName) {
    if (raw === null) return null;
    let record;
    try {
      record = JSON.parse(raw);
    } catch (_) {
      throw new Error("invalid stored draft");
    }
    if (!record || record.name !== expectedName || typeof record.source !== "string" ||
        !(typeof record.base === "string" || record.base === null)) {
      throw new Error("invalid stored draft");
    }
    return { name: record.name, source: record.source, base: record.base };
  }

  class Drafts {
    constructor(storage) {
      this.storage = storage || null;
      this.error = null;
      this.memory = new Map();
      this.observed = new Map();
      this.states = new Map();
    }

    key(device, name) {
      return prefix + encodeURIComponent(String(device)) + ":" + encodeURIComponent(String(name));
    }

    get(device, name) {
      const key = this.key(device, name);
      this.error = null;
      if (this.memory.has(key)) {
        const state = this.states.get(key);
        this.error = state ? state.error : null;
        return copy(this.memory.get(key));
      }
      try {
        if (!this.storage) throw new Error("storage unavailable");
        const raw = this.storage.getItem(key);
        this.observed.set(key, raw);
        return copy(parse(raw, name));
      } catch (error) {
        this.error = String(error && error.message || error).toLowerCase();
        return null;
      }
    }

    put(device, name, value) {
      const key = this.key(device, name);
      const record = { name, source: value.source, base: value.base };
      this.memory.set(key, record);
      this.error = null;
      try {
        if (!validName(name) || typeof value.source !== "string" ||
            !(typeof value.base === "string" || value.base === null)) {
          throw new Error("invalid draft");
        }
        if (!this.storage) throw new Error("storage unavailable");
        const current = this.storage.getItem(key);
        const expected = this.observed.has(key) ? this.observed.get(key) : null;
        if (current !== expected) {
          this.error = "draft conflict: another tab changed this draft";
          this.states.set(key, { durable: false, error: this.error });
          return false;
        }
        const raw = JSON.stringify(record);
        this.storage.setItem(key, raw);
        this.observed.set(key, raw);
        this.states.set(key, { durable: true, error: null });
        return true;
      } catch (error) {
        this.error = String(error && error.message || error).toLowerCase();
        this.states.set(key, { durable: false, error: this.error });
        return false;
      }
    }

    remove(device, name) {
      const key = this.key(device, name);
      this.memory.set(key, null);
      this.error = null;
      try {
        if (!this.storage) throw new Error("storage unavailable");
        const current = this.storage.getItem(key);
        const expected = this.observed.has(key) ? this.observed.get(key) : null;
        if (current !== expected) {
          this.error = "draft conflict: another tab changed this draft";
          this.states.set(key, { durable: false, error: this.error });
          return false;
        }
        this.storage.removeItem(key);
        this.observed.set(key, null);
        this.states.delete(key);
        return true;
      } catch (error) {
        this.error = String(error && error.message || error).toLowerCase();
        this.states.set(key, { durable: false, error: this.error });
        return false;
      }
    }

    list(device) {
      const devicePrefix = prefix + encodeURIComponent(String(device)) + ":";
      const records = new Map();
      this.error = null;
      try {
        if (!this.storage) throw new Error("storage unavailable");
        for (let index = 0; index < this.storage.length; index += 1) {
          const key = this.storage.key(index);
          if (!key || !key.startsWith(devicePrefix)) continue;
          try {
            const name = decodeURIComponent(key.slice(devicePrefix.length));
            const raw = this.storage.getItem(key);
            if (!this.memory.has(key)) this.observed.set(key, raw);
            const record = parse(raw, name);
            if (record) records.set(key, record);
          } catch (error) {
            if (this.error === null) this.error = String(error && error.message || error).toLowerCase();
          }
        }
      } catch (error) {
        this.error = String(error && error.message || error).toLowerCase();
      }
      for (const [key, record] of this.memory) {
        if (!key.startsWith(devicePrefix)) continue;
        if (record === null) records.delete(key);
        else records.set(key, record);
      }
      return [...records.values()].map(copy).sort((left, right) => left.name.localeCompare(right.name));
    }

    hasUnsafeDrafts(device) {
      const devicePrefix = device === undefined
        ? prefix
        : prefix + encodeURIComponent(String(device)) + ":";
      for (const [key, record] of this.memory) {
        const state = this.states.get(key);
        if (key.startsWith(devicePrefix) && record !== null && state && !state.durable) return true;
      }
      return false;
    }
  }

  class ScriptSession {
    constructor(drafts, device, name, remote, methods) {
      this.drafts = drafts;
      this.device = device;
      this.name = name;
      this.methods = methods;
      this.remote = remote;
      this.busy = false;
      this.conflict = false;
      const draft = drafts.get(device, name);
      this.source = draft ? draft.source : (remote === null ? "" : remote);
      this.base = draft ? draft.base : remote;
      this.dirty = this.source !== this.base;
      this.durable = drafts.error === null;
    }

    edit(source) {
      this.source = String(source);
      this.dirty = this.source !== this.base;
      this.conflict = false;
      this.durable = this.dirty
        ? this.drafts.put(this.device, this.name, { source: this.source, base: this.base })
        : this.drafts.remove(this.device, this.name);
      if (this.drafts.error && this.drafts.error.includes("draft conflict")) this.conflict = true;
      return this.durable;
    }

    async _save(options) {
      const overwrite = Boolean(options && options.overwrite);
      const snapshot = this.source;
      const snapshotBase = this.base;
      const latest = await this.methods.read(this.name);
      this.remote = latest;
      if (latest !== snapshot && !overwrite && latest !== snapshotBase) {
        this.conflict = true;
        throw new Error("script changed on device; reload, discard, or overwrite");
      }

      let written = false;
      let response = null;
      if (latest !== snapshot) {
        response = await this.methods.write(this.name, snapshot);
        written = true;
      }

      this.remote = snapshot;
      this.base = snapshot;
      this.conflict = false;
      this.dirty = this.source !== snapshot;
      this.durable = this.dirty
        ? this.drafts.put(this.device, this.name, { source: this.source, base: snapshot })
        : this.drafts.remove(this.device, this.name);
      if (this.drafts.error && this.drafts.error.includes("draft conflict")) this.conflict = true;
      return { written, response, source: snapshot };
    }

    async save(options = {}) {
      return this._exclusive(() => this._save(options));
    }

    async runSaved() {
      return this._exclusive(() => this.methods.run(this.name));
    }

    async saveAndRun(options = {}) {
      return this._exclusive(async () => {
        const saved = await this._save(options);
        const runResponse = await this.methods.run(this.name);
        return Object.assign({}, saved, { runResponse });
      });
    }

    discardDraft() {
      if (this.busy) throw new Error("script operation already in progress");
      this.source = this.remote === null ? "" : this.remote;
      this.base = this.remote;
      this.dirty = false;
      this.conflict = false;
      this.durable = this.drafts.remove(this.device, this.name);
      if (this.drafts.error && this.drafts.error.includes("draft conflict")) this.conflict = true;
      return this.durable;
    }

    async _exclusive(operation) {
      if (this.busy) throw new Error("script operation already in progress");
      this.busy = true;
      try {
        return await operation();
      } finally {
        this.busy = false;
      }
    }
  }

  return { Drafts, ScriptSession, byteLength, validName };
});
