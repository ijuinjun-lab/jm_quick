// Read-only classification of abandoned import material. Never infer that an
// issued/used application can be replaced. The same reader runs inside commit
// transactions, including reception history queries (a cancelled check-in counts).
const {createHash} = require('node:crypto');
const hash = (v) => createHash('sha256').update(JSON.stringify(v)).digest('hex');
const usedAttendance = (a) => a.checkedIn === true || a.checkedInAt != null || a.checkedInBy != null ||
  a.attendedCount != null || (a.historySequence || 0) > 0 || a.entitlementStatus === 'revoked';
const stamp = (v) => v && typeof v.toDate === 'function' ? `${v.seconds}:${v.nanoseconds}` : v;

async function abandonedMaterial(db, eventId, {people, links, attendances, batches}) {
  const abandoned = new Set(batches.docs.filter((d) => d.data().status === 'abandoned').map((d) => d.id));
  const ignoredPeople = new Set(), ignoredAttendances = new Set(), ignoredLinks = new Set(), protectedPeople = new Set();
  const linkOrigins = new Map(), provenance = [];
  if (!abandoned.size) return {ignoredPeople, ignoredAttendances, ignoredLinks, protectedPeople, linkOrigins, fingerprint: hash([])};
  const ps = new Map(people.docs.map((d) => [d.id, d.data()]));
  const [deliveries, logs, jobs, grants] = await Promise.all(['mailDeliveries', 'mailLogs', 'sendJobs', 'qualificationGrants']
    .map((c) => db.collection(c).where('eventId', '==', eventId).get()));
  const records = [...deliveries.docs, ...logs.docs].map((d) => ({id: d.id, ...d.data()}));
  const usedBatches = new Set(jobs.docs.map((d) => d.data().batchId).filter((id) => abandoned.has(id)));
  const grantRows = grants.docs.map((d) => d.data());
  // Legacy links did not record their creating batch. Recover provenance only
  // from the original atomic row timestamp/key, never from a later use of a link.
  for (const id of abandoned) {
    const rows = await db.collection(`importBatches/${id}/rows`).get();
    for (const d of rows.docs) {
      const r = d.data();
      provenance.push([id, d.id, r.identity?.key, stamp(r.createdAt)]);
      for (const l of links.docs) if (!l.data().importBatchId && r.identity?.key === l.id &&
        r.participantId === l.data().participantId && r.createdAt && l.data().confirmedAt &&
        stamp(r.createdAt) === stamp(l.data().confirmedAt)) linkOrigins.set(l.id, id);
    }
  }
  for (const l of links.docs) if (l.data().importBatchId) linkOrigins.set(l.id, l.data().importBatchId);
  const hasMail = (pid, batchId, all) => usedBatches.has(batchId) || records.some((m) =>
    (all && (m.participantId === pid || m.id === `${pid}_winner` || m.id === `${pid}_reminder`)) ||
    ((m.batchId === batchId || m.importBatchId === batchId) && (!m.participantId || m.participantId === pid)) ||
    m.id === `${pid}_winner_${batchId}` || grantRows.some((g) => g.batchId === batchId && g.participantId === pid && g.deliveryId === m.id));
  const historyUsed = new Set();
  for (const a of attendances.docs) {
    const data = a.data();
    if (!abandoned.has(data.importBatchId) && !abandoned.has(ps.get(data.participantId)?.importBatchId)) continue;
    const history = await db.collection(`programAttendances/${a.id}/history`).get();
    if (usedAttendance(data) || !history.empty) historyUsed.add(a.id);
  }
  for (const [pid, p] of ps) if (abandoned.has(p.importBatchId)) {
    const used = hasMail(pid, p.importBatchId, true) || attendances.docs.some((a) => a.data().participantId === pid &&
      (historyUsed.has(a.id) || !abandoned.has(a.data().importBatchId))) ||
      grantRows.some((g) => g.participantId === pid && !abandoned.has(g.batchId));
    if (used) protectedPeople.add(pid); else ignoredPeople.add(pid);
  }
  for (const a of attendances.docs) if (abandoned.has(a.data().importBatchId)) {
    const data = a.data();
    if (historyUsed.has(a.id) || hasMail(data.participantId, data.importBatchId, false) || protectedPeople.has(data.participantId)) protectedPeople.add(data.participantId);
    else ignoredAttendances.add(a.id);
  }
  for (const l of links.docs) {
    const data = l.data(), origin = linkOrigins.get(l.id);
    if (abandoned.has(origin)) {
      if (hasMail(data.participantId, origin, false) || protectedPeople.has(data.participantId)) protectedPeople.add(data.participantId);
      else ignoredLinks.add(l.id);
    } else if (ignoredPeople.has(data.participantId)) {
      // Unknown provenance is not evidence that a relation is unused.
      protectedPeople.add(data.participantId);
    }
  }
  for (const pid of protectedPeople) ignoredPeople.delete(pid);
  for (const a of attendances.docs) if (protectedPeople.has(a.data().participantId)) ignoredAttendances.delete(a.id);
  for (const l of links.docs) if (protectedPeople.has(l.data().participantId)) ignoredLinks.delete(l.id);
  return {ignoredPeople, ignoredAttendances, ignoredLinks, protectedPeople, linkOrigins,
    fingerprint: hash([[...abandoned].sort(), [...ignoredPeople].sort(), [...ignoredAttendances].sort(), [...ignoredLinks].sort(), [...protectedPeople].sort(), provenance.sort()])};
}

// Selecting the same file follows a deterministic successor. Old in-flight commit
// requests still address the abandoned batch and are rejected, never resurrected.
async function resolveReimport(db, request) {
  const batches = await db.collection('importBatches').where('eventId', '==', request.eventId).get();
  const byId = new Map(batches.docs.map((d) => [d.id, d.data()]));
  const original = request.batchId;
  while (byId.get(request.batchId)?.status === 'abandoned') {
    request.batchId = `r${hash([request.eventId, request.batchId, 'abandoned-reimport']).slice(0, 38)}`;
  }
  return original === request.batchId ? null : request.batchId;
}
module.exports = {abandonedMaterial, resolveReimport};
