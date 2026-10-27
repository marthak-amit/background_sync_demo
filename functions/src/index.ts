import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret, defineString } from "firebase-functions/params";
import { logger } from "firebase-functions";
import * as admin from "firebase-admin";
import * as crypto from "crypto";
import * as http2 from "http2";

admin.initializeApp();

// APNs auth key (.p8 contents) lives in Secret Manager, never in code:
//   firebase functions:secrets:set APNS_KEY_P8 < AuthKey_XXXXXXXXXX.p8
const APNS_KEY_P8 = defineSecret("APNS_KEY_P8");
const APNS_KEY_ID = defineString("APNS_KEY_ID");
const APNS_TEAM_ID = defineString("APNS_TEAM_ID");
const APNS_BUNDLE_ID = defineString("APNS_BUNDLE_ID", { default: "com.demo.backgroundSyncDemo" });
/** "true" for Xcode/debug builds (sandbox APNs), "false" for TestFlight / ad-hoc / production. */
const APNS_SANDBOX = defineString("APNS_SANDBOX", { default: "true" });

interface Meta {
  platform?: "android" | "ios";
  fcmToken?: string;
  voipToken?: string;
  lastWriteAt?: number;
  lastAlertAt?: number;
  lastExit?: string; // Android: why the previous process died, e.g. USER_REQUESTED_FORCE_STOP@<ms>
  lowPowerMode?: boolean; // iOS
  bgRefresh?: boolean; // iOS
  locationAlways?: boolean; // iOS
}

const CONCURRENCY = 25;

/** Runs `fn` over `items` with a bounded number of in-flight promises. */
async function pool<T>(items: T[], fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const workers = Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
    while (next < items.length) await fn(items[next++]);
  });
  await Promise.all(workers);
}

/** All device docs (meta fields live on devices/{id}; logs/posts are subcollections and are NOT loaded). */
async function loadDevices(): Promise<Map<string, Meta>> {
  const snap = await admin.firestore().collection("devices").get();
  const out = new Map<string, Meta>();
  for (const d of snap.docs) {
    const raw = d.data();
    out.set(d.id, {
      ...raw,
      lastWriteAt: raw.lastWriteAt?.toMillis?.(),
      lastAlertAt: typeof raw.lastAlertAt === "number" ? raw.lastAlertAt : raw.lastAlertAt?.toMillis?.(),
    } as Meta);
  }
  return out;
}

const deviceDoc = (id: string) => admin.firestore().doc(`devices/${id}`);

// ---------------------------------------------------------------- FCM (Android high priority + iOS silent)

async function sendFcm(id: string, meta: Meta): Promise<void> {
  const token = meta.fcmToken;
  if (!token) return;
  const message: admin.messaging.Message =
    meta.platform === "ios"
      ? {
          token,
          data: { type: "sync_tick" },
          apns: {
            headers: { "apns-push-type": "background", "apns-priority": "5" },
            payload: { aps: { "content-available": 1 } },
          },
        }
      : {
          token,
          data: { type: "sync_tick" },
          android: { priority: "high", ttl: 0 },
        };
  try {
    await admin.messaging().send(message);
  } catch (e) {
    const code = (e as { code?: string }).code ?? "";
    if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
      await deviceDoc(id).update({ fcmToken: admin.firestore.FieldValue.delete() });
      logger.warn("removed stale fcmToken", { id });
    } else {
      logger.error("fcm send failed", { id, code });
    }
  }
}

// ---------------------------------------------------------------- APNs VoIP (HTTP/2 + .p8 JWT)

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

function apnsJwt(keyPem: string, keyId: string, teamId: string): string {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const sig = crypto.sign("sha256", Buffer.from(`${header}.${claims}`), {
    key: keyPem,
    dsaEncoding: "ieee-p1363", // JWS ES256 wants raw r||s, not DER
  });
  return `${header}.${claims}.${b64url(sig)}`;
}

function sendVoip(
  session: http2.ClientHttp2Session,
  deviceToken: string,
  jwt: string,
  topic: string,
): Promise<{ status: number; reason?: string }> {
  return new Promise((resolve) => {
    const req = session.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": `${topic}.voip`,
      "apns-push-type": "voip",
      "apns-priority": "10",
      "apns-expiration": "0", // deliver now or drop: a stale wake is useless
    });
    let status = 0;
    let body = "";
    const timer = setTimeout(() => { req.close(); resolve({ status: 0, reason: "timeout" }); }, 10_000);
    req.on("response", (h) => { status = Number(h[":status"]); });
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      clearTimeout(timer);
      let reason: string | undefined;
      try { reason = body ? JSON.parse(body).reason : undefined; } catch { /* ignore */ }
      resolve({ status, reason });
    });
    req.on("error", () => { clearTimeout(timer); resolve({ status: 0, reason: "stream error" }); });
    req.end(JSON.stringify({ type: "sync_tick" }));
  });
}

