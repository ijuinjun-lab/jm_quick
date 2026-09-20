// 新方式のcallableが呼び出し側へ返す「想定内のエラー」。codeはFirebase Functionsのエラーコード
// (invalid-argument / failed-precondition / not-found / already-exists / data-loss など)。
// このファイルはFirebaseに依存しない。confirmedCallable(auth.js)がHttpsErrorへ変換する。
// messageとdetailsには個人情報(氏名・メール・自由記述)を入れない(列名・行番号・コードのみ)。
class ApiError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = "ApiError";
    this.isApiError = true;
    this.code = code;
    this.details = details === undefined ? undefined : details;
  }
}

module.exports = {ApiError};
