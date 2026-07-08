import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// The Learn library. One markdown file per article; frontmatter carries the
// answer-shaped metadata (question title, the direct first-paragraph answer,
// and the 2-3 on-page Q&As the FAQPage JSON-LD is DERIVED from — not invented).
// The markdown body is the depth. This collection is the single source that
// drives the article pages, the Learn index, the RSS feed, llms.txt,
// llms-full.txt and sitemap.xml.
const learn = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/learn' }),
  schema: z.object({
    // The question — becomes the page's single <h1>.
    title: z.string(),
    // The direct answer — rendered as the first paragraph, before the depth.
    answer: z.string(),
    // Meta description / og:description.
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    // Ordering in the Learn index and feeds.
    order: z.number(),
    tags: z.array(z.string()).default([]),
    // On-page Q&A. Rendered visibly AND emitted as FAQPage JSON-LD, so the
    // structured data always reflects real page content.
    faqs: z
      .array(z.object({ question: z.string(), answer: z.string() }))
      .min(2),
  }),
});

export const collections = { learn };
