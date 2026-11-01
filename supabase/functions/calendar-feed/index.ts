// Entry point. Deploy with JWT verification off: the unguessable token in the
// path is the credential (iOS calendar subscriptions can't send headers).
import { createFeedHandler } from "./handler.ts";

Deno.serve(createFeedHandler());
