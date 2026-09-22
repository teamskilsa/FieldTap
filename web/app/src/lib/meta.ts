// Per-page title and description. There is no SSR, so this is the whole of the app's head handling.
import { useEffect } from 'react';

export function usePageMeta(title: string, description: string): void {
  useEffect(() => {
    document.title = title;
    const tag = document.querySelector('meta[name="description"]');
    if (tag) tag.setAttribute('content', description);
  }, [title, description]);
}
