/**
 * Try navigator.share, fall back to clipboard copy.
 * Returns true if the link was copied to clipboard (for UI feedback).
 */
export async function shareOrCopyLink(title: string, url: string): Promise<boolean> {
  try {
    if (navigator.share) {
      await navigator.share({ title, url });
      return false;
    }
  } catch {
    // User cancelled native share — fall through to clipboard
  }
  try {
    await navigator.clipboard.writeText(url);
    return true;
  } catch {
    return false;
  }
}
