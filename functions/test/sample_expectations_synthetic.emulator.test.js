// 提示集計に基づく匿名fixture検証。実CSV原本の照合ではない。本番アクセス・メール送信はしない。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {createImportApi} = require("../confirmed/import_api");
const {composeWinnerMailFor, composeReminderMailFor, loadAttendances} = require("../confirmed/winner_mail_message");
const {buildMailSnapshot} = require("../confirmed/mail_view_model");
const {receptionQrPayload} = require("../confirmed/pass_urls");
const {generateQrPng} = require("../qr_png");
const {EVENT_ID, participationType} = require("../confirmed/participation_types");
const {event} = require("../confirmed/test_support/participation_fixture");
const {EXPECTED_TYPES, EXPECTED_SLOTS, mapping, makeSyntheticSample} = require("../confirmed/test_support/sample_expectations_synthetic");
const APP_BASE_URL = "https://synthetic.example.invalid";

test("匿名fixtureのみ: 120行を現行import APIで照合し、一致後に7タイプの正本からメールを生成", {skip: skipReason()}, async (t) => {
  const env = await startAdminEmulator();
  t.after(() => env.stop());
  const {db, FieldValue} = env;
  const fixture = makeSyntheticSample();
  await db.doc(`events/${EVENT_ID}`).set(event());
  const api = createImportApi({getDb: () => db, serverTimestamp: () => FieldValue.serverTimestamp()});
  const data = buildImportRequest({eventId: EVENT_ID, clientRequestId: "synthetic120", sourceFileName: "synthetic-expected-aggregates.csv", table: fixture.table, mapping});
  const preview = await api.preview({data});
  assert.equal(preview.totalRecords, 120);
  assert.equal(preview.totalRows, 120);
  assert.equal(preview.readyCount, 120);
  assert.equal(preview.reviewCount, 0);
  assert.equal(preview.errorCount, 0);
  assert.equal(preview.blankRecordCount, 0);
  const types = Object.fromEntries(preview.participationTypes.map((r) => [r.value, r.count]));
  assert.deepEqual(types, EXPECTED_TYPES);
  assert.equal(Object.values(types).reduce((a, b) => a + b, 0), 120);
  for (const expected of fixture.rows) {
    const actual = preview.rows.find((r) => r.sourceRowNumber === expected.sourceRowNumber);
    assert.equal(actual.participationType, expected.expectedType,
      JSON.stringify({syntheticOnly: true, row: expected.sourceRowNumber, raw: expected.cells, actual, expectedType: expected.expectedType}));
    assert.deepEqual([...actual.programIds].sort(), expected.expectedAttendances.map((a) => a.programId).sort());
  }
  // 上の照合が一致しなければ、以降の保存・メール確認には進まない。保存先はdemoローカルEmulatorのみ。
  await api.commit({identity: {uid: "synthetic-admin"}, data: {...data, approvedReviewRows: [], excludedRows: []}});
  const participants = (await db.collection("participants").where("eventId", "==", EVENT_ID).get()).docs;
  const attendanceDocs = (await db.collection("programAttendances").where("eventId", "==", EVENT_ID).get()).docs;
  assert.equal(participants.length, 120);
  const totals = {"program-1": 0, "program-2": 0, "program-3": 0};
  const slotTotals = {"program-1": {}, "program-2": {}};
  const headcounts = {"program-1": 0, "program-2": 0, "program-3": 0};
  for (const doc of attendanceDocs) {
    const a = doc.data();
    totals[a.programId]++;
    headcounts[a.programId] += a.plannedCount;
    if (slotTotals[a.programId]) slotTotals[a.programId][a.slotLabel] = (slotTotals[a.programId][a.slotLabel] || 0) + 1;
  }
  assert.deepEqual(totals, {"program-1": 30, "program-2": 57, "program-3": 106});
  assert.deepEqual(slotTotals, EXPECTED_SLOTS);
  // レコード数と同行者込みの人数合計を混同していないことを確認。
  for (const id of Object.keys(totals)) assert.ok(headcounts[id] > totals[id]);
  const saved = new Map(participants.map((doc) => [doc.data().importRow, {participantId: doc.id, ...doc.data()}]));
  assert.equal(fixture.residuals.length, 3);
  assert.equal(fixture.residuals.filter((r) => r.programId === "program-1").length, 1);
  assert.equal(fixture.residuals.filter((r) => r.programId === "program-2").length, 2);
  for (const r of fixture.residuals) {
    const raw = fixture.rows.find((row) => row.sourceRowNumber === r.sourceRowNumber).cells;
    assert.equal(raw[r.participationColumn], "参加を希望しない");
    assert.equal(raw[r.countColumn], "2");
    assert.ok(!attendanceDocs.some((doc) => doc.data().participantId === saved.get(r.sourceRowNumber).participantId && doc.data().programId === r.programId));
  }
  for (const row of fixture.rows) {
    const participant = saved.get(row.sourceRowNumber);
    assert.equal(participant.name, row.cells["氏名"]);
    const actual = await loadAttendances(db, participant.participantId, EVENT_ID);
    assert.equal(participationType(EVENT_ID, actual), row.expectedType);
    assert.deepEqual(actual.map(({programId, slotLabel, plannedCount}) => ({programId, slotLabel, plannedCount})).sort((a, b) => a.programId.localeCompare(b.programId)), row.expectedAttendances);
  }
  t.diagnostic(JSON.stringify({source: "SYNTHETIC_ONLY_NOT_ORIGINAL_CSV", total: 120, ready: preview.readyCount,
    review: preview.reviewCount, error: preview.errorCount, types, programRecords: totals, slots: slotTotals, residualRowsIgnored: 3}));
  const savedEvent = (await db.doc(`events/${EVENT_ID}`).get()).data();
  for (const type of Object.keys(EXPECTED_TYPES)) {
    await t.test(`匿名fixture ${type}: 当選メール・リマインド、氏名／人数／枠／開催情報／単一QR`, async () => {
      const row = fixture.rows.find((r) => r.expectedType === type);
      const participant = saved.get(row.sourceRowNumber);
      const expectedQr = receptionQrPayload({appBaseUrl: APP_BASE_URL, eventId: EVENT_ID, participantId: participant.participantId, publicId: participant.publicId});
      for (const [compose, templateField] of [[composeWinnerMailFor, "winnerMailTemplate"], [composeReminderMailFor, "reminderMailTemplate"]]) {
        const built = buildMailSnapshot(EVENT_ID, savedEvent, {templateField});
        assert.equal(built.ok, true);
        let calls = 0;
        const mail = await compose({db, snapshot: built.snapshot, participantId: participant.participantId, participant, appBaseUrl: APP_BASE_URL,
          generateQrPng: async (payload) => { calls++; assert.equal(payload, expectedQr); return generateQrPng(payload); }});
        assert.equal(mail.ok, true);
        assert.equal(mail.viewModel.recipientName, row.cells["氏名"]);
        assert.ok(mail.text.includes(`${row.cells["氏名"]} 様`));
        assert.ok(mail.html.includes(`${row.cells["氏名"]} 様`));
        assert.equal(mail.qrPayload, expectedQr);
        assert.equal(calls, 1);
        assert.equal(mail.attachments.length, 1);
        assert.equal((mail.html.match(/<img /g) || []).length, 1);
        assert.ok(mail.text.includes("受付用QRコード"));
        assert.equal(mail.viewModel.venue, savedEvent.venue);
        assert.equal(mail.viewModel.address, savedEvent.venueInfo.address);
        assert.equal(mail.viewModel.access, savedEvent.venueInfo.access);
        assert.equal(mail.viewModel.dateTimeText, "2026年11月30日(月) 10:00〜16:00"); // 架空event設定の日時
        for (const [id, name] of [["program-1", "譲渡会（ねこ）"], ["program-2", "譲渡会（いぬ）"], ["program-3", "トークセッション"]]) {
          const expected = row.expectedAttendances.find((a) => a.programId === id);
          assert.equal(new RegExp(`■ ?${name}`).test(mail.text), Boolean(expected));
          assert.equal(new RegExp(`■ ?${name}`).test(mail.html), Boolean(expected));
          const item = mail.viewModel.programs.find((p) => p.programId === id);
          if (!expected) { assert.equal(item, undefined); continue; }
          const time = expected.slotLabel || savedEvent.confirmedMailSettings.talkTimeText;
          assert.equal(item.plannedCount, expected.plannedCount);
          assert.equal(item.timeText, time);
          assert.ok(mail.text.includes(`${id === "program-3" ? "開催時間" : "参加時間"}：${time}\n参加人数：${expected.plannedCount}名`));
          assert.ok(mail.html.includes(`${time}<br>参加人数：${expected.plannedCount}名`));
        }
      }
    });
  }
});
