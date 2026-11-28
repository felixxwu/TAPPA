// Serves /b/<build-id>/* : files too big for Pages (over 25 MiB) come from the R2 bucket, the rest are Pages' own static files.
const TYPES = { wasm: "application/wasm", pck: "application/octet-stream", js: "text/javascript" };

// _headers is not reliably applied to responses that pass through a Function, and Godot's thread
// workers load index.js from here, so the cross-origin isolation headers are set on every response.
function isolate(headers) {
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("Cross-Origin-Embedder-Policy", "require-corp");
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
}

export async function onRequest({ request, env, params, next }) {
  if (request.method !== "GET" && request.method !== "HEAD") return next();
  const key = "b/" + params.path.join("/");
  const object = await env.BUILDS.get(key);
  if (!object) {
    const asset = await next();
    if (!asset.ok) return asset;
    const response = new Response(asset.body, asset);
    isolate(response.headers);
    return response;
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Content-Type", TYPES[key.split(".").pop()] ?? "application/octet-stream");
  headers.set("Content-Length", String(object.size));
  headers.set("ETag", object.httpEtag);
  isolate(headers);
  // The R2 copies are stored gzipped (Content-Encoding comes from writeHttpMetadata); "manual" sends them as they are.
  return new Response(request.method === "HEAD" ? null : object.body, { headers, encodeBody: "manual" });
}
