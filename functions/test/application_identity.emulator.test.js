const assert = require("node:assert/strict");
const {test} = require("node:test");
const {startAdminEmulator, skipReason, failingDb} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {createImportApi} = require("../confirmed/import_api");
const {createPassApi} = require("../confirmed/pass_api");
const {createAttendanceReportApi} = require("../confirmed/attendance_report_api");
const {composeWinnerMailFor} = require("../confirmed/winner_mail_message");
const {buildMailSnapshot} = require("../confirmed/mail_view_model");
const {collectReminderRecipients} = require("../confirmed/reminder_targets");
const {TYPES} = require("../confirmed/participation_types");
const f = require("../confirmed/test_support/participation_fixture");
const {fakeQrPng} = require("../confirmed/test_support/mail_fixtures");

test("application identity, seven participation types, grants and old QR (Emulator only)", {skip: skipReason(), timeout: 120000}, async () => {
  const emu = await startAdminEmulator();
  const {db, FieldValue} = emu;
  const stamp = () => FieldValue.serverTimestamp();
  const api = createImportApi({getDb: () => db, serverTimestamp: stamp, concurrency: 1});
  const pass = createPassApi({getDb: () => db, serverTimestamp: stamp, getAppBaseUrl: () => "https://example.invalid"});
  const report = createAttendanceReportApi({getDb: () => db});
  const identity = {uid: "synthetic-manager"};
  const outputs = [];
  const {createSendJobEngine} = require("../confirmed/send_jobs");
  const engine = createSendJobEngine({serverTimestamp: stamp});
  let serial = 0;
  function request(eventId, type, {promotion = false, extraCells = {}} = {}) {
    const mapping = structuredClone(f.mapping);
    mapping.participant.externalIdColumn = "id";
    mapping.participant.registeredAtColumn = "登録日時";
    const cells = {...f.cells(type), id: "001", 登録日時: "2026-10-01 12:00:00", ...extraCells};
    const extra = {};
    if (promotion) {
      const dog = type === "dog", slot = dog ? "14:10-14:50" : "10:10-10:50";
      const label = dog ? "午後の部（犬）" : "午前の部（猫）";
      mapping.waitlist = {optionsColumn: "キャンセル待希望枠", countColumn: "キャンセル待希望人数",
        options: [{label: "午前の部（猫）", programId: "program-1", kind: "猫"}, {label: "午後の部（犬）", programId: "program-2", kind: "犬"}]};
      cells.キャンセル待希望枠 = label + slot;
      cells.キャンセル待希望人数 = dog ? "3" : "2";
      Object.assign(extra, {notificationType: "waitlistPromotion", sourceSheetName: slot, sourceSheetCandidates: [slot]});
    }
    return buildImportRequest({eventId, clientRequestId: `Identity${++serial}`, mapping,
      sourceFileName: promotion ? `【${type === "dog" ? "犬" : "猫"}】synthetic.xlsx` : "synthetic.csv",
      table: {headers: Object.keys(cells), records: [Object.values(cells)]}, extra});
  }
  async function commit(data, target = undefined, useApi = api) {
    let v = await useApi.validate({data});
    if (target !== undefined) {
      data = {...data, identityDecisions: [{sourceRowNumber: 2, decisionKey: v.identityRows[0].decisionKey,
        kind: target === null ? "new" : "existing", ...(target ? {participantId: target} : {}), reason: "架空原本による確認"}]};
      v = await useApi.validate({data});
    }
    const full = {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      approvedReviewRows: v.reviewRows, approvalKeys: v.rows.flatMap((r) => Object.values(r.approvalKeys || {}))};
    return {result: await useApi.commit({identity, data: full}), data: full};
  }
  try {
    for (const {value: type} of TYPES) {
      const eventId = `identity${type.replaceAll("_", "")}`;
      const event = f.event({eventId, participationMapping: {catProgramId: "program-1", dogProgramId: "program-2", talkProgramId: "program-3"}});
      event.waitlistWinnerMailTemplate = {...event.winnerMailTemplate, subject: "架空の追加当選通知"};
      Object.assign(event.programs.find((p) => p.programId === "program-3"),
        {startAt: "2026-11-30T00:00:00Z", endAt: "2026-11-30T01:00:00Z"});
      await db.collection("events").doc(eventId).set(event);
      const roles = type.split("_");
      const first = roles.includes("talk") ? "talk" : roles.includes("cat") ? "cat" : "dog";
      const initial = request(eventId, first, {promotion: first !== "talk"});
      const v = await api.validate({data: initial});
      assert.equal(v.identityRows[0].action, "review", "absence alone must not create a participant");
      await assert.rejects(api.commit({identity, data: {...initial, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint}}), /確認/);
      const created = await commit(initial, null);
      const participantId = created.result.rows[0].participantId;
      const p = (await db.collection("participants").doc(participantId).get()).data();
      const input = {eventId, participantId, publicId: p.publicId};
      const oldPass = await pass.getPass({data: {participantId, publicId: p.publicId}});
      const firstProgram = first === "talk" ? "program-3" : first === "dog" ? "program-2" : "program-1";
      await pass.checkIn({identity, data: {...input, programId: firstProgram, attendedCount: 1}});
      const firstPath = `${participantId}_${firstProgram}`;
      const savedAttendance = (await db.collection("programAttendances").doc(firstPath).get()).data();
      // Seed only a historical delivery fixture; no job creation and no transport is invoked.
      await db.collection("mailDeliveries").doc(`${participantId}_winner`).set({eventId, participantId, status: "sent"});
      for (const role of roles.filter((r) => r !== first)) {
        const added = await commit(request(eventId, role, {promotion: true}));
        assert.equal(added.result.addedCount, 1);
        assert.equal(added.result.rows[0].participantId, participantId);
        assert.deepEqual((await db.collection("programAttendances").doc(firstPath).get()).data(), savedAttendance);
        const built = buildMailSnapshot(eventId, event, {templateField: "waitlistWinnerMailTemplate"});
        built.snapshot.grantBatchId = added.result.batchId;
        const mail = await composeWinnerMailFor({db, snapshot: built.snapshot, participantId, participant: p,
          appBaseUrl: "https://example.invalid", generateQrPng: fakeQrPng});
        assert.equal(mail.ok, true);
        assert.equal(mail.subject, "架空の追加当選通知");
        assert.equal(mail.viewModel.participationType, role, "notify only the newly awarded program");
        assert.equal(mail.viewModel.programs.length, 1);
        assert.equal(mail.viewModel.programs[0].plannedCount, role === "dog" ? 3 : 2);
        assert.deepEqual((await db.collection("qualificationGrants").doc(`${added.result.batchId}-${participantId}`).get()).data().programIds,
          [role === "dog" ? "program-2" : "program-1"]);
        assert.equal(mail.qrPayload, oldPass.qrPayload);
        const targets = await collectReminderRecipients(db, eventId);
        assert.equal(targets.targets.length, 0);
        assert.equal(targets.blocked.unknownWinnerMail, 1);
        // Isolated delivery-state fixtures only. Do not invoke job creation or any transport.
        const jobId = `winner-${added.result.batchId}`;
        const jobRef = db.collection("sendJobs").doc(jobId);
        const deliveryRef = db.collection("mailDeliveries").doc(`${participantId}_winner_${added.result.batchId}`);
        const initialDelivery = (await db.collection("mailDeliveries").doc(`${participantId}_winner`).get()).data();
        await jobRef.set({eventId, batchId: added.result.batchId, snapshot: built.snapshot,
          status: "ready", targetCount: 1, excludedInactiveCount: 0});
        await jobRef.collection("items").doc(participantId).set({status: "pending"});
        await deliveryRef.set({eventId, participantId, jobId, status: "pending"});
        const ctx = {db, jobId, participantId};
        const claims = await Promise.all([engine.claimItem(ctx), engine.claimItem(ctx)]);
        assert.equal(claims.filter((c) => c.claimed).length, 1);
        await engine.finishItem({...ctx, claimId: claims.find((c) => c.claimed).claimId, outcome: "failed"});
        assert.equal((await engine.retryFailed({db, jobId})).retried, 1);
        const claimed = await engine.claimItem(ctx);
        await engine.finishItem({...ctx, claimId: claimed.claimId, outcome: "sent"});
        assert.equal((await engine.claimItem(ctx)).claimed, false, "sent additions cannot be claimed twice");
        assert.deepEqual((await db.collection("mailDeliveries").doc(`${participantId}_winner`).get()).data(), initialDelivery);
        const sent = await collectReminderRecipients(db, eventId);
        await deliveryRef.update({status: "unknown"});
        assert.equal((await engine.claimItem(ctx)).claimed, false, "unknown additions cannot be retried");
        assert.equal((await engine.retryFailed({db, jobId})).retried, 0);
        const unknown = await collectReminderRecipients(db, eventId);
        assert.notEqual(unknown.fingerprint, sent.fingerprint);
        assert.equal(unknown.blocked.unknownWinnerMail, 1);
        await deliveryRef.update({status: "sent"});
      }
      const current = await pass.getPass({data: {participantId, publicId: p.publicId}});
      assert.equal(current.qrPayload, oldPass.qrPayload);
      assert.equal(current.webPassUrl, oldPass.webPassUrl);
      assert.equal(current.programs.length, roles.length);
      if (roles.includes("talk")) assert.equal(current.programs.find((a) => a.programId === "program-3").timeText, event.confirmedMailSettings.talkTimeText);
      const repeated = await commit(request(eventId, first, {promotion: first !== "talk"}));
      assert.equal(repeated.result.unchangedCount, 1);
      assert.equal((await db.collection("participants").where("eventId", "==", eventId).get()).size, 1);
      const collected = await collectReminderRecipients(db, eventId);
      assert.deepEqual(collected.targets, [participantId]);
      assert.equal(collected.recipients[0].programs.length, roles.length);
      if (roles.includes("talk")) {
        await db.collection("events").doc(eventId).update({"confirmedMailSettings.talkTimeText": "17:00-18:00"});
        assert.notEqual((await collectReminderRecipients(db, eventId)).fingerprint, collected.fingerprint);
        assert.equal((await pass.getPass({data: {participantId, publicId: p.publicId}})).programs.find((a) => a.programId === "program-3").timeText, "17:00-18:00");
        await db.collection("events").doc(eventId).update({"confirmedMailSettings.talkTimeText": event.confirmedMailSettings.talkTimeText});
      }
      const output = await report.getReport({data: {eventId}});
      outputs.push({type, output});
      assert.equal(output.participants.length, 1);
      assert.equal(output.participants[0].programs.length, roles.length);
      assert.equal(output.participants[0].programs.reduce((n, a) => n + a.plannedCount, 0), roles.reduce((n, r) => n + ({dog: 3, cat: 2, talk: 4}[r]), 0));
    }
    if (process.env.JM_QR_REPORT_FIXTURE) require("node:fs").writeFileSync(process.env.JM_QR_REPORT_FIXTURE, JSON.stringify(outputs));
    // Identity ambiguity and explicit, durable decisions.
    const eventId = "identitytalk";
    const personDoc = (await db.collection("participants").where("eventId", "==", eventId).get()).docs[0];
    const person = personDoc.data(), participantId = personDoc.id;
    for (const extraCells of [{id: ""}, {氏名: "架空 参加者"}, {メールアドレス: "changed@example.invalid"}, {登録日時: "2026-10-02 12:00:00"}]) {
      const v = await api.validate({data: request(eventId, "dog", {extraCells})});
      assert.equal(v.identityRows[0].action, "review");
    }
    const family = request(eventId, "cat", {extraCells: {id: "002", 氏名: "架空の別申込"}});
    const separately = await commit(family, null);
    assert.notEqual(separately.result.rows[0].participantId, participantId);
    // Legacy participants have no saved correspondence. Explicit A retains their existing identity.
    const legacyId = separately.result.rows[0].participantId;
    const legacyBefore = (await db.collection("participants").doc(legacyId).get()).data();
    const links = await db.collection("applicationLinks").where("participantId", "==", legacyId).get();
    for (const link of links.docs) await link.ref.delete();
    const legacyAddition = request(eventId, "dog", {promotion: true, extraCells: {id: "002", 氏名: "架空の別申込"}});
    assert.equal((await api.validate({data: legacyAddition})).identityRows[0].action, "review");
    assert.equal((await commit(legacyAddition, legacyId)).result.addedCount, 1);
    assert.deepEqual((await db.collection("participants").doc(legacyId).get()).data(), legacyBefore);
    const changedEmail = request(eventId, "dog", {promotion: true, extraCells: {メールアドレス: "changed@example.invalid"}});
    const changed = await commit(changedEmail, participantId);
    assert.equal(changed.result.addedCount, 1);
    assert.equal((await db.collection("participants").doc(participantId).get()).data().email, person.email, "identity confirmation must not overwrite contact details");
    const repeatChanged = await commit(request(eventId, "dog", {promotion: true, extraCells: {メールアドレス: "changed@example.invalid"}}));
    assert.equal(repeatChanged.result.unchangedCount, 1);
    for (const extraCells of [{午後参加人数: "9"}, {午後参加時間: "15:30-16:10"}]) {
      const v = await api.validate({data: request(eventId, "dog", {extraCells})});
      assert.equal(v.identityRows[0].reason, "qualification-conflict");
    }
    const duplicate = request(eventId, "cat");
    duplicate.rows.push({...duplicate.rows[0], rowNumber: 3}); duplicate.totalRecords = 2;
    assert((await api.validate({data: duplicate})).identityRows.every((r) => r.action === "review"));
    const missingId = request(eventId, "cat", {extraCells: {id: "", 氏名: "架空の番号なし申込"}});
    await commit(missingId, null);
    const differentSource = {...missingId, clientRequestId: `Identity${++serial}`, fileHash: "9".repeat(64)};
    assert.equal((await api.validate({data: differentSource})).identityRows[0].action, "review",
      "a previous name/email-only confirmation cannot merge a different file automatically");
    // Two batches compete for the same next sequence: only one may allocate and add.
    const raceEvent = "identitydog";
    const candidates = [request(raceEvent, "cat", {promotion: true}), request(raceEvent, "cat", {promotion: true})];
    const checked = await Promise.all(candidates.map(async (data) => {
      const v = await api.validate({data});
      return {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint};
    }));
    const raced = await Promise.allSettled(checked.map((data) => api.commit({identity, data})));
    assert.equal(raced.filter((r) => r.status === "fulfilled").length, 1);
    assert.equal((await db.collection("programAttendances").where("eventId", "==", raceEvent).get()).size, 2);
    // Interruption after allocation: lock persists, no partial qualification is visible; same request resumes.
    const failEvent = "identitycat";
    const data = request(failEvent, "dog", {promotion: true});
    const v = await api.validate({data});
    const full = {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint};
    const flaky = createImportApi({getDb: () => failingDb(db, {failAtTransaction: 2}), serverTimestamp: stamp, concurrency: 1});
    await assert.rejects(flaky.commit({identity, data: full}));
    assert.equal((await db.collection("programAttendances").where("eventId", "==", failEvent).get()).size, 1);
    const resumed = await api.commit({identity, data: full});
    assert.equal(resumed.addedCount, 1);
    assert.equal((await api.commit({identity, data: full})).idempotentReplay, true);
    // Even if event settings change during an interrupted import, its saved time/count plan is immutable.
    const frozenEvent = "identityfrozen";
    await db.collection("events").doc(frozenEvent).set(f.event({eventId: frozenEvent,
      participationMapping: {catProgramId: "program-1", dogProgramId: "program-2", talkProgramId: "program-3"}}));
    const frozenRequest = request(frozenEvent, "dog");
    frozenRequest.mapping.programs.find((p) => p.programId === "program-2").slotFormat = "timeRange";
    let frozenValidation = await api.validate({data: frozenRequest});
    frozenRequest.identityDecisions = [{sourceRowNumber: 2, kind: "new", reason: "架空原本確認", decisionKey: frozenValidation.identityRows[0].decisionKey}];
    frozenValidation = await api.validate({data: frozenRequest});
    const frozenFull = {...frozenRequest, expectedImportSequence: frozenValidation.expectedImportSequence, validationFingerprint: frozenValidation.validationFingerprint};
    const frozenTime = frozenValidation.identityRows[0].programs[0].startAt;
    assert.ok(frozenTime);
    await assert.rejects(flaky.commit({identity, data: frozenFull}));
    await db.collection("events").doc(frozenEvent).update({startAt: new Date("2026-12-01T01:00:00Z")});
    const frozenResult = await api.commit({identity, data: frozenFull});
    const frozenAttendance = (await db.collection("programAttendances").doc(`${frozenResult.rows[0].participantId}_program-2`).get()).data();
    assert.equal(frozenAttendance.startAt.toDate().toISOString(), frozenTime);
    const {createQualificationApi} = require("../confirmed/qualification_api");
    const qualificationApi = createQualificationApi({getDb: () => db, serverTimestamp: stamp});
    const input = {eventId, participantId, publicId: person.publicId};
    const beforeRevoke = await pass.getPass({data: {participantId, publicId: person.publicId}});
    await qualificationApi.revoke({identity, data: {eventId, participantId, programId: "program-2", reason: "架空の資格取消"}});
    assert.ok((await collectReminderRecipients(db, eventId)).targets.includes(participantId),
      "an explicitly revoked, unsent addition must not block the remaining sent qualification");
    assert.equal((await pass.getPass({data: {participantId, publicId: person.publicId}})).qrPayload, beforeRevoke.qrPayload);
    await assert.rejects(pass.checkIn({identity, data: {...input, programId: "program-2", attendedCount: 1}}), (e) => e.details.code === "qualification-revoked");
    const cancelled = await api.validate({data: request(eventId, "dog", {promotion: true})});
    assert.equal(cancelled.identityRows[0].reason, "qualification-conflict");
    const before = (await db.collection("programAttendances").doc(`${participantId}_program-3`).get()).data();
    await pass.correct({identity, data: {...input, programId: "program-3", attendedCount: 2}});
    await pass.cancel({identity, data: {...input, programId: "program-3"}});
    const after = (await db.collection("programAttendances").doc(`${participantId}_program-3`).get()).data();
    assert.equal(after.plannedCount, before.plannedCount); assert.equal(after.checkedIn, false);
  } finally { await db.terminate(); emu.stop(); }
});

test("legacy qualifications retain their promotion origin when a new qualification is added", () => {
  const eventId = "originfixture", participantId = "original-000002";
  const {buildAttendanceReport} = require("../confirmed/attendance_report_api");
  const result = buildAttendanceReport({eventId, event: f.event({eventId}),
    participants: [{id: participantId, data: {eventId, status: "active", importBatchId: "legacy"}}],
    batches: new Map([["legacy", {eventId, status: "committed", notificationType: "waitlistPromotion"}],
      ["added", {eventId, status: "committed", notificationType: "normal"}]]),
    attendances: [{eventId, participantId, programId: "program-1", plannedCount: 2, importBatchId: "legacy"},
      {eventId, participantId, programId: "program-2", plannedCount: 3, importBatchId: "added", identityVersion: 1, notificationType: "normal"}],
  });
  assert.deepEqual(result.participants[0].programs.map((a) => a.notificationType), ["waitlistPromotion", "normal"]);
});
