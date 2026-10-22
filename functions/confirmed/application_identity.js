// Application identity is an operator-confirmed relation, never a name/email dedupe.
// Exact source evidence can reuse a confirmed relation; edits require a new decision.
const {abandonedMaterial} = require("./abandoned_imports");
const {gzipSync, gunzipSync} = require("node:zlib");
const {createHash} = require("node:crypto");
const {ApiError} = require("./api_error");
const {programAttendanceId} = require("../programs");
const {allExclusionsOf} = require("./import_request");
const {displayPrograms, programTimeText} = require("./mail_view_model");
const digest = (value) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const iso = (v) => v ? new Date(typeof v.toDate === "function" ? v.toDate() : v).toISOString() : null;
const evidence = (p) => [p.sourceReference || null, p.name || "", p.email || "", iso(p.sourceRegisteredAt)];
const keyFor = (eventId, p) => digest([eventId, ...evidence(p)]);
const qualification = (a) => [a.programId, a.plannedCount, a.slotLabel || "", iso(a.startAt), iso(a.endAt)];
const active = (a) => a.entitlementStatus !== "revoked";
const fail = (code) => new ApiError("failed-precondition", "申込の照合結果が変更されたか、確認が必要です。再検証してください。", {code});

async function prepareIdentity(db, request, plan, event = {}) {
  const {eventId, batchId} = request;
  const programsById = new Map(displayPrograms(eventId, event).map((p) => [p.programId, p]));
  const timeText = (a) => programTimeText(a, programsById.get(a.programId) || {});
  const [people, links, attendances, batch, batches] = await Promise.all([
    db.collection("participants").where("eventId", "==", eventId).get(),
    db.collection("applicationLinks").where("eventId", "==", eventId).get(),
    db.collection("programAttendances").where("eventId", "==", eventId).get(),
    db.collection("importBatches").doc(batchId).get(),
    db.collection("importBatches").where("eventId", "==", eventId).get(),
  ]);
  const material = await abandonedMaterial(db, eventId, {people, links, attendances, batches});
  const ps = people.docs.filter((d) => !material.ignoredPeople.has(d.id)).map((d) => ({...d.data(), participantId: d.id}));
  const ls = new Map(links.docs.filter((d) => !material.ignoredLinks.has(d.id)).map((d) => [d.id, d.data()]));
  const as = attendances.docs.filter((d) => !material.ignoredAttendances.has(d.id)).map((d) => d.data());
  const excluded = new Set(allExclusionsOf(request).map((x) => x.sourceRowNumber));
  const decisions = new Map((request.identityDecisions || []).map((d) => [d.sourceRowNumber, d]));
  const inventoryFingerprint = digest([material.fingerprint, ps.map((p) => [p.participantId, evidence(p), p.status]).sort(),
    [...ls].sort(), as.map((a) => [a.participantId, qualification(a), a.entitlementStatus || "active"]).sort()]);
  const fingerprint = digest([inventoryFingerprint, plan.records.map((r) => [r.sourceRowNumber, r.attendances.map(qualification)])]);
  if (batch.exists && batch.data().eventId === eventId && batch.data().status !== "abandoned" && batch.data().identityPlan) {
    const frozen = decodePlan(batch.data().identityPlan);
    if (!request.identityDecisions.length) request.identityDecisions = frozen.decisions || batch.data().confirmedIdentityDecisions || [];
    const saved = frozen.rows;
    for (const r of plan.records) r.identity = saved.find((x) => x.sourceRowNumber === r.sourceRowNumber);
    return {rows: plan.records.map((r) => ({sourceRowNumber: r.sourceRowNumber, ...r.identity})), fingerprint};
  }
  const keys = new Map();
  for (const r of plan.records) if (r.participant && !excluded.has(r.sourceRowNumber)) {
    const key = keyFor(eventId, r.participant);
    keys.set(key, (keys.get(key) || 0) + 1);
  }
  const norm = (v) => String(v || "").normalize("NFKC").replace(/\s+/g, "").toLowerCase();
  const sourceRows = plan.records.filter((r) => r.participant && !excluded.has(r.sourceRowNumber));
  const used = new Set();
  const rows = plan.records.map((r) => {
    const p = r.participant;
    const evidenceKey = p ? keyFor(eventId, p) : null;
    // Incomplete source identity may reuse a decision only for the same source file/row.
    // A name/email pair must not silently merge a different application in a later file.
    const key = p && (!p.sourceReference || !p.sourceRegisteredAt) ?
      digest([evidenceKey, request.fileHash, request.sourceSheetName || null, r.sourceRowNumber]) : evidenceKey;
    const decisionKey = digest([inventoryFingerprint, r.sourceRowNumber, key, r.attendances.map(qualification)]);
    const matches = ps.filter((x) => p && (norm(x.email) === norm(p.email) || norm(x.name) === norm(p.name) ||
      (p.sourceReference && norm(x.sourceReference) === norm(p.sourceReference))));
    const bulkReasons = [];
    if (!p || !p.sourceReference || !p.sourceRegisteredAt || !p.name || !p.email) bulkReasons.push("incomplete-evidence");
    if (matches.length || ls.has(key)) bulkReasons.push("existing-candidate");
    if (p && sourceRows.some((other) => other !== r &&
      (norm(other.participant.email) === norm(p.email) || norm(other.participant.name) === norm(p.name) ||
       (p.sourceReference && norm(other.participant.sourceReference) === norm(p.sourceReference))))) bulkReasons.push("conflicting-source-rows");
    if (r.status !== "ready" || excluded.has(r.sourceRowNumber)) bulkReasons.push("row-not-ready");
    const bulkEligible = bulkReasons.length === 0;
    const d = decisions.get(r.sourceRowNumber);
    if (d?.mode === "bulk" && (!bulkEligible || d.kind !== "new")) throw fail("bulk-identity-ineligible");
    const confirmed = d && d.decisionKey === decisionKey;
    let participantId = ls.get(key)?.participantId || null;
    let action = "review", reason = "identity-unconfirmed";
    const abandonedUsed = material.protectedPeople.has(participantId) || matches.some((x) => material.protectedPeople.has(x.participantId));
    if (confirmed && !abandonedUsed) {
      if (d.kind === "existing") {
        if (participantId && participantId !== d.participantId) throw fail("identity-link-conflict");
        participantId = d.participantId;
      } else if (!participantId) { participantId = r.participantId; action = "created"; }
      else throw fail("identity-already-linked");
    }
    const person = ps.find((x) => x.participantId === participantId);
    let additions = [];
    if (person && person.status === "active" && person.schemaVersion === 2) {
      action = "added";
      const current = as.filter((a) => a.participantId === participantId);
      for (const a of r.attendances) {
        const previous = current.find((x) => x.programId === a.programId);
        if (!previous) additions.push(a.programId);
        else if (!active(previous) || JSON.stringify(qualification(previous)) !== JSON.stringify(qualification(a))) {
          action = "review"; reason = "qualification-conflict";
        }
      }
      if (action === "added" && !additions.length) action = "unchanged";
    } else if (action === "created") additions = r.attendances.map((a) => a.programId);
    else if (participantId) { action = "review"; reason = "participant-unavailable"; }
    if (abandonedUsed || material.protectedPeople.has(participantId)) {
      action = "review"; reason = "abandoned-record-used";
    }
    // Identical evidence cannot safely distinguish two applications. Never choose one automatically.
    if (keys.get(evidenceKey) > 1) { action = "review"; reason = "duplicate-identity-evidence"; }
    if (participantId && used.has(participantId)) { action = "review"; reason = "duplicate-target-in-file"; }
    if (excluded.has(r.sourceRowNumber)) action = "excluded";
    else if (r.status === "error") action = "error";
    if (["created", "added", "unchanged"].includes(action)) used.add(participantId);
    const candidates = matches.map((x) => ({
      participantId: x.participantId, name: x.name, email: x.email, sourceReference: x.sourceReference || null,
      sourceRegisteredAt: iso(x.sourceRegisteredAt), status: x.status,
      programs: as.filter((a) => a.participantId === x.participantId).map((a) => ({programId: a.programId,
        plannedCount: a.plannedCount, slotLabel: a.slotLabel || null, timeText: timeText(a), entitlementStatus: a.entitlementStatus || "active",
        startAt: iso(a.startAt), endAt: iso(a.endAt)})),
    }));
    const replacedAttendances = attendances.docs.filter((d) => material.ignoredAttendances.has(d.id) &&
      d.data().participantId === participantId && additions.includes(d.data().programId)).map((d) => d.id);
    const abandonedCandidates = people.docs.filter((d) => material.ignoredPeople.has(d.id) && p &&
      (norm(d.data().email) === norm(p.email) || norm(d.data().name) === norm(p.name) ||
       (p.sourceReference && norm(d.data().sourceReference) === norm(p.sourceReference)))).map((d) => d.id);
    const replacementFingerprint = digest([links.docs.filter((d) => d.id === key && material.ignoredLinks.has(d.id)).map((d) => [d.id, d.data()]),
      attendances.docs.filter((d) => replacedAttendances.includes(d.id)).map((d) => [d.id, d.data()]).sort()]);
    r.identity = {replacedLinkBatchId: material.ignoredLinks.has(key) ? material.linkOrigins.get(key) : null, abandonedCandidates, replacementFingerprint, replacedAttendances, replacedLink: material.ignoredLinks.has(key) ? key : null, sourceRowNumber: r.sourceRowNumber, action, participantId, key, decisionKey, additions,
      qualifications: r.attendances.map(({programId, plannedCount, slotLabel, startAt, endAt}) =>
        ({programId, plannedCount, slotLabel, startAt, endAt})),
      reason: ["review", "error"].includes(action) ? reason : null,
      decision: confirmed ? {kind: d.kind, reason: d.reason, ...(d.mode ? {mode: d.mode, basis: "complete-unique-evidence-no-candidates"} : {})} : {kind: "saved-link", reason: "確認済みの対応関係"}};
    return {...r.identity, bulkEligible, bulkReasons, candidates, input: p ? {...p, sourceRegisteredAt: iso(p.sourceRegisteredAt)} : null,
      programs: r.attendances.map((a) => ({...a, timeText: timeText(a), startAt: iso(a.startAt), endAt: iso(a.endAt)}))};
  });
  return {rows, fingerprint, ignoredParticipantIds: [...material.ignoredPeople]};
}

function remapRecord(record) {
  const id = record.identity;
  if (!id || !["created", "added", "unchanged"].includes(id.action)) return record;
  return {...record, participantId: id.participantId,
    attendances: (id.qualifications || record.attendances).filter((a) => id.additions.includes(a.programId)).map((a) => ({...a,
      participantId: id.participantId, attendanceId: programAttendanceId(id.participantId, a.programId)}))};
}
function encodePlan(rows, decisions) {
  const value = gzipSync(Buffer.from(JSON.stringify({rows, decisions}))).toString("base64");
  if (Buffer.byteLength(value) > 600000) throw fail("identity-plan-too-large");
  return value;
}
function decodePlan(value) {
  return Array.isArray(value) ? {rows: value} : JSON.parse(gunzipSync(Buffer.from(value, "base64")).toString());
}
module.exports = {decodePlan, encodePlan, prepareIdentity, remapRecord, keyFor, qualification, active, fail, digest};
