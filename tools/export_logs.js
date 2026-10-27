#!/usr/bin/env node
// Exports devices/<deviceId>/logs from Firestore into the JSON shape tools/analyze_gaps.js reads.
//   export GOOGLE_APPLICATION_CREDENTIALS=serviceAccount.json   (Firebase console > Project settings > Service accounts)
//   node tools/export_logs.js            -> lists device ids
//   node tools/export_logs.js <deviceId> export.json
const admin = require("../functions/node_modules/firebase-admin");
admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "test-back-sync" });
const db = admin.firestore();

(async () => {
  const [id, out] = process.argv.slice(2);
  if (!id) {
    const devices = await db.collection("devices").get();
    for (const d of devices.docs) {
      const x = d.data();
      console.log(d.id, x.platform ?? "?", `lastN=${x.lastN ?? 0}`, x.lastExit ? `lastExit=${x.lastExit}` : "");
    }
    return;
  }
  const snap = await db.collection(`devices/${id}/logs`).orderBy("clientTime").get();
  const logs = {};
  snap.forEach((d) => { logs[d.id] = d.data(); });
  require("fs").writeFileSync(out || "export.json", JSON.stringify({ logs }));
  console.log(`wrote ${snap.size} records to ${out || "export.json"}`);
})().catch((e) => { console.error(e.message); process.exit(1); });
