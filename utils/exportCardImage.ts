import html2canvas from 'html2canvas';

/**
 * Render an HTML element to a PNG and either share (mobile) or download (desktop).
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

  return new Promise<void>((resolve) => {
    canvas.toBlob(async (blob) => {
      if (!blob) { resolve(); return; }
      const file = new File([blob], filename, { type: 'image/png' });

      if (navigator.share && navigator.canShare?.({ files: [file] })) {
        try {
          await navigator.share({ files: [file], title });
        } catch {
          // User cancelled share
        }
      } else {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        a.click();
        URL.revokeObjectURL(url);
      }
      resolve();
    }, 'image/png');
  });
}
