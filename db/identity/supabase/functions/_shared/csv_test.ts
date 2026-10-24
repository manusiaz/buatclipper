import { assertEquals } from "@std/assert";
import { csvCell, toCsv } from "./csv.ts";

Deno.test("CSV: quotes commas, quotes and newlines (RFC 4180)", () => {
  assertEquals(csvCell("plain"), "plain");
  assertEquals(csvCell("a,b"), '"a,b"');
  assertEquals(csvCell('say "hi"'), '"say ""hi"""');
  assertEquals(csvCell("line1\nline2"), '"line1\nline2"');
  assertEquals(csvCell("cr\rlf"), '"cr\rlf"');
  assertEquals(csvCell(null), "");
  assertEquals(csvCell(undefined), "");
  assertEquals(csvCell(150000), "150000");
});

Deno.test("CSV: formula injection cells are prefixed with an apostrophe", () => {
  assertEquals(csvCell('=HYPERLINK("http://x")'), '"\'=HYPERLINK(""http://x"")"');
  assertEquals(csvCell("+62812"), "'+62812");
  assertEquals(csvCell("-1+1"), "'-1+1");
  assertEquals(csvCell("@SUM(A1)"), "'@SUM(A1)");
  assertEquals(csvCell("\tcmd"), "'\tcmd");
  assertEquals(csvCell("=1,2"), '"\'=1,2"');
  assertEquals(csvCell("a=b"), "a=b");
});

Deno.test("CSV: header + rows with CRLF", () => {
  assertEquals(toCsv(["a", "b"], [["1", "x,y"], ["=2", null]]), 'a,b\r\n1,"x,y"\r\n\'=2,\r\n');
});
