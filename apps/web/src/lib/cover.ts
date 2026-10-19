/** Path di bucket publik campaign-covers → URL publik storage core. */
export function coverUrl(path: string | null | undefined, base = process.env.NEXT_PUBLIC_CORE_URL): string | null {
  if (!path || !base) return null;
  const clean = path.replace(/^\/+/, '').split('/').map(encodeURIComponent).join('/');
  return `${base.replace(/\/+$/, '')}/storage/v1/object/public/campaign-covers/${clean}`;
}
