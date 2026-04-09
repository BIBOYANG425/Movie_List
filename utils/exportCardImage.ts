import html2canvas from 'html2canvas';

/**
 * Render an HTML element to a PNG and either share (mobile) or download (desktop).
 *
 * Throws on real failures (canvas crash, null blob, share rejection that isn't user cancel).
 * Resolves silently when the user dismisses the native share sheet.
 */
export async function exportCardImage(
  element: HTMLElement,
  filename: string,
  title: string,
): Promise<void> {
  const canvas = await html2canvas(element, {
    backgroundColor: null,
    scale: 2,
    useCORS: true,
    logging: false,
  });

  const blob = await new Promise<Blob | null>((resolve) => {
    canvas.toBlob((b) => resolve(b), 'image/png');
  });

  if (!blob) {
    throw new Error('Failed to render card image');
  }

  const file = new File([blob], filename, { type: 'image/png' });

  if (navigator.share && navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title });
    } catch (err) {
      // AbortError = user dismissed the native share sheet — not a failure
      if (err instanceof Error && err.name === 'AbortError') return;
      throw err;
    }
    return;
  }

  // Desktop / no share API: trigger a download
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
