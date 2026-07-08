import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { SITE, absUrl } from '../data/site';

// RSS 2.0 feed for the Learn library — several answer engines discover fresh
// content via feeds. Built from the same collection as the pages.
function escapeXml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export const GET: APIRoute = async () => {
  const articles = (await getCollection('learn')).sort(
    (a, b) => b.data.pubDate.getTime() - a.data.pubDate.getTime(),
  );

  const items = articles
    .map((a) => {
      const link = absUrl(`/learn/${a.id}`);
      return `    <item>
      <title>${escapeXml(a.data.title)}</title>
      <link>${link}</link>
      <guid isPermaLink="true">${link}</guid>
      <pubDate>${a.data.pubDate.toUTCString()}</pubDate>
      <description>${escapeXml(a.data.answer)}</description>
      ${a.data.tags.map((t) => `<category>${escapeXml(t)}</category>`).join('\n      ')}
    </item>`;
    })
    .join('\n');

  const lastBuild = articles.length
    ? articles[0].data.pubDate.toUTCString()
    : new Date().toUTCString();

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>${escapeXml(SITE.name)} — Learn</title>
    <link>${absUrl('/learn')}</link>
    <atom:link href="${absUrl('/feed.xml')}" rel="self" type="application/rss+xml" />
    <description>Answer-shaped explainers on the Model Context Protocol from ${escapeXml(SITE.name)}.</description>
    <language>en-us</language>
    <lastBuildDate>${lastBuild}</lastBuildDate>
${items}
  </channel>
</rss>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' },
  });
};
