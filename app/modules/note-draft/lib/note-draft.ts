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
  const length = draft.length;
  const tooLong = length > max;
  const empty = draft.trim().length === 0;
  const unsaved = draft !== savedBody;
  return {
    length,
    max,
    tooLong,
    unsaved,
    canSave: unsaved && !empty && !tooLong,
  };
}
