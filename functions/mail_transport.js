// Cloud Run mail-api への送信トランスポート。fetchは注入できる(テストでは偽物を使い、実通信は行わない)。
//
// ■ 送信結果は3種類に分類する(二重送信を避けるため、判断できないものは unknown):
//     sent    : mail-apiが成功(200・ok=true)を返した
//     failed  : 「相手(SendGrid/mail-api)へ渡っていない」と確実に言える(mail-apiの4xx拒否、プロバイダの4xx拒否、
//               接続そのものができなかった等)。管理者は「失敗分だけ再送」できる
//     unknown : 渡ったかどうか判断できない(タイムアウト、5xx、接続断、不正な成功応答など)。自動再送しない
// ■ 送信前に capabilities() で、mail-apiが html・attachments 対応か確認する。旧版のmail-apiへQR付きメールを送ると、
//   htmlが無視されてQRのないテキストだけが送られてしまうため、未対応・確認不能なら fail-closed(送信しない)。
// ■ 宛先メールアドレスをログに出さない。

const REQUIRED_FEATURES = ["html", "attachments"];
const NEVER_CONNECTED = new Set(["ENOTFOUND", "ECONNREFUSED", "EAI_AGAIN"]);
const DEFINITE_REJECTIONS = new Set([400, 401, 403, 404, 413, 415, 422]);

function validEndpoint(endpoint) {
  if (typeof endpoint !== "string" || !/^https:\/\/[^\s/]+(\/[^\s]*)?$/.test(endpoint.trim())) throw new Error("invalid mail api endpoint");
  return endpoint.trim().replace(/\/+$/, "");
}

function createMailApiTransport({endpoint, apiKey, fetchFn = globalThis.fetch, timeoutMs = 30000}) {
  const base = validEndpoint(endpoint);
  if (typeof apiKey !== "string" || apiKey === "") throw new Error("mail api key required");
  const signal = () => AbortSignal.timeout(timeoutMs);

  return {
    // {ok:boolean, missing:[機能名]}。確認できない場合も ok:false(fail-closed)。
    async capabilities() {
      try {
        const response = await fetchFn(`${base}/health`, {method: "GET", signal: signal()});
        if (!response.ok) return {ok: false, missing: [...REQUIRED_FEATURES]};
        const body = await response.json();
        const features = Array.isArray(body && body.features) ? body.features : [];
        const missing = REQUIRED_FEATURES.filter((feature) => !features.includes(feature));
        return {ok: missing.length === 0, missing};
      } catch (error) {
        return {ok: false, missing: [...REQUIRED_FEATURES]};
      }
    },

    // message: {to, senderName, subject, text, html, attachments, metadata}
    // 戻り値: {outcome: 'sent'|'failed'|'unknown', messageId?, errorCode?}(例外は投げない)
    async send(message) {
      let response;
      try {
        response = await fetchFn(`${base}/v1/mail/send`, {
          method: "POST",
          headers: {"Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json"},
          body: JSON.stringify(message),
          signal: signal(),
        });
      } catch (error) {
        if (error && (error.name === "TimeoutError" || error.name === "AbortError")) return {outcome: "unknown", errorCode: "timeout"};
        const code = error && error.cause && error.cause.code;
        if (NEVER_CONNECTED.has(code)) return {outcome: "failed", errorCode: "network-unreachable"};
        return {outcome: "unknown", errorCode: "network-error"};
      }
      let body = null;
      try { body = await response.json(); } catch (error) { body = null; }
      if (response.status === 200) {
        return body && body.ok === true && typeof body.messageId === "string"
          ? {outcome: "sent", messageId: body.messageId}
          : {outcome: "unknown", errorCode: "invalid-success-response"};
      }
      if (DEFINITE_REJECTIONS.has(response.status)) return {outcome: "failed", errorCode: `mail-api-${response.status}`};
      if (response.status === 502 && body && Number.isInteger(body.providerStatus) && body.providerStatus >= 400 && body.providerStatus < 500) {
        return {outcome: "failed", errorCode: `provider-${body.providerStatus}`};
      }
      return {outcome: "unknown", errorCode: `mail-api-${response.status}`};
    },
  };
}

module.exports = {REQUIRED_FEATURES, createMailApiTransport};
