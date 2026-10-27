// base.xeroth.ai
//
// Requests for the network service (sign-in, applications, dashboards,
// administration and the /v1 RINEX API) are passed to the xeroth-network
// service on Cloud Run, so the whole site is one address. Everything else
// is this repository's site/ folder.

const PORTAL_ORIGIN = "https://xeroth-network-o6dy7dazpq-ew.a.run.app";
const PORTAL_PREFIXES = [
  "/apply", "/auth", "/dashboard", "/admin", "/v1", "/static", "/privacy", "/terms",
];

function toPortal(pathname) {
  return PORTAL_PREFIXES.some((p) => pathname === p || pathname.startsWith(p + "/"));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!toPortal(url.pathname)) {
      return env.ASSETS.fetch(request);
    }
    const target = new URL(url.pathname + url.search, PORTAL_ORIGIN);
    const headers = new Headers(request.headers);
    headers.set("X-Forwarded-Host", url.host);
    headers.set("X-Forwarded-Proto", url.protocol.replace(":", ""));
    headers.set("X-Forwarded-For", request.headers.get("CF-Connecting-IP") ?? "");
    return fetch(target, {
      method: request.method,
      headers,
      body: request.body,
      redirect: "manual",
    });
  },
};
