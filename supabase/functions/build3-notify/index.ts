import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// Sends phone notifications for Newberry Build 3. It checks the caller's personal key itself, so JWT verification is off.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function vapid() {
  const { data } = await db.from("build3_secrets").select("k,v").in("k", ["vapid_public", "vapid_private"]);
  const m: Record<string, string> = Object.fromEntries((data || []).map((r: any) => [r.k, r.v]));
  if (m.vapid_public && m.vapid_private) return m;
  const g = webpush.generateVAPIDKeys();
  await db.from("build3_secrets").upsert([{ k: "vapid_public", v: g.publicKey }, { k: "vapid_private", v: g.privateKey }]);
  return { vapid_public: g.publicKey, vapid_private: g.privateKey };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const k = await vapid();
    if (req.method === "GET") return json({ publicKey: k.vapid_public });
    const b = await req.json();
    const code = String(b.code || ""), key = String(b.key || "");
    if (code.length < 20 || key.length < 20) return json({ error: "denied" }, 403);
    const { data: me } = await db.from("build3_people").select("pid,perm,active").eq("code", code).eq("key", key).maybeSingle();
    if (!me || !me.active) return json({ error: "denied" }, 403);
    if (!(me.perm?.send || me.perm?.manage)) return json({ error: "not allowed" }, 403);
    const to: string[] = Array.isArray(b.to) ? b.to.map(String) : [];
    const { data: people } = await db.from("build3_people").select("pid").eq("code", code).eq("active", true).neq("pid", me.pid);
    const pids = (people || []).filter((p: any) => to.includes("all") || to.includes(p.pid)).map((p: any) => p.pid);
    if (!pids.length) return json({ sent: 0, failed: 0 });
    const { data: subs } = await db.from("build3_push").select("endpoint,p256dh,auth").eq("code", code).in("pid", pids);
    if (!subs || !subs.length) return json({ sent: 0, failed: 0 });
    webpush.setVapidDetails("https://newberry-montessori-dashboard.vercel.app", k.vapid_public, k.vapid_private);
    const payload = JSON.stringify({ title: String(b.title || "Newberry Build").slice(0, 80), body: String(b.body || "").slice(0, 160), open: String(b.open || "").slice(0, 20) });
    let sent = 0, failed = 0;
    await Promise.all(subs.map(async (s: any) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
        sent++;
      } catch (e: any) {
        failed++;
        if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("build3_push").delete().eq("endpoint", s.endpoint);
      }
    }));
    return json({ sent, failed });
  } catch (e: any) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
