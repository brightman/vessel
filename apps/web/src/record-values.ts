import type { FieldDefinition } from "./api";

function decimalKey(raw: string): string {
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(raw);
  if (!match) throw new Error("JSON 数字格式无效。");
  let digits = `${match[2]}${match[3] ?? ""}`.replace(/^0+/, "");
  if (!digits) return "0";
  let exponent = BigInt(match[4] ?? "0") - BigInt((match[3] ?? "").length);
  const trailing = /0+$/.exec(digits)?.[0].length ?? 0;
  digits = digits.slice(0, digits.length - trailing);
  exponent += BigInt(trailing);
  return `${match[1]}${digits}e${exponent}`;
}

export function parseValue(raw: string, definition: FieldDefinition): unknown {
  if (raw === "" && definition.nullable) return null;
  switch (definition.type) {
    case "integer":
      if (!/^-?\d+$/.test(raw)) throw new Error("整数应填写完整数字。");
      if (!Number.isSafeInteger(Number(raw))) throw new Error("整数超出 JavaScript 安全整数范围，请使用 numeric 字段。");
      return Number(raw);
    case "numeric": return raw;
    case "boolean":
      if (raw !== "true" && raw !== "false") throw new Error("布尔值必须选择是或否。");
      return raw === "true";
    case "timestamp": {
      if (!/(?:Z|[+-]\d{2}:\d{2})$/i.test(raw)) throw new Error("时间必须包含时区，例如 2026-10-15T12:00:00Z。");
      const parsed = new Date(raw);
      if (Number.isNaN(parsed.getTime())) throw new Error("时间格式无效。");
      return parsed.toISOString();
    }
    case "json": {
      const value = JSON.parse(raw);
      const tokens = raw.match(/"(?:\\.|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g) ?? [];
      if (tokens.some(token => !token.startsWith('"') && (
        !Number.isFinite(Number(token)) ||
        (Number.isInteger(Number(token)) && !Number.isSafeInteger(Number(token))) ||
        decimalKey(token) !== decimalKey(Number(token).toString())
      ))) {
        throw new Error("JSON 数字会丢失精度，请改用字符串以保留原值。");
      }
      return value;
    }
    default: return raw;
  }
}

export function asInput(value: unknown, definition: FieldDefinition): string {
  if (value === null || value === undefined) return "";
  return definition.type === "json" ? JSON.stringify(value, null, 2) : String(value);
}
