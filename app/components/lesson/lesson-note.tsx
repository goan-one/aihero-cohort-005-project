import { useState } from "react";
import { useFetcher } from "react-router";
import { Button } from "~/components/ui/button";
import { Card, CardContent } from "~/components/ui/card";
import { Textarea } from "~/components/ui/textarea";
import { Lock, NotebookPen } from "lucide-react";
import { cn, formatRelativeTime } from "~/lib/utils";
import { noteDraftStatus, type NoteDraftStatus } from "~/modules/note-draft";

type SavedNote = { body: string; updatedAt: string } | null;

/** Styled to match the Questions & Discussion card further down the page. */
export function LessonNote({ note }: { note: SavedNote }) {
  const fetcher = useFetcher<{ ok: boolean; error?: string }>();
  const [draft, setDraft] = useState(note?.body ?? "");
  const status = noteDraftStatus(draft, note?.body ?? "");

  return (
    <Card className="mb-8">
      <CardContent className="p-6">
        <div className="mb-4 flex items-start justify-between gap-3">
          <div className="flex items-center gap-2">
            <NotebookPen className="size-5 text-primary" />
            <h2 className="text-xl font-semibold">Your notes</h2>
          </div>
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <Lock className="size-3" />
            Only you can see these
          </span>
        </div>

        <fetcher.Form method="post" className="space-y-2">
          <input type="hidden" name="intent" value="save-note" />
          <Textarea
            name="body"
            rows={4}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Jot down what stood out while you watch..."
            aria-label="Your notes"
            className="resize-y"
          />
          <NoteFooter
            note={note}
            status={status}
            isSaving={fetcher.state !== "idle"}
            error={fetcher.data?.error}
          />
        </fetcher.Form>
      </CardContent>
    </Card>
  );
}

function NoteFooter({
  note,
  status,
  isSaving,
  error,
}: {
  note: SavedNote;
  status: NoteDraftStatus;
  isSaving: boolean;
  error: string | undefined;
}) {
  return (
    <div className="flex items-center gap-3">
      <Button type="submit" size="sm" disabled={isSaving || !status.canSave}>
        {isSaving ? "Saving..." : "Save note"}
      </Button>
      <NoteState note={note} unsaved={status.unsaved} error={error} />
      <span
        className={cn(
          "ml-auto text-xs",
          status.tooLong ? "text-destructive" : "text-muted-foreground"
        )}
      >
        {status.length} / {status.max}
      </span>
    </div>
  );
}

function NoteState({
  note,
  unsaved,
  error,
}: {
  note: SavedNote;
  unsaved: boolean;
  error: string | undefined;
}) {
  if (error) return <span className="text-sm text-destructive">{error}</span>;
  if (unsaved) {
    return (
      <span className="text-xs text-muted-foreground">Unsaved changes</span>
    );
  }
  if (!note) return null;
  return (
    <span suppressHydrationWarning className="text-xs text-muted-foreground">
      Saved {formatRelativeTime(note.updatedAt)}
    </span>
  );
}
