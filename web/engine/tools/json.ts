// JSON parsing that keeps integers beyond 2^53 exact. The goldens print raw modem timestamps as 17-digit
// integers (77282930941493954); JSON.parse would round them to the nearest double and hide a one-unit error.
// Integers within the safe range stay numbers; larger ones become bigint.

export type Json = null | boolean | number | bigint | string | Json[] | { [key: string]: Json };

export function parseJsonExact(text: string): Json {
  let i = 0;
  const ws = () => {
    while (i < text.length && (text[i] === ' ' || text[i] === '\n' || text[i] === '\r' || text[i] === '\t')) i++;
  };
  const fail = (what: string): never => {
    throw new SyntaxError(`JSON: ${what} at ${i}`);
  };
  const value = (): Json => {
    ws();
    const c = text[i];
    if (c === '{') {
      i++;
      const out: { [key: string]: Json } = {};
      ws();
      if (text[i] === '}') {
        i++;
        return out;
      }
      for (;;) {
        ws();
        if (text[i] !== '"') fail('expected a key');
        const key = string();
        ws();
        if (text[i++] !== ':') fail("expected ':'");
        out[key] = value();
        ws();
        if (text[i] === ',') {
          i++;
          continue;
        }
        if (text[i++] !== '}') fail("expected ',' or '}'");
        return out;
      }
    }
    if (c === '[') {
      i++;
      const out: Json[] = [];
      ws();
      if (text[i] === ']') {
        i++;
        return out;
      }
      for (;;) {
        out.push(value());
        ws();
        if (text[i] === ',') {
          i++;
          continue;
        }
        if (text[i++] !== ']') fail("expected ',' or ']'");
        return out;
      }
    }
    if (c === '"') return string();
    if (text.startsWith('true', i)) return (i += 4, true);
    if (text.startsWith('false', i)) return (i += 5, false);
    if (text.startsWith('null', i)) return (i += 4, null);
    return number();
  };
  const string = (): string => {
    const start = i;
    i++;
    while (i < text.length && text[i] !== '"') i += text[i] === '\\' ? 2 : 1;
    if (i >= text.length) fail('unterminated string');
    i++;
    return JSON.parse(text.slice(start, i));
  };
  const number = (): number | bigint => {
    const m = /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/.exec(text.slice(i, i + 64));
    if (!m) fail('unexpected character');
    i += m![0].length;
    const literal = m![0];
    if (m![2] === undefined && m![3] === undefined) {
      const n = Number(literal);
      return Number.isSafeInteger(n) ? n : BigInt(literal);
    }
    return Number(literal);
  };
  const out = value();
  ws();
  if (i !== text.length) fail('trailing data');
  return out;
}
