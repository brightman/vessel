import { test } from "node:test";
import assert from "node:assert/strict";
import { asInput, parseValue } from "../apps/web/src/record-values.ts";

test("timestamp input keeps its explicit instant through edit and save", () => {
  const field = { type: "timestamp", nullable: false };
  assert.equal(asInput("2026-10-15T12:00:00+00:00", field), "2026-10-15T12:00:00+00:00");
  assert.equal(parseValue("2026-10-15T12:00:00+00:00", field), "2026-10-15T12:00:00.000Z");
  assert.throws(() => parseValue("2026-10-15T12:00", field), /时区/);
});

test("numeric input remains a precision-safe string", () => {
  assert.equal(parseValue("12345678901234567890.25", { type: "numeric", nullable: false }), "12345678901234567890.25");
});

test("JSON and nullable values parse deliberately", () => {
  assert.deepEqual(parseValue('{"ok":true}', { type: "json", nullable: false }), { ok: true });
  assert.equal(parseValue("", { type: "json", nullable: true }), null);
});

test("JSON and integer fields reject numbers that JavaScript would silently round", () => {
  const json = { type: "json", nullable: false };
  assert.throws(() => parseValue('{"account_id":9007199254740993}', json), /安全整数|精度/);
  assert.throws(() => parseValue('{"rate":0.1234567890123456789}', json), /安全整数|精度/);
  assert.deepEqual(parseValue('{"account_id":"9007199254740993"}', json), { account_id: "9007199254740993" });
  assert.deepEqual(parseValue('{"message":"id 9007199254740993","rate":0.1}', json), { message: "id 9007199254740993", rate: 0.1 });
  assert.throws(() => parseValue("9007199254740993", { type: "integer", nullable: false }), /安全整数|精度/);
});
