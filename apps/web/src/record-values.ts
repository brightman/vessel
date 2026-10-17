import type { FieldDefinition } from "./api";

function decimalKey(raw: string): string {
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(raw);
  if (!match) throw new Error("The JSON number format is invalid.");
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
      if (!/^-?\d+$/.test(raw)) throw new Error("Enter a complete integer.");
      if (!Number.isSafeInteger(Number(raw))) throw new Error("The integer is outside JavaScript's safe range. Use a numeric field instead.");
      return Number(raw);
    case "numeric": return raw;
    case "boolean":
      if (raw !== "true" && raw !== "false") throw new Error("Select Yes or No for a boolean value.");
      return raw === "true";
    case "timestamp": {
      if (!/(?:Z|[+-]\d{2}:\d{2})$/i.test(raw)) throw new Error("The timestamp must include a timezone, for example 2026-10-15T12:00:00Z.");
      const parsed = new Date(raw);
      if (Number.isNaN(parsed.getTime())) throw new Error("The timestamp format is invalid.");
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
        throw new Error("A JSON number would lose precision. Use a string to preserve the original value.");
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
