// Cryptography used by the functions — Web Crypto only, no dependencies.
//
//   verifyMetaSignature   X-Hub-Signature-256 on webhooks and Flow requests
//   constantTimeEqual     compare secrets without timing leaks
//   Flow encryption       RSA-OAEP(SHA-256) wraps a per-request AES-128-GCM key;
//                         the response is encrypted with the same key and the
//                         request IV with every byte flipped (XOR 0xFF).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// ---------------------------------------------------------------- encoding
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function constantTimeEqual(a: string, b: string): boolean {
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

// ---------------------------------------------------------------- Meta signature
export async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return toHex(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body))));
}

/** True if `header` ("sha256=<hex>") matches HMAC-SHA256(appSecret, rawBody). */
export async function verifyMetaSignature(
  appSecret: string,
  rawBody: string,
  header: string | null,
): Promise<boolean> {
  if (!header?.startsWith("sha256=")) return false;
  const expected = "sha256=" + await hmacSha256Hex(appSecret, rawBody);
  return constantTimeEqual(expected, header);
}

// ---------------------------------------------------------------- Flow encryption
export interface EncryptedFlowRequest {
  encrypted_flow_data: string;
  encrypted_aes_key: string;
  initial_vector: string;
}

export interface DecryptedFlowRequest {
  payload: Record<string, unknown>;
  aesKey: Uint8Array;
  iv: Uint8Array;
}

/** Import an unencrypted PKCS#8 PEM ("BEGIN PRIVATE KEY") for RSA-OAEP SHA-256. */
export async function importFlowPrivateKey(pem: string): Promise<CryptoKey> {
  if (pem.includes("BEGIN RSA PRIVATE KEY") || pem.includes("ENCRYPTED")) {
    throw new Error(
      "FLOW_PRIVATE_KEY must be unencrypted PKCS#8 (BEGIN PRIVATE KEY). " +
        "Convert with: openssl pkcs8 -topk8 -nocrypt -in private.pem -out private_pkcs8.pem",
    );
  }
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  return await crypto.subtle.importKey(
    "pkcs8", fromBase64(body), { name: "RSA-OAEP", hash: "SHA-256" }, false, ["decrypt"],
  );
}

export async function decryptFlowRequest(
  request: EncryptedFlowRequest,
  privateKey: CryptoKey,
): Promise<DecryptedFlowRequest> {
  const aesKey = new Uint8Array(
    await crypto.subtle.decrypt({ name: "RSA-OAEP" }, privateKey, fromBase64(request.encrypted_aes_key)),
  );
  const iv = fromBase64(request.initial_vector);
  const key = await crypto.subtle.importKey("raw", aesKey, { name: "AES-GCM" }, false, ["decrypt"]);
  // Meta appends the 16-byte GCM tag to the ciphertext, which is what Web Crypto expects.
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, tagLength: 128 }, key, fromBase64(request.encrypted_flow_data),
  );
  return { payload: JSON.parse(decoder.decode(plain)), aesKey, iv };
}

export async function encryptFlowResponse(
  response: unknown,
  aesKey: Uint8Array,
  requestIv: Uint8Array,
): Promise<string> {
  const flippedIv = requestIv.map((b) => b ^ 0xff);
  const key = await crypto.subtle.importKey("raw", aesKey, { name: "AES-GCM" }, false, ["encrypt"]);
  const cipher = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: flippedIv, tagLength: 128 }, key, encoder.encode(JSON.stringify(response)),
  );
  return toBase64(new Uint8Array(cipher));
}
