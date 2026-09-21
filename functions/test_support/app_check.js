// テスト専用: App Check検証済みのリクエストに相当する request.app。実際のApp Checkサービスには接続しない
// (本番ではランタイムが X-Firebase-AppCheck を検証し、有効なときだけ request.app を設定する)。
const TEST_APP = Object.freeze({appId: "1:000000000000:web:0000000000000000000000", token: Object.freeze({})});
let ipCounter = 0;
const nextIp = () => `198.51.100.${(ipCounter = (ipCounter % 250) + 1)}`;
const publicRequest = (request = {}) => ({...request, app: TEST_APP, rawRequest: {headers: {"x-forwarded-for": nextIp()}}});
module.exports = {TEST_APP, nextIp, publicRequest};
