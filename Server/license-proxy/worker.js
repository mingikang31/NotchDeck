// NotchDeck license proxy (Cloudflare Worker).
//
// POST /v1/licenses/activate    { license_key, machine_id, machine_name? } -> { receipt: { payload, signature } }
// POST /v1/licenses/deactivate  { license_key, machine_id, instance_id }    -> { deactivated: true }
//
// Activation is checked against the merchant (or the master key), then answered with an
// Ed25519-signed receipt the app verifies offline with its embedded public key.
//
// Secrets (never in source):  SIGNING_KEY_JWK, MASTER_LICENSE_KEY (optional)
// Vars:                       MERCHANT = "lemonsqueezy" | "mock", PRODUCT_ID = "notchdeck",
//                             LEMONSQUEEZY_STORE_ID?, LEMONSQUEEZY_PRODUCT_ID? (optional ownership checks)

const encoder = new TextEncoder();

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "Request body must be JSON." }, 400);
    }
    try {
      switch (new URL(request.url).pathname) {
        case "/v1/licenses/activate":
          return await activate(body, env);
        case "/v1/licenses/deactivate":
          return await deactivate(body, env);
        default:
          return json({ error: "Not found." }, 404);
      }
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message }, error.status);
      console.error(error);
      return json({ error: "The license server hit an unexpected error." }, 500);
    }
  },
};

async function activate(body, env) {
  const licenseKey = requiredString(body.license_key, "license_key", 8, 128);
  const machineID = requiredString(body.machine_id, "machine_id", 16, 128);
  const machineName = typeof body.machine_name === "string" ? body.machine_name.slice(0, 120) : "";

  const grant = (await isMasterKey(licenseKey, env))
    ? { edition: "master", instanceID: `master-${randomID()}`, customerName: null }
    : await merchant(env).activate(licenseKey, machineID, machineName);

  const payload = {
    v: 1,
    product: env.PRODUCT_ID || "notchdeck",
    edition: grant.edition,
    // Only a hint: the receipt must never reveal the key (especially the master key).
    license_key_hint: licenseKey.slice(-4).toUpperCase(),
    machine_id: machineID,
    instance_id: grant.instanceID,
    issued_at: new Date().toISOString(),
    customer_name: grant.customerName,
  };
  return json({ receipt: await sign(payload, env) });
}

async function deactivate(body, env) {
  const licenseKey = requiredString(body.license_key, "license_key", 8, 128);
  const instanceID = requiredString(body.instance_id, "instance_id", 1, 128);
  // Master activations hold no merchant seat, so there is nothing to release.
  if (!(await isMasterKey(licenseKey, env))) {
    await merchant(env).deactivate(licenseKey, instanceID);
  }
  return json({ deactivated: true });
}

// MARK: Master key

async function isMasterKey(licenseKey, env) {
  const master = (env.MASTER_LICENSE_KEY || "").trim().toUpperCase();
  if (!master) return false;
  // Compare fixed-length digests in constant time so response timing leaks nothing.
  const [a, b] = await Promise.all([sha256(licenseKey.trim().toUpperCase()), sha256(master)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// MARK: Merchants

function merchant(env) {
  switch ((env.MERCHANT || "lemonsqueezy").toLowerCase()) {
    case "mock":
      return mockMerchant;
    case "lemonsqueezy":
      return lemonSqueezy(env);
    default:
      throw new HttpError(500, "The license server is misconfigured (unknown MERCHANT).");
  }
}

// Local testing only: accepts any key starting with "TEST-".
const mockMerchant = {
  async activate(licenseKey) {
    if (!licenseKey.toUpperCase().startsWith("TEST-")) {
      throw new HttpError(403, "This license key isn't valid.");
    }
    return { edition: "standard", instanceID: `mock-${randomID()}`, customerName: "Test Customer" };
  },
  async deactivate() {},
};

function lemonSqueezy(env) {
  async function call(action, params) {
    const response = await fetch(`https://api.lemonsqueezy.com/v1/licenses/${action}`, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params),
    });
    const data = await response.json().catch(() => ({}));
    return { ok: response.ok, data };
  }

  return {
    async activate(licenseKey, machineID) {
      const { ok, data } = await call("activate", { license_key: licenseKey, instance_name: machineID });
      if (!ok || !data.activated) {
        throw new HttpError(403, data.error || "This license key couldn't be activated.");
      }
      const meta = data.meta || {};
      const wrongStore = env.LEMONSQUEEZY_STORE_ID && String(meta.store_id) !== String(env.LEMONSQUEEZY_STORE_ID);
      const wrongProduct = env.LEMONSQUEEZY_PRODUCT_ID && String(meta.product_id) !== String(env.LEMONSQUEEZY_PRODUCT_ID);
      if (wrongStore || wrongProduct) {
        await call("deactivate", { license_key: licenseKey, instance_id: data.instance?.id ?? "" });
        throw new HttpError(403, "This license key isn't for NotchDeck.");
      }
      return { edition: "standard", instanceID: data.instance.id, customerName: meta.customer_name ?? null };
    },
    async deactivate(licenseKey, instanceID) {
      const { ok, data } = await call("deactivate", { license_key: licenseKey, instance_id: instanceID });
      if (!ok || !data.deactivated) {
        throw new HttpError(400, data.error || "This Mac couldn't be deactivated.");
      }
    },
  };
}

// MARK: Signing

let signingKeyPromise;

function signingKey(env) {
  if (!env.SIGNING_KEY_JWK) throw new HttpError(500, "The license server is misconfigured (no signing key).");
  signingKeyPromise ??= crypto.subtle.importKey("jwk", JSON.parse(env.SIGNING_KEY_JWK), { name: "Ed25519" }, false, ["sign"]);
  return signingKeyPromise;
}

async function sign(payload, env) {
  const bytes = encoder.encode(JSON.stringify(payload));
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, await signingKey(env), bytes);
  return { payload: base64(bytes), signature: base64(new Uint8Array(signature)) };
}

// MARK: Helpers

function requiredString(value, name, min, max) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (trimmed.length < min || trimmed.length > max) throw new HttpError(400, `${name} is missing or invalid.`);
  return trimmed;
}

async function sha256(text) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

function randomID() {
  return Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, "0")).join("");
}

function base64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
