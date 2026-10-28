// base.xeroth.ai
//
// Requests for the network service (sign-in, applications, dashboards,
// administration and the /v1 RINEX API) are passed to the xeroth-network
// service on Cloud Run, so the whole site is one address. Everything else
// is this repository's site/ folder.
//
// The site's pages are static, so on their own they cannot know who is
// signed in. For a visitor carrying the portal's session cookie, the
// Worker asks the portal who that is and rewrites the page's menu to the
// signed-in one, the same as on the portal's own pages.

const PORTAL_ORIGIN = "https://xeroth-network-o6dy7dazpq-ew.a.run.app";
const PORTAL_PREFIXES = [
  "/apply", "/auth", "/dashboard", "/admin", "/v1", "/static", "/privacy", "/terms",
];

export function toPortal(pathname) {
  return PORTAL_PREFIXES.some((p) => pathname === p || pathname.startsWith(p + "/"));
}

export function cookie(request, name) {
  const header = request.headers.get("Cookie") || "";
  for (const part of header.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return "";
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export function signedInNav(who, csrf) {
  let links = '<a href="/build/">Build a station</a>' +
    '<a href="/#join">Join the network</a>' +
    '<a href="/#data">Get RINEX</a>';
  if (who.role === "admin") links += '<a href="/admin">Admin</a>';
  if (who.status === "approved") links += '<a href="/dashboard">Dashboard</a>';
  else if (who.status === "applied") links += '<a href="/apply/status">Your application</a>';
  else links += '<a href="/apply">Apply</a>';
  links += '<form action="/auth/logout" method="post" class="nav-form">' +
    `<input type="hidden" name="csrf_token" value="${escape(csrf)}">` +
    '<button type="submit" class="nav-github">Sign out</button></form>';
  return links;
}

function forward(request, url) {
  const incoming = new URL(request.url);
  const target = new URL(url.pathname + url.search, PORTAL_ORIGIN);
  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-Host", incoming.host);
  headers.set("X-Forwarded-Proto", incoming.protocol.replace(":", ""));
  headers.set("X-Forwarded-For", request.headers.get("CF-Connecting-IP") ?? "");
  return fetch(target, { method: request.method, headers, body: request.body, redirect: "manual" });
}

export async function whoIsSignedIn(request, fetcher = fetch) {
  if (!cookie(request, "xn_session")) return null;
  try {
    const r = await fetcher(new Request(new URL("/auth/session", PORTAL_ORIGIN), {
      headers: { Cookie: request.headers.get("Cookie") || "" },
    }));
    if (!r.ok) return null;
    const who = await r.json();
    return who.signed_in ? who : null;
  } catch {
    return null;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (toPortal(url.pathname)) return forward(request, url);

    const page = await env.ASSETS.fetch(request);
    const type = page.headers.get("Content-Type") || "";
    if (!type.startsWith("text/html")) return page;
    const who = await whoIsSignedIn(request);
    if (!who) return page;
    const nav = signedInNav(who, cookie(request, "xn_csrf"));
    const out = new HTMLRewriter()
      .on("nav#site-nav", { element(el) { el.setInnerContent(nav, { html: true }); } })
      .transform(page);
    const headers = new Headers(out.headers);
    headers.set("Cache-Control", "private, no-store");
    return new Response(out.body, { status: out.status, headers });
  },
};
