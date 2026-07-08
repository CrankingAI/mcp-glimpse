import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { SITE, absUrl } from '../data/site';

// llms.txt — a curated, link-first index for LLMs, per the llmstxt.org
// convention. Generated from the same content source as the site so it can't
// drift from what's actually published.
export const GET: APIRoute = async () => {
  const articles = (await getCollection('learn')).sort(
    (a, b) => a.data.order - b.data.order,
  );

  const learnLinks = articles
    .map(
      (a) =>
        `- [${a.data.title}](${absUrl(`/learn/${a.id}`)}): ${a.data.answer.replace(/\s+/g, ' ').trim()}`,
    )
    .join('\n');

  const body = `# ${SITE.name}

> ${SITE.description}

The one-line pitch: "${SITE.tagline}." mcp-glimpse is an open-source (MIT) Model
Context Protocol server. Connect it and run \`${SITE.primaryTool}\` to see your
whole agent context: every connected server, every tool and its declared
annotations, the negotiated capabilities, and your context-window cost.

## Connect

- Hosted (Streamable HTTP): ${SITE.mcpEndpoint}
- Local (stdio): \`uvx ${SITE.pypiPackage}\`
- Then run the tool: \`${SITE.primaryTool}\`

## Learn (MCP explainers)

${learnLinks}

## Site

- [Home](${SITE.url}): pitch, live App demo, quickstart, capability matrix.
- [Learn index](${absUrl('/learn')}): all ${articles.length} explainers.
- [Privacy](${absUrl('/privacy')}): snapshots analyzed in memory, never persisted.
- [Example share card](${absUrl('/c/example')}): the "Agent Facts" card format.

## More

- Full text of every article, inlined: ${absUrl('/llms-full.txt')}
- RSS feed: ${absUrl('/feed.xml')}
- Source: ${SITE.repo}
- Contact: ${SITE.contactEmail}
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
