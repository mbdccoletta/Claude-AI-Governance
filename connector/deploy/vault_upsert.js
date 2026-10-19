// Runs in the Dynatrace JS runtime via `dtctl exec function -f deploy/vault_upsert.js --payload '{...}'`.
// Creates or updates a TOKEN credential in the credential vault scoped to APP_ENGINE so the workflow can read it.
// Payload: { "name": "<credential name>", "token": "<Anthropic key>", "description": "optional" }
// Returns: { id, created: boolean }
// The key never touches the dtctl config or a file: it travels only in this one request payload.
import { credentialVaultClient } from "@dynatrace-sdk/client-classic-environment-v2";

export default async function (payload) {
  const name = payload?.name;
  const token = payload?.token;
  if (!name || !token) throw new Error("payload must contain name and token");
  const description = payload?.description ?? "Anthropic Analytics/Admin API key for dt-ai-observability-claude layer 3";

  const list = await credentialVaultClient.listCredentials({ pageSize: 500 });
  const existing = (list?.credentials ?? []).find((c) => c.name === name);
  const body = { name, description, type: "TOKEN", token, scopes: ["APP_ENGINE"], ownerAccessOnly: false };

  if (existing) {
    await credentialVaultClient.updateCredentials({ id: existing.id, body });
    return { id: existing.id, created: false };
  }
  const res = await credentialVaultClient.createCredentials({ body });
  return { id: res.id, created: true };
}
