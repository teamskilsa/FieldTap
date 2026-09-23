// A file URL as a path the host understands. URL.pathname is "/C:/Users/..." on Windows, which every
// Deno file API rejects (os error 123); on POSIX it is already the path.
export function localPath(url: URL): string {
  const p = decodeURIComponent(url.pathname);
  return /^\/[A-Za-z]:\//.test(p) ? p.slice(1) : p;
}
