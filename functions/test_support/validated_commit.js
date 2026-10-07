// テスト用: 管理画面と同じく、commitの前に検証(validateConfirmedImport)を行い、検証が返した
// expectedImportSequence・validationFingerprint を付けてからcommitする。
// - 重複の許可(acknowledge*)・reviewの許可(approvedReviewRows)は付けない(必要なテストが明示する)。
// - 許可の鍵(approvalKeys)は、テストが指定しなければ検証が返した現在の鍵をすべて付ける(画面が許可した警告の鍵を送るのと同じ。
//   どの警告を許可するかは、従来どおり approvedReviewRows・acknowledge* が決める)。古い鍵を送るテストは自分で指定する。
// - 番号・指紋をテストが自分で指定した場合や、検証自体が拒否される入力(権限なし・不正なリクエスト等)は、そのままcommitへ渡す
//   (commit側の拒否をそのまま確認できるように)。
// 検証(validate)へは送らない、commitだけの項目(許可・番号・指紋)。修正(corrections)・除外(excludedRows)は検証にも送る。
const COMMIT_ONLY_KEYS = ["approvedReviewRows", "acknowledgeExistingEmailDuplicates", "acknowledgeCsvEmailDuplicates",
  "acknowledgeIgnoredCounts", "approvalKeys", "expectedImportSequence", "validationFingerprint"];

// 検証の応答から、許可の鍵をすべて取り出す。
const approvalKeysOf = (v) => (v.rows || []).flatMap((r) => Object.values(r.approvalKeys || {}));

async function validatedData(validate, req) {
  const data = req.data;
  if (data === null || typeof data !== "object" || "expectedImportSequence" in data || "validationFingerprint" in data) return data;
  const base = Object.fromEntries(Object.entries(data).filter(([key]) => !COMMIT_ONLY_KEYS.includes(key)));
  try {
    const v = await validate({...req, data: base});
    return {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      ...("approvalKeys" in data ? {} : {approvalKeys: approvalKeysOf(v)})};
  } catch (error) {
    return data;
  }
}

// validate・commit: 同じ形の呼び出し({identity|auth, data})を受けるハンドラ/callableのrun。
const validatingCommit = (validate, commit) => async (req) => commit({...req, data: await validatedData(validate, req)});

// createImportApi の結果のcommitを、検証してからcommitするハンドラに置き換える。
const withValidatedCommit = (api) => ({...api, commit: validatingCommit(api.validate, api.commit)});

// index.js のcallable(commitConfirmedImport)を、検証(validateConfirmedImport)してから呼ぶ。
const validatedCommitRun = (index) => validatingCommit((r) => index.validateConfirmedImport.run(r), (r) => index.commitConfirmedImport.run(r));

module.exports = {approvalKeysOf, validatedData, validatingCommit, withValidatedCommit, validatedCommitRun};
