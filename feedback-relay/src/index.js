// ProcLens feedback relay — Cloudflare Worker.
//
// The ProcLens app POSTs a bug report / feature request here instead of
// redirecting the user to mail or a browser. This Worker holds the one
// secret the app itself never sees (a GitHub fine-grained PAT scoped to
// ONLY canberkys/proclens, ONLY "Issues: Read and write") and creates the
// GitHub issue server-side.
//
// Deliberately NOT real anti-abuse: the CLIENT_TOKEN check below only
// filters out casual/accidental hits (scanners, curious visitors poking
// the URL), not a determined attacker — it's baked into the shipped app
// binary and extractable from it like any client-side "secret". Real
// protection against abuse is GitHub's own per-token rate limit (the PAT
// can only create issues, nothing else) and this being a low-traffic,
// niche developer tool. Revisit only if that assumption stops holding.

const GITHUB_REPO = "canberkys/proclens";
const ALLOWED_TYPES = new Set(["bug", "feature"]);
const LABELS = { bug: ["bug"], feature: ["enhancement"] };
const MAX_TITLE_LENGTH = 200;
const MAX_BODY_LENGTH = 8000;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ ok: false, error: "Method not allowed" }, 405);
    }

    if (!env.CLIENT_TOKEN || request.headers.get("X-ProcLens-Client") !== env.CLIENT_TOKEN) {
      return json({ ok: false, error: "Unauthorized" }, 401);
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return json({ ok: false, error: "Malformed request body" }, 400);
    }

    const { type, title, description, diagnostics } = payload ?? {};

    if (!ALLOWED_TYPES.has(type)) {
      return json({ ok: false, error: "type must be 'bug' or 'feature'" }, 400);
    }
    if (typeof title !== "string" || title.trim().length === 0) {
      return json({ ok: false, error: "title is required" }, 400);
    }
    if (typeof description !== "string" || description.trim().length === 0) {
      return json({ ok: false, error: "description is required" }, 400);
    }
    if (title.length > MAX_TITLE_LENGTH) {
      return json({ ok: false, error: `title must be under ${MAX_TITLE_LENGTH} characters` }, 400);
    }
    if (description.length > MAX_BODY_LENGTH) {
      return json({ ok: false, error: `description must be under ${MAX_BODY_LENGTH} characters` }, 400);
    }

    const bodyParts = [description.trim()];
    if (typeof diagnostics === "string" && diagnostics.trim().length > 0) {
      bodyParts.push("---", "**Diagnostics** (attached by the app, reviewed by the user before sending):", "```", diagnostics.trim(), "```");
    }
    bodyParts.push("---", "_Submitted via ProcLens' in-app Report an Issue form._");

    const githubResponse = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "proclens-feedback-relay",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        title: title.trim(),
        body: bodyParts.join("\n\n"),
        labels: LABELS[type],
      }),
    });

    if (!githubResponse.ok) {
      const detail = await githubResponse.text();
      return json({ ok: false, error: `GitHub API error (${githubResponse.status})` }, 502, detail);
    }

    const issue = await githubResponse.json();
    return json({ ok: true, issueUrl: issue.html_url, issueNumber: issue.number });
  },
};

function json(body, status, logDetail) {
  if (logDetail) console.error(logDetail);
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
