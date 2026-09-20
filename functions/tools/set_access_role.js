#!/usr/bin/env node
// 最初のadmin・スタッフの権限(accessRoles/{uid})を、Admin SDKで安全に設定するためのCLI。
//
//   node functions/tools/set_access_role.js --project <projectId> --uid <FirebaseAuthのUID> \
//        --role admin|staff --active true|false            # dry-run(既定。何も書かない・どこにも接続しない)
//   ... --apply --confirm-project <projectId>               # 実際に書き込む
//
// 安全策:
//   - --project / --uid / --role / --active はすべて必須(暗黙の既定プロジェクトを使わない)
//   - dry-runが既定。--apply と、--project と同じ値の --confirm-project の両方が無ければ書き込まない
//   - dry-runはFirebase Admin SDKを読み込まず、ネットワークにも接続しない
//   - 対象を必ず表示する(実Firestoreか、FIRESTORE_EMULATOR_HOSTのエミュレータか)
//   - UIDを明示する方式のみ。メールアドレスから利用者を探して変更する機能は無い
//   - --apply時は、UIDがFirebase Authに実在することを確認し、メールアドレス(参考情報)はAuthから取得する
//   - 最後の有効なadminを、adminでない/無効な状態へ変更する操作は、--allow-remove-last-admin が無い限り拒否する
//   - 認証情報はApplication Default Credentialsを使う(鍵ファイルは扱わない)
//   - accessRoles/{uid} はクライアントSDKから書けない(Rulesで全拒否)。書けるのはAdmin SDKだけ。

const {UID_PATTERN} = require("../auth");

const PROJECT_PATTERN = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const ROLES = ["admin", "staff"];
const VALUE_FLAGS = ["project", "uid", "role", "active", "confirm-project", "display-name"];
const BOOLEAN_FLAGS = ["apply", "allow-remove-last-admin", "help"];

function parseArgs(argv) {
  const options = {};
  const errors = [];
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) { errors.push(`予期しない引数: ${token}`); continue; }
    const [rawName, inline] = token.slice(2).split(/=(.*)/s);
    if (BOOLEAN_FLAGS.includes(rawName)) {
      if (inline !== undefined) errors.push(`--${rawName} は値を取りません`);
      else if (rawName in options) errors.push(`--${rawName} が重複しています`);
      else options[rawName] = true;
    } else if (VALUE_FLAGS.includes(rawName)) {
      const value = inline !== undefined ? inline : argv[++i];
      if (value === undefined || value.startsWith("--")) errors.push(`--${rawName} に値がありません`);
      else if (rawName in options) errors.push(`--${rawName} が重複しています`);
      else options[rawName] = value;
    } else {
      errors.push(`未知のオプション: --${rawName}`);
    }
  }
  return {options, errors};
}

// 入力を検証し、実行計画を返す。{ok:true, plan} | {ok:false, errors}
function buildPlan(options, env = {}) {
  const errors = [];
  if (!options.project) errors.push("--project は必須です(暗黙の既定プロジェクトは使いません)");
  else if (!PROJECT_PATTERN.test(options.project)) errors.push("--project の形式が不正です");
  if (!options.uid) errors.push("--uid は必須です(メールアドレスからの検索はできません)");
  else if (!UID_PATTERN.test(options.uid)) errors.push("--uid の形式が不正です");
  if (!ROLES.includes(options.role)) errors.push(`--role は ${ROLES.join(" または ")} を指定してください`);
  if (options.active !== "true" && options.active !== "false") errors.push("--active は true または false を指定してください");
  if (options["display-name"] !== undefined &&
      (options["display-name"].trim() === "" || options["display-name"].length > 100)) {
    errors.push("--display-name は1〜100文字で指定してください");
  }
  const apply = options.apply === true;
  if (apply && options["confirm-project"] !== options.project) {
    errors.push("--apply には、--project と同じ値の --confirm-project が必要です");
  }
  if (!apply && options["confirm-project"] !== undefined && options["confirm-project"] !== options.project) {
    errors.push("--confirm-project が --project と一致しません");
  }
  if (errors.length > 0) return {ok: false, errors};
  const emulatorHost = env.FIRESTORE_EMULATOR_HOST || null;
  return {
    ok: true,
    plan: {
      project: options.project,
      uid: options.uid,
      role: options.role,
      active: options.active === "true",
      displayName: options["display-name"] === undefined ? null : options["display-name"].trim(),
      apply,
      allowRemoveLastAdmin: options["allow-remove-last-admin"] === true,
      emulatorHost,
      target: emulatorHost ? `Firestore Emulator (${emulatorHost})` : `実Firestore(プロジェクト ${options.project})`,
    },
  };
}

