// Canonical site constants — the single source of truth shared by pages,
// sitemap.xml, feed.xml, llms.txt and llms-full.txt. Change a value here and
// every derived surface follows; nothing hand-duplicates it.

export const SITE = {
  name: 'mcp-glimpse',
  url: 'https://www.mcpglimpse.com',
  title: 'mcp-glimpse — Point your agent at itself',
  tagline: 'Point your agent at itself',
  description:
    'mcp-glimpse is an open-source MCP server that lets any agent — and its human — see its own environment: every connected MCP server, every tool and its declared annotations, the negotiated capabilities, the context window, and the wire.',
  // The MCP endpoint host (served by Azure Container Apps behind this custom domain).
  mcpHost: 'mcp.mcpglimpse.com',
  mcpEndpoint: 'https://mcp.mcpglimpse.com/mcp',
  primaryTool: 'introspect_mcp_context',
  pypiPackage: 'mcp-glimpse',
  repo: 'https://github.com/CrankingAI/mcp-glimpse',
  contactEmail: 'codingoutloud@gmail.com',
  // A checked-in 1200x630 card. Kept generic so every page can reuse it.
  ogImage: '/og/og-default.png',
  ogImageAlt:
    'mcp-glimpse — Point your agent at itself. An open-source MCP server that shows an agent its own context.',
  locale: 'en_US',
  lang: 'en',
} as const;

export const NAV: ReadonlyArray<{ label: string; href: string }> = [
  { label: 'Home', href: '/' },
  { label: 'Learn', href: '/learn' },
  { label: 'Privacy', href: '/privacy' },
];

/** Absolute URL for a site-root-relative path. */
export function absUrl(path: string): string {
  return new URL(path, SITE.url).href;
}
