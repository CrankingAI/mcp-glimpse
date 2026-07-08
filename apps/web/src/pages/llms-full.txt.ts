import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { SITE, absUrl } from '../data/site';

// llms-full.txt — the fuller variant: every Learn article inlined in full, so an
// answer engine can ingest the whole library in one fetch. The article body is
// the raw markdown from the SAME collection that renders the pages (entry.body),
// guaranteeing no drift between the HTML page and this plaintext twin.
export const GET: APIRoute = async () => {
  const articles = (await getCollection('learn')).sort(
    (a, b) => a.data.order - b.data.order,
  );

  const header = `# ${SITE.name} — full text

> ${SITE.description}

Pitch: "${SITE.tagline}." Open-source (MIT) MCP server.
Connect (hosted): ${SITE.mcpEndpoint}
Connect (stdio): uvx ${SITE.pypiPackage}
Then run: ${SITE.primaryTool}
Source: ${SITE.repo}

This file inlines every Learn article in full. The link index is at
${absUrl('/llms.txt')}.

================================================================================
`;

  const bodies = articles
    .map((a) => {
      const url = absUrl(`/learn/${a.id}`);
      const faqs = a.data.faqs
        .map((f) => `Q: ${f.question}\nA: ${f.answer.replace(/\s+/g, ' ').trim()}`)
        .join('\n\n');
      return `
# ${a.data.title}

URL: ${url}
Published: ${a.data.pubDate.toISOString().slice(0, 10)}
Tags: ${a.data.tags.join(', ')}

Answer: ${a.data.answer.replace(/\s+/g, ' ').trim()}

${a.body.trim()}

## FAQ

${faqs}

## Call to action

Connect ${SITE.mcpEndpoint} (or run \`uvx ${SITE.pypiPackage}\`) and run \`${SITE.primaryTool}\`.

================================================================================`;
    })
    .join('\n');

  return new Response(header + bodies + '\n', {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
