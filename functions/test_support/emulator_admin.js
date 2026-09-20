// ローカルのFirestore Emulatorに、実際のFirebase Admin SDKを接続するテスト基盤。
// 実Firestoreへは接続しない(FIRESTORE_EMULATOR_HOST=127.0.0.1のみ)。transactionや並行実行を本物のFirestoreの挙動で検証できる。
const {skipReason, startEmulator, PROJECT} = require("./rules_harness");

let appCounter = 0;

async function startAdminEmulator() {
  const emu = await startEmulator();
  process.env.FIRESTORE_EMULATOR_HOST = new URL(emu.origin).host;
  const {initializeApp} = require("firebase-admin/app");
  const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
  appCounter += 1;
  const app = initializeApp({projectId: PROJECT}, `phase5-test-${process.pid}-${appCounter}`);
  const db = getFirestore(app);
  return {
    db, FieldValue, Timestamp, origin: emu.origin, emu,
    // 全データを消す(テスト間の独立性のため)。
    async clear() {
      const response = await fetch(`${emu.origin}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {method: "DELETE"});
      if (response.status !== 200) throw new Error(`clear failed: ${response.status}`);
    },
    stop: () => emu.stop(),
  };
}

// 指定回数目のrunTransactionで例外を投げるdbを返す(途中失敗の再現)。それ以外は本物のdbへそのまま委譲する。
function failingDb(db, {failAtTransaction}) {
  let count = 0;
  return new Proxy(db, {
    get(target, prop) {
      if (prop === "runTransaction") {
        return async (fn, options) => {
          count += 1;
          if (count === failAtTransaction) throw new Error("injected failure");
          return target.runTransaction(fn, options);
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

// participantsの件数確認(count集計)だけを偽の値にするdb。保存則の検証が、実際に不整合を検出して失敗することの確認用。
function dbWithWrongParticipantCount(db, wrongCount) {
  const bind = (target, prop) => {
    const value = Reflect.get(target, prop, target);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return new Proxy(db, {
    get(target, prop) {
      if (prop !== "collection") return bind(target, prop);
      return (name) => {
        const collection = target.collection(name);
        if (name !== "participants") return collection;
        return new Proxy(collection, {
          get(ct, p) {
            if (p !== "where") return bind(ct, p);
            return (...args) => new Proxy(ct.where(...args), {
              get(qt, qp) {
                if (qp === "count") return () => ({get: async () => ({data: () => ({count: wrongCount})})});
                return bind(qt, qp);
              },
            });
          },
        });
      };
    },
  });
}

module.exports = {skipReason, startAdminEmulator, failingDb, dbWithWrongParticipantCount};
