// Entry point. Deploy with JWT verification off; the request is authenticated
// by the X-Hub-Signature-256 check and the encryption itself.
import { env, envOr, SECRETS } from "../_shared/config.ts";
import { importFlowPrivateKey } from "../_shared/crypto.ts";
import { createFlowHandler } from "./handler.ts";

Deno.serve(createFlowHandler({
  privateKey: await importFlowPrivateKey(env(SECRETS.flowPrivateKey)),
  appSecret: env(SECRETS.waAppSecret),
  verifySignature: envOr("FLOW_VERIFY_SIGNATURE", "true") !== "false",
}));