// ---------------------------------------------------------------- the scheduled tick

export const syncTick = onSchedule(
  {
    schedule: "every 1 minutes",
    timeoutSeconds: 55,
    memory: "256MiB",
    secrets: [APNS_KEY_P8],
  },
  async () => {
    const metas = await loadDevices();

    // 1) FCM: Android high-priority data + iOS silent background push.
    await pool([...metas.entries()], ([id, m]) => sendFcm(id, m));

    // 2) iOS VoIP push over a single HTTP/2 session.
    const voip = [...metas.entries()].filter(([, m]) => m.platform === "ios" && m.voipToken);
    if (voip.length > 0) {
      const keyId = APNS_KEY_ID.value();
      const teamId = APNS_TEAM_ID.value();
      const key = APNS_KEY_P8.value().replace(/\\n/g, "\n");
      if (!keyId || !teamId || !key) {
        logger.warn("APNs not configured; skipping VoIP pushes");
      } else {
        const host = APNS_SANDBOX.value() === "true" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
        const session = http2.connect(`https://${host}`);
        session.on("error", (e) => logger.error("apns session error", e));
        try {
          const jwt = apnsJwt(key, keyId, teamId);
          await pool(voip, async ([id, m]) => {
            const r = await sendVoip(session, m.voipToken!, jwt, APNS_BUNDLE_ID.value());
            if (r.status === 200) return;
            if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") {
              await deviceDoc(id).update({ voipToken: admin.firestore.FieldValue.delete() });
              logger.warn("removed stale voipToken", { id, reason: r.reason });
            } else {
              logger.error("voip push failed", { id, status: r.status, reason: r.reason });
            }
          });
        } finally {
          session.close();
        }
      }
    }
    logger.info("syncTick done", { devices: metas.size, voip: voip.length });
  },
);

// ---------------------------------------------------------------- stale-device watchdog

const STALE_MS = 3 * 60_000;
const ALERT_COOLDOWN_MS = 30 * 60_000;

/** Turns the device's self-reported state into the one instruction the user needs. */
function staleMessage(m: Meta): string {
  if (m.platform === "ios") {
    if (m.lowPowerMode) return "Sync paused: turn off Low Power Mode, then open the app.";
    if (m.bgRefresh === false) return "Sync paused: turn on Background App Refresh for this app, then open the app.";
    if (m.locationAlways === false) return "Sync paused: set Location access to Always, then open the app.";
  } else if (m.lastExit?.startsWith("USER_REQUESTED_FORCE_STOP")) {
    return "Sync was force-stopped. Open the app and tap Start sync.";
  }
  return "Background sync stopped. Open the app to resume.";
}

/**
 * Every 5 min: any device that has not written for 3+ min gets a VISIBLE notification saying what to fix.
 * Visible alerts are not subject to Background App Refresh / Low Power Mode. They cannot reach a force-stopped
 * Android app or a phone with no connectivity; FCM holds them (ttl 1 h) until the device is reachable again.
 */
export const staleDeviceAlert = onSchedule(
  { schedule: "every 5 minutes", timeoutSeconds: 120, memory: "256MiB" },
  async () => {
    const metas = await loadDevices();
    const now = Date.now();
    let alerted = 0;
    await pool([...metas.entries()], async ([id, m]) => {
      if (!m.fcmToken || !m.lastWriteAt || now - m.lastWriteAt < STALE_MS) return;
      if (m.lastAlertAt && now - m.lastAlertAt < ALERT_COOLDOWN_MS) return;
      const body = staleMessage(m);
      try {
        await admin.messaging().send({
          token: m.fcmToken,
          notification: { title: "Background sync", body },
          android: { priority: "high", ttl: 3_600_000, notification: { channelId: "bgsync" } },
          apns: { headers: { "apns-priority": "10", "apns-push-type": "alert" }, payload: { aps: { sound: "default" } } },
        });
        await deviceDoc(id).update({ lastAlertAt: now });
        alerted++;
      } catch (e) {
        logger.warn("stale alert failed", { id, code: (e as { code?: string }).code });
      }
    });
    logger.info("staleDeviceAlert done", { devices: metas.size, alerted });
  },
);
