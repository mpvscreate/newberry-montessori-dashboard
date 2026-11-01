/* Serves week-view.html for a share link with link-preview tags filled in, so WhatsApp and other
   apps can show the first photo, the name and a short line. The page itself still loads the report. */
const FN = "https://oikwudpqmbnssttatlhc.supabase.co/functions/v1/build3-share";
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

module.exports = async (req, res) => {
  const host = req.headers["x-forwarded-host"] || req.headers.host, origin = "https://" + host;
  const t = String(new URL(req.url, origin).searchParams.get("t") || "");
  let title = "Newberry Build", desc = "Progress from the site.", img = origin + "/icons/build-512.png";
  try {
    if (/^[a-f0-9]{32}$/.test(t)) {
      const r = await fetch(FN + "?t=" + t + "&og=1");
      if (r.ok) {
        const d = await r.json(), name = d.name || "Newberry Build";
        if (d.type === "photos") {
          title = name + " · Photo update";
          const n = (d.photos || []).length, m = String(d.msg || "").replace(/\s+/g, " ").trim();
          desc = m ? (m.length > 140 ? m.slice(0, 137) + "..." : m) : n + " new photo" + (n === 1 ? "" : "s") + " from the site.";
          if (n) img = d.photos[0].url;
        } else if (d.hero) {
          title = name + " · Weekly progress";
          desc = d.hero.targets ? d.hero.reached + " of " + d.hero.targets + " weekly targets reached." : d.hero.done + " task" + (d.hero.done === 1 ? "" : "s") + " finished this week.";
        }
      }
    }
  } catch { /* fall back to the plain tags */ }
  let html = "";
  try { html = await (await fetch(origin + "/week-view.html")).text(); } catch { /* handled below */ }
  if (!html) { res.statusCode = 502; res.end("Could not load the page."); return; }
  const tags = `<meta property="og:type" content="website"><meta property="og:site_name" content="Newberry Build"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${esc(img)}"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(title)}"><meta name="twitter:description" content="${esc(desc)}"><meta name="twitter:image" content="${esc(img)}">`;
  html = html.replace(/<title>[^<]*<\/title>/, `<title>${esc(title)}</title>${tags}`).replace("<head>", '<head><base href="/">');
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "public, s-maxage=60, stale-while-revalidate=300");
  res.end(html);
};
