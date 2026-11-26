// Runs worker.js locally under Node (no wrangler needed), reading secrets from the repo-root .env.
//
//   node Server/license-proxy/dev-server.mjs     -> http://127.0.0.1:8787
//
// Debug builds of NotchDeck point LICENSE_API_BASE_URL here.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import worker from "./worker.js";

function loadEnv(url) {
  const env = {};
  for (const line of readFileSync(url, "utf8").split("\n")) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (match) env[match[1]] = match[2];
  }
  return env;
}

const env = loadEnv(new URL("../../.env", import.meta.url));
const port = Number(process.env.PORT || 8787);

createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const request = new Request(`http://127.0.0.1:${port}${req.url}`, {
    method: req.method,
    headers: { "Content-Type": req.headers["content-type"] || "application/json" },
    body: req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks),
  });
  const response = await worker.fetch(request, env);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
  console.log(`${req.method} ${req.url} -> ${response.status}`);
}).listen(port, "127.0.0.1", () => {
  console.log(`NotchDeck license proxy (MERCHANT=${env.MERCHANT || "lemonsqueezy"}) on http://127.0.0.1:${port}`);
});
