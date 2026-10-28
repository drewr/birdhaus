// birdhaus-watch: a small heartbeat and probe monitor (see ops/watch/README.md).
//
// Invoked three ways:
//   - Function URL: POST /ping/<check> or POST /fail/<check> (body: reason),
//     with "Authorization: Bearer <token>" for that check.
//   - EventBridge Scheduler every 5 minutes with {"task":"sweep"}: heartbeat
//     checks that went quiet and failing probes go down; alerts are emailed.
//   - {"task":"digest"} weekly, and {"task":"test-alert"} by hand.
//
// State is one DynamoDB item per check, holding JSON. Email goes through SES.

import { DynamoDBClient, GetItemCommand, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import { timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";

const checks = JSON.parse(readFileSync(new URL("./checks.json", import.meta.url), "utf8"));
const byName = new Map(checks.map((check) => [check.name, check]));
const tokens = JSON.parse(process.env.TOKENS || "{}");
const table = process.env.TABLE;
const db = new DynamoDBClient({});
const ses = new SESv2Client({});

const PROBE_FAILURES_BEFORE_ALERT = 2;
const REMIND_AFTER_MS = 24 * 60 * 60 * 1000;
const MAX_MESSAGE = 2000;

export async function handler(event) {
  if (event?.requestContext?.http) return http(event);
  switch (event?.task) {
    case "sweep": return sweep();
    case "digest": return digest();
    case "test-alert": return send("[birdhaus] Test alert", "This is a test from birdhaus-watch. Alerts reach this address.");
    default: throw new Error(`Unknown invocation: ${JSON.stringify(event).slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------- HTTP

async function http(event) {
  const [, action, name] = event.rawPath.split("/");
  const check = byName.get(name);
  if (!["ping", "fail"].includes(action) || !check || check.kind !== "heartbeat") return reply(404, "not found");
  if (event.requestContext.http.method !== "POST") return reply(405, "use POST");
  if (!authorized(event.headers?.authorization, tokens[name])) return reply(401, "unauthorized");

  const body = event.body ? (event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body) : "";
  const now = Date.now();
  const state = await load(name);
  state.lastPing = now;
  if (action === "ping") {
    state.failures = 0;
    if (state.status === "down") await recover(check, state, now);
    else state.status = "up";
    state.lastMessage = "";
  } else {
    state.failures += 1;
    state.lastMessage = body.trim().slice(0, MAX_MESSAGE) || "failure reported without a reason";
    if (state.status !== "down") await goDown(check, state, now, state.lastMessage);
  }
  await save(name, state);
  return reply(200, "ok");
}

function authorized(header, expected) {
  if (!expected || typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  const given = Buffer.from(header.slice(7));
  const want = Buffer.from(expected);
  return given.length === want.length && timingSafeEqual(given, want);
}

const reply = (statusCode, body) => ({ statusCode, headers: { "content-type": "text/plain" }, body });

// ---------------------------------------------------------------- sweep

async function sweep() {
  const now = Date.now();
  for (const check of checks) {
    try {
      await sweepCheck(check, now);
    } catch (error) {
      console.error(`sweep of ${check.name} failed:`, error);
    }
  }
  return { ok: true };
}

async function sweepCheck(check, now) {
  const state = await load(check.name);
  if (check.kind === "heartbeat") {
    // A check that has never pinged is measured from when it was first seen.
    const last = state.lastPing ?? state.firstSeen;
    const quietMinutes = (now - last) / 60000;
    if (quietMinutes > check.periodMinutes + check.graceMinutes && state.status !== "down") {
      await goDown(check, state, now, `No heartbeat for ${Math.round(quietMinutes)} minutes (expected every ${check.periodMinutes}).`);
    }
  } else {
    const problems = (await Promise.all(check.urls.map(probe))).filter(Boolean);
    if (problems.length === 0) {
      state.failures = 0;
      state.lastMessage = "";
      if (state.status === "down") await recover(check, state, now);
      else state.status = "up";
    } else {
      state.failures += 1;
      state.lastMessage = problems.join("\n");
      if (state.failures >= PROBE_FAILURES_BEFORE_ALERT && state.status !== "down") {
        await goDown(check, state, now, state.lastMessage);
      }
    }
  }
  // Also retries an alert whose email failed (lastAlert stays 0).
  if (state.status === "down" && now - (state.lastAlert ?? 0) > REMIND_AFTER_MS) {
    const label = state.lastAlert ? "STILL DOWN" : "DOWN";
    if (await alert(check, state, `Down since ${iso(state.since)}.\n\n${state.lastMessage}`, label)) state.lastAlert = now;
  }
  await save(check.name, state);
}

// Returns a description of the problem, or "" when the URL answers 200.
async function probe(url) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(10000), headers: { "user-agent": "birdhaus-watch" } });
    if (response.ok) return "";
    const body = (await response.text().catch(() => "")).slice(0, 300);
    return `${url} answered ${response.status}${body && !body.startsWith("<") ? `: ${body}` : ""}`;
  } catch (error) {
    return `${url} failed: ${error.cause?.code || error.name}: ${error.message}`;
  }
}

// ---------------------------------------------------------------- transitions

// State changes are saved even when the email fails; the next sweep retries it.
async function goDown(check, state, now, reason) {
  state.status = "down";
  state.since = now;
  state.lastAlert = (await alert(check, state, reason, "DOWN")) ? now : 0;
}

async function recover(check, state, now) {
  const minutes = Math.round((now - (state.since ?? now)) / 60000);
  state.status = "up";
  state.since = now;
  await trySend(`[birdhaus] RECOVERED ${check.name}`, `${check.name} is healthy again after about ${minutes} minutes down.`);
}

async function alert(check, state, reason, label) {
  const firstLine = reason.split("\n")[0].slice(0, 120);
  return trySend(
    `[birdhaus] ${label} ${check.name}: ${firstLine}`,
    `${check.name} is down (since ${iso(state.since)}).\n\n${reason}\n\nWhat to check: ${check.runbook}`
  );
}

async function digest() {
  const lines = [];
  for (const check of checks) {
    const state = await load(check.name);
    const seen = state.lastPing ? `, last heartbeat ${iso(state.lastPing)}` : "";
    lines.push(`${check.name}: ${state.status}${state.status === "down" ? ` since ${iso(state.since)}` : ""}${seen}`);
  }
  const anyDown = lines.some((line) => line.includes(": down"));
  await send(`[birdhaus] Weekly status: ${anyDown ? "problems" : "all healthy"}`,
    `${lines.join("\n")}\n\nIf this email stops arriving on Mondays, birdhaus-watch itself is broken.`);
  return { ok: true };
}

// ---------------------------------------------------------------- storage and email

async function load(name) {
  const result = await db.send(new GetItemCommand({ TableName: table, Key: { check: { S: name } }, ConsistentRead: true }));
  const stored = result.Item?.state?.S;
  return stored ? JSON.parse(stored) : { status: "new", failures: 0, firstSeen: Date.now(), lastMessage: "" };
}

async function save(name, state) {
  await db.send(new PutItemCommand({ TableName: table, Item: { check: { S: name }, state: { S: JSON.stringify(state) } } }));
}

async function trySend(subject, text) {
  try {
    await send(subject, text);
    return true;
  } catch (error) {
    console.error(`could not send "${subject}":`, error.message);
    return false;
  }
}

async function send(subject, text) {
  await ses.send(new SendEmailCommand({
    FromEmailAddress: process.env.FROM,
    Destination: { ToAddresses: [process.env.TO] },
    Content: { Simple: { Subject: { Data: subject }, Body: { Text: { Data: text } } } }
  }));
}

const iso = (ms) => (ms ? new Date(ms).toISOString().replace("T", " ").slice(0, 16) + " UTC" : "unknown");
