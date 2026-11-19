import { describeDraft, type NoteDraftStatus } from "./lib/note-draft";

export type { NoteDraftStatus };

/**
 * What the Note editor on the Lesson page shows for a draft: its length against the
 * limit, whether it has unsaved changes, and whether Save is allowed.
 */
export function noteDraftStatus(
  draft: string,
  savedBody: string,
  max?: number
): NoteDraftStatus {
  return describeDraft(draft, savedBody, max);
}
