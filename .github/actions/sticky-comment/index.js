const fs = require("node:fs");

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, "_").toUpperCase()}`;
  const value = process.env[key]?.trim() ?? "";
  if (!value) {
    throw new Error(`${name} input is required`);
  }
  return value;
}

async function github(path, options = {}) {
  const token = getInput("github-token");
  const response = await fetch(`https://api.github.com${path}`, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "commander-sticky-comment",
      ...(options.headers ?? {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${response.status}: ${body}`);
  }

  if (response.status === 204) {
    return null;
  }
  return response.json();
}

async function findExistingComment(repository, issueNumber, marker) {
  for (let page = 1; ; page += 1) {
    const comments = await github(
      `/repos/${repository}/issues/${issueNumber}/comments?per_page=100&page=${page}`
    );

    const match = comments.find((comment) => comment.body?.includes(marker));
    if (match) {
      return match;
    }
    if (comments.length < 100) {
      return null;
    }
  }
}

async function main() {
  const repository = getInput("repository");
  const issueNumber = getInput("issue-number");
  const marker = getInput("marker");
  const bodyFile = getInput("body-file");

  const body = fs.readFileSync(bodyFile, "utf8");
  if (!body.includes(marker)) {
    throw new Error("Comment body must contain the configured marker");
  }

  const existing = await findExistingComment(repository, issueNumber, marker);

  if (existing) {
    console.log(`Updating existing comment ${existing.id}`);
    await github(
      `/repos/${repository}/issues/comments/${existing.id}`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body }),
      }
    );
  } else {
    console.log("Creating comment");
    await github(
      `/repos/${repository}/issues/${issueNumber}/comments`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body }),
      }
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
