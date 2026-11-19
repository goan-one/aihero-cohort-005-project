import { MAX_NOTE_LENGTH } from "~/lib/notes";

export type NoteDraftStatus = {
  length: number;
  max: number;
  tooLong: boolean;
  /** The draft differs from the body the server last saved. */
  unsaved: boolean;
  canSave: boolean;
};

export function describeDraft(
  draft: string,
  savedBody: string,
  max: number = MAX_NOTE_LENGTH
): NoteDraftStatus {
  // The server trims before it checks the length and stores the body, so the
  // draft is judged by what Save would actually store.
  const stored = draft.trim();
  const length = stored.length;
  const tooLong = length > max;
  const empty = length === 0;
  const unsaved = stored !== savedBody;
  return {
    length,
    max,
    tooLong,
    unsaved,
    canSave: unsaved && !empty && !tooLong,
  };
}
