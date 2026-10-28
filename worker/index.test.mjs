// node --test worker/
import { test } from "node:test";
import assert from "node:assert/strict";
import { toPortal, cookie, signedInNav, whoIsSignedIn } from "./index.js";

const req = (cookies) => new Request("https://base.xeroth.ai/", { headers: cookies ? { Cookie: cookies } : {} });

test("portal paths go to the portal, site paths do not", () => {
  for (const p of ["/admin", "/admin/users", "/v1/stations", "/auth/session", "/apply", "/dashboard"]) assert.ok(toPortal(p), p);
  for (const p of ["/", "/build/", "/assets/site.css", "/applyx", "/administrator"]) assert.ok(!toPortal(p), p);
});

test("cookies are read by exact name", () => {
  assert.equal(cookie(req("a=1; xn_session=abc.def=; xn_csrf=t"), "xn_session"), "abc.def=");
  assert.equal(cookie(req("xn_sessionx=1"), "xn_session"), "");
});

test("no session cookie: the portal is not asked", async () => {
  let asked = false;
  assert.equal(await whoIsSignedIn(req(""), async () => { asked = true; }), null);
  assert.equal(asked, false);
});

test("a live session gives the signed-in menu, an expired one does not", async () => {
  const live = async () => new Response(JSON.stringify({ signed_in: true, role: "admin", status: "approved" }));
  const who = await whoIsSignedIn(req("xn_session=s"), live);
  const nav = signedInNav(who, 'tok"en');
  assert.match(nav, /href="\/admin"/);
  assert.match(nav, /href="\/dashboard"/);
  assert.match(nav, /value="tok&quot;en"/);
  assert.doesNotMatch(nav, /Sign in/);
  const expired = async () => new Response(JSON.stringify({ signed_in: false }));
  assert.equal(await whoIsSignedIn(req("xn_session=s"), expired), null);
  const down = async () => { throw new Error("portal down"); };
  assert.equal(await whoIsSignedIn(req("xn_session=s"), down), null);
});

test("an applicant is pointed at their application, a new visitor at applying", () => {
  assert.match(signedInNav({ role: "operator", status: "applied" }, ""), /\/apply\/status/);
  assert.match(signedInNav({ role: null, status: null }, ""), /href="\/apply"/);
  assert.doesNotMatch(signedInNav({ role: "consumer", status: "approved" }, ""), /\/admin/);
});
