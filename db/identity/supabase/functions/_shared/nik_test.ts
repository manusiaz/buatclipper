import { assertEquals, assertThrows } from "@std/assert";
import { HttpError } from "./http.ts";
import { ageOn, assertAdultNik, normalizeNik, parseNik, todayJakarta } from "./nik.ts";

const TODAY = { y: 2026, m: 10, d: 19 };

function code(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    if (err instanceof HttpError) return err.code;
    throw err;
  }
  return "ok";
}

Deno.test("NIK: male birth date from digits 7–12 (DDMMYY)", () => {
  const n = parseNik("3171011205900001", TODAY);
  assertEquals(n.birth, { y: 1990, m: 5, d: 12 });
  assertEquals(n.female, false);
});

Deno.test("NIK: female day is DD + 40", () => {
  const n = parseNik("3171015205900002", TODAY);
  assertEquals(n.birth, { y: 1990, m: 5, d: 12 });
  assertEquals(n.female, true);
  assertEquals(parseNik("3171017112990003", TODAY).birth, { y: 1999, m: 12, d: 31 });
});

Deno.test("NIK: normalizes spaces/dots/dashes, rejects other input", () => {
  assertEquals(normalizeNik("3171 0112-0590.0001"), "3171011205900001");
  assertEquals(code(() => normalizeNik("317101120590000")), "invalid_nik"); // 15 digits
  assertEquals(code(() => normalizeNik("31710112059000012")), "invalid_nik"); // 17 digits
  assertEquals(code(() => normalizeNik("31710112059O0001")), "invalid_nik"); // letter O
});

Deno.test("NIK: invalid calendar dates are rejected", () => {
  for (
    const nik of [
      "3171013205900001", // day 32
      "3171010005900001", // day 00
      "3171014005900001", // female day 00 (40)
      "3171017205900001", // female day 32 (72)
      "3171011213900001", // month 13
      "3171011200900001", // month 00
      "3171013102900001", // 31 Feb
      "3171012902900001", // 29 Feb 1990 (not leap)
      "3171013104900001", // 31 Apr
      "0000001205900001", // empty region
      "3171011205900000", // serial 0000
    ]
  ) assertEquals(code(() => parseNik(nik, TODAY)), "invalid_nik", nik);
});

Deno.test("NIK: century inference uses the latest year not in the future", () => {
  assertEquals(parseNik("3171010110260001", TODAY).birth.y, 2026); // 1 Oct 2026 already passed
  assertEquals(parseNik("3171012010260001", TODAY).birth.y, 1926); // 20 Oct 2026 would be tomorrow
  assertEquals(parseNik("3171011906080001", TODAY).birth.y, 2008);
  assertEquals(parseNik("3171010101300001", TODAY).birth.y, 1930); // 2030 is in the future
  assertEquals(parseNik("3171012902000001", TODAY).birth, { y: 2000, m: 2, d: 29 }); // 2000 is leap
  assertEquals(parseNik("3171016902040001", TODAY).birth, { y: 2004, m: 2, d: 29 }); // female, leap
  assertEquals(code(() => parseNik("3171012902270001", TODAY)), "invalid_nik"); // → 1927, not leap
});

Deno.test("age: 18th birthday boundary, female, leap day", () => {
  // born 19 Oct 2008 → exactly 18 today
  assertEquals(assertAdultNik("3171011910080001", TODAY).birth, { y: 2008, m: 10, d: 19 });
  // born 20 Oct 2008 → 17 until tomorrow
  assertEquals(code(() => assertAdultNik("3171012010080001", TODAY)), "under_age");
  // female, born 20 Oct 2008 (60 = 20 + 40) → under age; 19 Oct (59) → adult
  assertEquals(code(() => assertAdultNik("3171016010080002", TODAY)), "under_age");
  assertEquals(code(() => assertAdultNik("3171015910080002", TODAY)), "ok");
  // newborn this year → under age; 1926 (99 years) → adult
  assertEquals(code(() => assertAdultNik("3171010110260001", TODAY)), "under_age");
  assertEquals(code(() => assertAdultNik("3171012010260001", TODAY)), "ok");
  // 29 Feb 2008 turns 18 on 1 Mar 2026 (non-leap)
  assertEquals(ageOn({ y: 2008, m: 2, d: 29 }, { y: 2026, m: 2, d: 28 }), 17);
  assertEquals(ageOn({ y: 2008, m: 2, d: 29 }, { y: 2026, m: 3, d: 1 }), 18);
});

Deno.test("todayJakarta: UTC+7 date boundary", () => {
  assertEquals(todayJakarta(new Date("2026-10-19T16:59:59Z")), { y: 2026, m: 10, d: 19 });
  assertEquals(todayJakarta(new Date("2026-10-19T17:00:00Z")), { y: 2026, m: 10, d: 20 });
});

Deno.test("parseNik error type", () => {
  assertThrows(() => parseNik("x", TODAY), HttpError);
});
