// テスト専用のメモリ上Firestore。実Firestoreへは一切接続しない。
// functions/index.js が使う範囲(collection/doc/get/update/set/create/add、where(==)、
// runTransaction、bulkWriter、サブコレクション)だけを最小限に再現する。

const SERVER_TIMESTAMP = {__sentinel: "serverTimestamp"};

const FieldValue = {
  serverTimestamp: () => SERVER_TIMESTAMP,
  increment: (n) => ({__sentinel: "increment", n}),
};

function ts(date) {
  return {toDate: () => date, __ts: date.toISOString()};
}

function applyValue(current, value) {
  if (value && value.__sentinel === "increment") return (current || 0) + value.n;
  return value;
}

class DocSnapshot {
  constructor(db, path, data) {
    this.db = db;
    this.ref = new DocRef(db, path);
    this.id = this.ref.id;
    this.exists = data !== undefined;
    this._data = data;
  }
  data() { return this._data === undefined ? undefined : {...this._data}; }
}

class DocRef {
  constructor(db, path) {
    this.db = db;
    this.path = path;
    this.id = path.split("/").pop();
  }
  collection(name) { return new Query(this.db, `${this.path}/${name}`); }
  async get() { return new DocSnapshot(this.db, this.path, this.db.store.get(this.path)); }
  async update(data) { this.db._write("update", this.path, data); }
  async set(data) { this.db._write("set", this.path, data); }
  async create(data) { this.db._write("create", this.path, data); }
  async delete() { this.db._write("delete", this.path); }
}

class Query {
  constructor(db, collectionPath, filters = [], max = Infinity) {
    this.db = db;
    this.collectionPath = collectionPath;
    this.filters = filters;
    this.max = max;
  }
  doc(id) {
    return new DocRef(this.db, `${this.collectionPath}/${id || this.db._autoId()}`);
  }
  async add(data) {
    const ref = this.doc();
    this.db._write("create", ref.path, data);
    return ref;
  }
  where(field, op, value) {
    if (op !== "==") throw new Error(`fake firestore: unsupported operator ${op}`);
    return new Query(this.db, this.collectionPath, [...this.filters, {field, value}], this.max);
  }
  limit(n) { return new Query(this.db, this.collectionPath, this.filters, n); }
  async get() {
    const prefix = `${this.collectionPath}/`;
    const docs = [];
    for (const [path, data] of this.db.store) {
      if (!path.startsWith(prefix) || path.slice(prefix.length).includes("/")) continue;
      if (this.filters.every(({field, value}) => data[field] === value)) {
        docs.push(new DocSnapshot(this.db, path, data));
      }
      if (docs.length >= this.max) break;
    }
    return {docs, empty: docs.length === 0, size: docs.length};
  }
}

class FakeFirestore {
  // seed: {"events/e1": {...}, ...}
  constructor(seed = {}) {
    this.store = new Map(Object.entries(seed).map(([k, v]) => [k, {...v}]));
    this.writes = [];
    this._id = 0;
  }
  _autoId() { return `auto${++this._id}`; }
  collection(name) { return new Query(this, name); }
  doc(path) { return new DocRef(this, path); }
  _write(op, path, data) {
    this.writes.push({op, path, data});
    if (op === "delete") { this.store.delete(path); return; }
    const existing = this.store.get(path);
    if (op === "create" && existing !== undefined) throw new Error(`already exists: ${path}`);
    if (op === "update" && existing === undefined) throw new Error(`not found: ${path}`);
    const next = op === "set" || op === "create" ? {} : {...existing};
    for (const [key, value] of Object.entries(data)) next[key] = applyValue(next[key], value);
    this.store.set(path, next);
  }
  async runTransaction(fn) {
    const tx = {
      get: (ref) => ref.get(),
      update: (ref, data) => this._write("update", ref.path, data),
      set: (ref, data) => this._write("set", ref.path, data),
      create: (ref, data) => this._write("create", ref.path, data),
    };
    return fn(tx);
  }
  bulkWriter() {
    return {
      set: (ref, data) => this._write("set", ref.path, data),
      update: (ref, data) => this._write("update", ref.path, data),
      delete: (ref) => this._write("delete", ref.path),
      close: async () => {},
    };
  }
  writesTo(pathPrefix) { return this.writes.filter((w) => w.path.startsWith(pathPrefix)); }
}

module.exports = {FakeFirestore, FieldValue, SERVER_TIMESTAMP, ts};
