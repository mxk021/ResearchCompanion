/* The delimiter layer emits trusted KaTeX output, with the original source as
 * a local fallback. markdown-it remains responsible for all Markdown parsing. */
(function (root) {
  'use strict';

  const delimiters = [
    { open: '$$', close: '$$', display: true },
    { open: '\\[', close: '\\]', display: true },
    { open: '\\(', close: '\\)', display: false },
    { open: '$', close: '$', display: false }
  ];

  function escaped(text, position) {
    let backslashes = 0;
    for (let index = position - 1; text[index] === '\\'; index--) backslashes++;
    return backslashes % 2 === 1;
  }

  function inlineMath(state, silent) {
    const start = state.pos;
    const source = state.src;
    const delimiter = delimiters.find(item => source.startsWith(item.open, start));
    if (!delimiter || escaped(source, start)) return false;
    const contentStart = start + delimiter.open.length;
    const dollar = delimiter.open === '$';
    if (dollar && (!source[contentStart] || /\s/u.test(source[contentStart]))) return false;
    let end = source.indexOf(delimiter.close, contentStart);
    const lineEnd = source.indexOf('\n', contentStart);
    while (end >= 0 && end < state.posMax && escaped(source, end)) {
      end = source.indexOf(delimiter.close, end + delimiter.close.length);
    }
    if (end < 0 || end >= state.posMax || (!delimiter.display && lineEnd >= 0 && end > lineEnd)) {
      if (delimiter.open[0] !== '\\') return false;
      if (!silent) state.push('math_literal', '', 0).content = delimiter.open;
      state.pos = contentStart; // markdown-it must not consume the literal backslash.
      return true;
    }
    if (end === contentStart || (dollar && (/\s/u.test(source[end - 1]) || /[\d$]/u.test(source[end + 1] || '')))) return false;
    const body = source.slice(contentStart, end);
    // `$5 and $10` is not math. Exclude prose after a currency amount while
    // retaining numeric expressions, including `$2 x + 3$` and `$2$`.
    if (dollar && (body.includes('`') || /^\d+(?:[.,]\d+)*[\s,.;:，。；：、]*[\p{L}\s]{2,}$/u.test(body))) return false;
    const stop = end + delimiter.close.length;
    if (!silent) {
      const token = state.push('math_inline', '', 0);
      token.content = body;
      token.meta = { display: delimiter.display, raw: source.slice(start, stop) };
    }
    state.pos = stop;
    return true;
  }

  function blockMath(state, startLine, endLine, silent) {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    function lineAt(line) {
      return state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
    }
    const first = lineAt(startLine);
    const delimiter = delimiters.find(item => item.display && first.startsWith(item.open));
    if (!delimiter) return false;
    const joined = [];
    const body = [];
    let length = 0;
    for (let line = startLine; line < endLine; line++) {
      if (line > startLine && !state.isEmpty(line) && state.sCount[line] < state.blkIndent) return false;
      const raw = lineAt(line);
      joined.push(raw);
      length += raw.length + 1;
      if (length > 9000) return false;
      const text = line === startLine ? raw.slice(delimiter.open.length) : raw;
      const trimmed = text.trimEnd();
      const closeAt = trimmed.length - delimiter.close.length;
      if (closeAt >= 0 && trimmed.endsWith(delimiter.close) && !escaped(trimmed, closeAt)) {
        body.push(trimmed.slice(0, closeAt));
        if (!body.join('\n').trim()) return false;
        if (!silent) {
          const token = state.push('math_block', '', 0);
          token.block = true;
          token.map = [startLine, line + 1];
          token.content = body.join('\n');
          token.meta = { display: true, raw: joined.join('\n') };
        }
        state.line = line + 1;
        return true;
      }
      body.push(text);
    }
    return false;
  }

  function create(markdownIt, katex) {
    const md = markdownIt({ html: false, linkify: false });
    const escape = md.utils.escapeHtml;
    md.inline.ruler.before('escape', 'research_math', inlineMath);
    md.block.ruler.before('fence', 'research_math', blockMath, { alt: ['paragraph', 'blockquote', 'list'] });
    // Output stays text even for explicitly linked images, including remote
    // tracking images in model output.
    md.renderer.rules.image = (tokens, index) => escape(tokens[index].content);
    md.validateLink = url => /^https?:\/\//iu.test(url);
    md.renderer.rules.math_literal = (tokens, index) => escape(tokens[index].content);

    function renderMath(tokens, index) {
      const { content, meta } = tokens[index];
      const escapedText = escape(content);
      let rendered;
      try {
        if (content.length > 8000) throw new RangeError();
        rendered = katex.renderToString(content, {
          displayMode: meta.display, output: 'htmlAndMathml', throwOnError: true,
          trust: false, strict: 'warn', maxExpand: 200, maxSize: 12
        });
      } catch (_) {
        rendered = `<code class="math-fallback">${escape(meta.raw)}</code>`;
      }
      const tag = meta.display ? 'div' : 'span';
      // KaTeX's generated math never receives arbitrary HTML or a URL. Escape
      // the attribute independently because it stores the verbatim formula.
      return `<${tag} class="math ${meta.display ? 'math-display' : 'math-inline'}" data-latex="${escapedText}" data-markdown="${escape(meta.raw)}">${rendered}</${tag}>`;
    }

    md.renderer.rules.math_inline = renderMath;
    md.renderer.rules.math_block = renderMath;
    return md;
  }

  if (typeof module !== 'undefined') module.exports = { create };
  else root.createResearchMarkdown = create;
})(globalThis);
