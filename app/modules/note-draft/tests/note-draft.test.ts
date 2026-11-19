import { describe, it, expect } from "vitest";
import { noteDraftStatus } from "../index";
import { MAX_NOTE_LENGTH } from "~/lib/notes";

describe("noteDraftStatus", () => {
  it("counts the draft against the note limit by default", () => {
    const status = noteDraftStatus("hello", "");
    expect(status.length).toBe(5);
    expect(status.max).toBe(MAX_NOTE_LENGTH);
  });

  it("allows saving a new non-empty draft", () => {
    expect(noteDraftStatus("hello", "")).toEqual({
      length: 5,
      max: MAX_NOTE_LENGTH,
      tooLong: false,
      unsaved: true,
      canSave: true,
    });
  });

  it("has nothing to save when the draft matches the saved note", () => {
    const status = noteDraftStatus("hello", "hello");
    expect(status.unsaved).toBe(false);
    expect(status.canSave).toBe(false);
  });

  it("does not allow saving a draft cleared to whitespace", () => {
    const status = noteDraftStatus("   ", "hello");
    expect(status.unsaved).toBe(true);
    expect(status.canSave).toBe(false);
  });

  it("allows a draft exactly at the limit", () => {
    const status = noteDraftStatus("abc", "", 3);
    expect(status.tooLong).toBe(false);
    expect(status.canSave).toBe(true);
  });

  it("flags and blocks a draft over the limit", () => {
    const status = noteDraftStatus("abcd", "", 3);
    expect(status.tooLong).toBe(true);
    expect(status.canSave).toBe(false);
  });

  it("has nothing to save once the server has stored the trimmed draft", () => {
    const status = noteDraftStatus("hello \n", "hello");
    expect(status.unsaved).toBe(false);
    expect(status.canSave).toBe(false);
  });

  it("does not count surrounding whitespace against the limit", () => {
    const status = noteDraftStatus("  abc  ", "", 3);
    expect(status.length).toBe(3);
    expect(status.tooLong).toBe(false);
    expect(status.canSave).toBe(true);
  });
});
