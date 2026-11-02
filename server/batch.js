// The batch orders are recorded under (orders.batch), set by the deploy
// (run.hs --batch). How many are left is the inventory's job (server/inventory.js).
export const currentBatch = (env = process.env) => ({ id: env.BATCH_ID || "xmas-2026" });
