// No participant reads. Only allowlisted structural evidence crosses this boundary.
const {createHash} = require('node:crypto');
const {readFileSync} = require('node:fs');
const {renderWinnerMail, renderBroadcastMail, escapeHtml} = require('./mail_render');
const RENDERER_VERSION = createHash('sha256').update(['mail_render', 'mail_view_model', 'participation_types', 'pass_urls']
  .map(name => readFileSync(require.resolve(`./${name}`))).join('\n')).digest('hex');
const NOTICE = '個別参加者の情報は確認用サンプルです。QR・Web参加証は受付に利用できません。';
const SENTINEL = 'JM_QUICK_CONFIRMATION_ONLY_NOT_A_RECEPTION_QR';
const LABELS = {normal: '通常当選メール', waitlistPromotion: '繰り上げ当選メール', broadcast: '一斉メール'};
function evidenceFor(rendered) {
  const vm = rendered?.viewModel;
  if (!vm || !Array.isArray(vm.programs) || !vm.programs.length || vm.programs.some(p => typeof p.programId !== 'string' || !p.programId)) return null;
  return {rendererVersion: RENDERER_VERSION, programIds: vm.programs.map(p => p.programId),
    hasRegisteredAt: Boolean(vm.sourceRegisteredAtText)};
}
const ms = v => v?.toMillis?.() ?? (v instanceof Date ? v.getTime() : typeof v === 'string' ? Date.parse(v) : 0);
const dateText = v => ms(v) ? new Intl.DateTimeFormat('ja-JP', {timeZone: 'Asia/Tokyo', dateStyle: 'medium', timeStyle: 'medium'}).format(new Date(ms(v))) + ' JST' : '記録なし';
async function renderConfirmation({job, kind, evidence, generateQrPng}) {
  if (evidence?.rendererVersion !== RENDERER_VERSION) throw new Error('renderer-version-unavailable');
  const snapshot = job.snapshot;
  if (!snapshot?.programs || !evidence.programIds?.length || evidence.programIds.some(id => !snapshot.programs.some(p => p.programId === id))) throw new Error('sample-unavailable');
  const participantId = 'confirmation-sample';
  const participant = {participantId, name: '配信確認用サンプル', publicId: 'pub_confirmation_sample_not_valid_0000',
    ...(evidence.hasRegisteredAt ? {sourceRegisteredAt: '2000-01-01T00:00:00+09:00'} : {})};
  const sample = await (kind === 'broadcast' ? renderBroadcastMail : renderWinnerMail)({snapshot, participant,
    attendances: evidence.programIds.map(programId => ({eventId: snapshot.event.eventId, participantId, programId,
      plannedCount: 1, slotLabel: '確認用サンプル時間（予約ではありません）'})),
    appBaseUrl: 'https://confirmation.invalid', generateQrPng: () => generateQrPng(SENTINEL)});
  if (!sample.ok) throw new Error('sample-render-failed');
  // Replace only the known synthetic URL, never arbitrary real participant HTML.
  const safeHtml = sample.html.split(`href="${escapeHtml(sample.webPassUrl)}"`).join('aria-disabled="true"')
    .split(escapeHtml(sample.webPassUrl)).join('確認用サンプル（Web参加証は利用できません）');
  const safeText = sample.text.split(sample.webPassUrl).join('確認用サンプル（Web参加証は利用できません）');
  const rows = [
    ['イベント名', snapshot.event.eventName], ['配信種別', LABELS[kind]],
    ['配信回', job.batchSequence ? `第${job.batchSequence}回` : `一斉配信 ${job.jobId}`],
    ['正式メールの件名', sample.subject], ['配信開始日時（開始要求）', dateText(job.dispatchRequestedAt || job.broadcastStartedAt)],
    ['配信完了日時', dateText(job.completedAt)], ['対象件数', job.targetCount], ['送信成功件数', job.sentCount],
    ['失敗件数', job.failedCount], ['結果不明件数', job.unknownCount],
  ];
  const intro = rows.map(([k,v]) => `${k}：${v}`).join('\n') + '\n送信成功はメールサービスの受付成功であり、到着・開封の確認ではありません。\n' + NOTICE +
    (job.sentCount === 0 ? '\n送信成功0件のため、これは送信予定内容のサンプルです。実際に送信成功したコピーではありません。' : '\n代表1件の表示パターンです。全参加者の個別内容を網羅するものではありません。');
  const banner = `<section style="padding:20px;background:#eef3f8"><h2>配信確認</h2><p>${escapeHtml(intro).replace(/\n/g,'<br>')}</p><h3>正式メールの確認用コピー</h3></section>`;
  const html = safeHtml.replace(/(<body\b[^>]*>)/i, (_match, opening) => opening + banner);
  const text = intro + '\n\n【正式メールの確認用コピー】\n' + safeText;
  const subject = `【配信確認】${sample.subject}`;
  if (html.length > 100000 || text.length > 20000 || subject.length > 200) throw new Error('confirmation-too-large');
  return {subject, text, html, ...(sample.attachments.length ? {attachments: sample.attachments} : {}), senderName: snapshot.event.senderName,
    rendererVersion: RENDERER_VERSION};
}
module.exports = {RENDERER_VERSION, NOTICE, SENTINEL, LABELS, evidenceFor, renderConfirmation, ms};