const usage = () => [
  "使い方: node functions/tools/set_access_role.js --project <id> --uid <uid> --role admin|staff --active true|false",
  "        [--display-name <名前>] [--apply --confirm-project <id>] [--allow-remove-last-admin]",
  "既定はdry-run(何も書き込まず、どこにも接続しません)。",
].join("\n");

// 実際のFirebase Admin SDKへ接続するバックエンド。--apply のときだけ生成する。
function createAdminBackend(plan, loadAdmin = () => require("firebase-admin")) {
  const admin = loadAdmin();
  admin.initializeApp({projectId: plan.project});
  const db = admin.firestore();
  const ref = () => db.collection("accessRoles").doc(plan.uid);
  return {
    async getAuthUser() {
      try {
        const user = await admin.auth().getUser(plan.uid);
        return {exists: true, email: user.email || null};
      } catch (error) {
        if (error && error.code === "auth/user-not-found") return {exists: false, email: null};
        throw error;
      }
    },
    async getAccessRole() {
      const snapshot = await ref().get();
      return snapshot.exists ? snapshot.data() : null;
    },
    async countOtherActiveAdmins() {
      const result = await db.collection("accessRoles").where("role", "==", "admin").where("active", "==", true).get();
      return result.docs.filter((doc) => doc.id !== plan.uid).length;
    },
    async writeAccessRole(data, isNew) {
      const FieldValue = admin.firestore.FieldValue;
      const now = FieldValue.serverTimestamp();
      if (isNew) await ref().create({...data, createdAt: now, updatedAt: now});
      else await ref().update({...data, updatedAt: now});
    },
  };
}

async function run({argv, env = {}, out = console.log, createBackend = createAdminBackend}) {
  const {options, errors: parseErrors} = parseArgs(argv);
  if (options.help) { out(usage()); return 0; }
  const built = parseErrors.length > 0 ? {ok: false, errors: parseErrors} : buildPlan(options, env);
  if (!built.ok) {
    built.errors.forEach((message) => out(`エラー: ${message}`));
    out(usage());
    return 2;
  }
  const {plan} = built;
  out(`モード: ${plan.apply ? "APPLY(書き込みます)" : "DRY-RUN(何も書き込みません)"}`);
  out(`対象プロジェクトID: ${plan.project}`);
  out(`書き込み先: ${plan.target}`);
  out(`対象UID: ${plan.uid}`);
  out(`設定内容: role=${plan.role} active=${plan.active}${plan.displayName ? ` displayName=${plan.displayName}` : ""}`);

  if (!plan.apply) {
    out(`accessRoles/${plan.uid} に上記を設定します(新規は createdAt、常に updatedAt を記録。email はApply時にFirebase Authから取得)。`);
    out("dry-runのため、Firebaseへは接続しておらず、何も変更していません。");
    out(`実行するには: --apply --confirm-project ${plan.project} を付けてください。`);
    return 0;
  }

  if (!plan.emulatorHost) out("警告: 実Firestoreへ書き込みます。プロジェクトIDを確認してください。");
  const backend = createBackend(plan);
  const authUser = await backend.getAuthUser();
  if (!authUser.exists) {
    out("エラー: このUIDはFirebase Authenticationに存在しません。書き込みを中止しました。");
    return 1;
  }
  const before = await backend.getAccessRole();
  out(`現在の設定: ${before ? `role=${before.role} active=${before.active}` : "(なし・新規作成)"}`);
  const removesAdmin = before && before.role === "admin" && before.active === true &&
    !(plan.role === "admin" && plan.active === true);
  if (removesAdmin && !plan.allowRemoveLastAdmin && (await backend.countOtherActiveAdmins()) === 0) {
    out("エラー: これは最後の有効なadminです。変更すると管理者がいなくなるため中止しました" +
      "(意図する場合は --allow-remove-last-admin を付けてください)。");
    return 1;
  }
  const data = {role: plan.role, active: plan.active, email: authUser.email, ...(plan.displayName ? {displayName: plan.displayName} : {})};
  await backend.writeAccessRole(data, before === null);
  out(`完了: accessRoles/${plan.uid} を${before ? "更新" : "作成"}しました(role=${plan.role} active=${plan.active})。`);
  return 0;
}

if (require.main === module) {
  run({argv: process.argv.slice(2), env: process.env}).then(
    (code) => { process.exitCode = code; },
    (error) => { console.error("失敗:", error && error.message ? error.message : error); process.exitCode = 1; },
  );
}

module.exports = {parseArgs, buildPlan, run, createAdminBackend, PROJECT_PATTERN};
