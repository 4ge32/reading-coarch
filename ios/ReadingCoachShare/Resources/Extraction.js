/* ReadingCoach extractor v1. Article content is data, never instructions. */
(function (root) {
  "use strict";
  const blocked = new Set(["script", "style", "noscript", "iframe", "frame", "object", "embed", "form", "input", "button", "select", "textarea", "canvas", "svg", "video", "audio", "img", "nav", "footer"]);
  const allowed = { p: "paragraph", li: "listItem", blockquote: "blockquote", pre: "code", h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading", h6: "heading" };
  const extractionVersion = "readability-0.6.0/readingcoach-blocks-1";
  function safeURL(value) {
    try {
      const url = new URL(value);
      return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password ? url.href : null;
    } catch (_) { return null; }
  }
  function isBlocked(node) {
    if (node.nodeType !== 1) return false;
    const name = (node.localName || node.tagName || "").toLowerCase();
    const style = node.getAttribute("style") || "";
    return blocked.has(name) || node.hasAttribute("hidden") || node.getAttribute("aria-hidden") === "true" || /(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(style);
  }
  function textOf(node) {
    if (node.nodeType === 3) return node.textContent || node.data || "";
    if (isBlocked(node)) return "";
    if ((node.localName || "").toLowerCase() === "br") return "\n";
    const name = (node.localName || node.tagName || "").toLowerCase();
    const text = Array.from(node.childNodes || []).map(textOf).join("");
    return ["p", "div", "li", "section"].includes(name) ? text + "\n" : text;
  }
  function blocksFromDocument(document) {
    const blocks = [];
    function add(kind, text) {
      const normalized = kind === "code" ? text.replace(/\r\n?/g, "\n") : text.replace(/\s+/g, " ").trim();
      if (normalized.trim()) blocks.push({ kind, text: normalized });
    }
    function visit(node) {
      if (isBlocked(node)) return;
      const name = (node.localName || node.tagName || "").toLowerCase();
      if (allowed[name]) { add(allowed[name], textOf(node)); return; }
      // Unwrapped text (for example article text in a div) is preserved as a paragraph.
      let pending = "";
      for (const child of Array.from(node.childNodes || [])) {
        if (child.nodeType === 3) { pending += textOf(child); continue; }
        if (child.nodeType !== 1) continue;
        const childName = (child.localName || child.tagName || "").toLowerCase();
        if (["span", "a", "strong", "em", "b", "i", "u", "small", "code", "br", "sup", "sub"].includes(childName)) {
          pending += textOf(child);
        } else {
          add("paragraph", pending); pending = "";
          visit(child);
        }
      }
      add("paragraph", pending);
    }
    visit(document.body || document.documentElement || document);
    if (blocks.length > 2000 || blocks.reduce((n, block) => n + block.text.length, 0) > 2000000) throw new Error("Article is too large to import.");
    return blocks;
  }
  function extract(document, url, parseHTML) {
    const sourceURL = safeURL(url);
    const fallback = { title: document.title || "Shared page", author: null, sourceURL, blocks: [], extractionVersion, status: "urlOnly" };
    try {
      const article = new root.Readability(document.cloneNode(true), { maxElemsToParse: 50000, charThreshold: 80 }).parse();
      if (!article || !article.content) return fallback;
      const blocks = blocksFromDocument(parseHTML(article.content));
      if (!blocks.length) return fallback;
      return { title: article.title || fallback.title, author: article.byline || null, sourceURL, blocks, extractionVersion, status: "extracted" };
    } catch (_) { return fallback; }
  }
  root.ReadingCoachExtraction = { safeURL, blocksFromDocument, extract, extractionVersion };
  root.ExtensionPreprocessingJS = {
    run: function (arguments_) {
      const result = extract(document, document.location.href, html => new DOMParser().parseFromString(html, "text/html"));
      arguments_.completionFunction(result);
    }
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
