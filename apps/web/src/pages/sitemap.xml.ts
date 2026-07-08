import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { absUrl } from '../data/site';

// Hand-generated so the canonical file is exactly /sitemap.xml and every URL is
// derived from the SAME content source as the pages — the Learn collection plus
// the known static routes. It cannot drift from what actually ships.
export const GET: APIRoute = async () => {
  const learn = await getCollection('learn');

  const staticRoutes: { path: string; lastmod: string; priority: string }[] = [
    { path: '/', lastmod: new Date().toISOString(), priority: '1.0' },
    { path: '/learn', lastmod: new Date().toISOString(), priority: '0.9' },
    { path: '/privacy', lastmod: '2026-07-07T00:00:00.000Z', priority: '0.4' },
    { path: '/c/example', lastmod: new Date().toISOString(), priority: '0.3' },
  ];

  const articleRoutes = learn.map((a) => ({
    path: `/learn/${a.id}`,
    lastmod: (a.data.updatedDate ?? a.data.pubDate).toISOString(),
    priority: '0.8',
  }));

  const urls = [...staticRoutes, ...articleRoutes];

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls
  .map(
    (u) => `  <url>
    <loc>${absUrl(u.path)}</loc>
    <lastmod>${u.lastmod}</lastmod>
    <priority>${u.priority}</priority>
  </url>`,
  )
  .join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
