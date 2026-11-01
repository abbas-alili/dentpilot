// Test helpers: play Meta's side of the Flow encryption and of webhook signing.
import { fromBase64, hmacSha256Hex, toBase64 } from "../_shared/crypto.ts";

export async function generateFlowKeys(): Promise<{ privatePem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "RSA-OAEP", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["encrypt", "decrypt"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = toBase64(pkcs8).match(/.{1,64}/g)!.join("\n");
  return { privatePem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

/** Encrypt a Flow request the way WhatsApp does. */
export async function encryptAsMeta(payload: unknown, publicKey: CryptoKey) {
  const aesKey = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey("raw", aesKey, "AES-GCM", false, ["encrypt"]);
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(JSON.stringify(payload)));
  const wrapped = await crypto.subtle.encrypt({ name: "RSA-OAEP" }, publicKey, aesKey);
  return {
    request: {
      encrypted_flow_data: toBase64(new Uint8Array(data)),
      encrypted_aes_key: toBase64(new Uint8Array(wrapped)),
      initial_vector: toBase64(iv),
    },
    aesKey,
    iv,
  };
}

/** Decrypt our endpoint's answer the way WhatsApp does (flipped IV). */
export async function decryptAsMeta(body: string, aesKey: Uint8Array, iv: Uint8Array): Promise<any> {
  const key = await crypto.subtle.importKey("raw", aesKey, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv.map((b) => b ^ 0xff) }, key, fromBase64(body));
  return JSON.parse(new TextDecoder().decode(plain));
}

export async function signedRequest(url: string, payload: unknown, appSecret: string): Promise<Request> {
  const body = JSON.stringify(payload);
  return new Request(url, {
    method: "POST",
    body,
    headers: { "x-hub-signature-256": "sha256=" + await hmacSha256Hex(appSecret, body), "content-type": "application/json" },
  });
}
