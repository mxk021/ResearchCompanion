import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const context = vm.createContext({ console });
const root = new URL('../Resources/Transcript/', import.meta.url);
for (const relative of ['vendor/katex/katex.min.js', 'vendor/markdown-it/browser/markdown-it.umd.min.js', 'markdown.js']) {
    vm.runInContext(readFileSync(new URL(relative, root), 'utf8'), context, { filename: relative });
}
const markdown = context.createResearchMarkdown(context.markdownit, context.katex);

test('tight bold labels render after a CJK or ASCII colon without altering original Markdown', () => {
    const incomplete = '**原文的论点：';
    const complete = '**原文的论点：**梯度下降等一阶方法只利用梯度信息。';
    assert.equal(markdown.render(incomplete).trim(), '<p>**原文的论点：</p>');
    assert.equal(markdown.render(complete).trim(), '<p><strong>原文的论点：</strong>梯度下降等一阶方法只利用梯度信息。</p>');
    assert.match(markdown.render('**Proof:**见下文 *推导*。'), /<strong>Proof:<\/strong>见下文 <em>推导<\/em>/);
    assert.match(markdown.render('[**注意：**正文](https://example.net/)'), /<a href="https:\/\/example.net\/".*><strong>注意：<\/strong>正文<\/a>/);
    assert.match(markdown.render('**例：**直接使用 $x_i^2$。'), /<strong>例：<\/strong>直接使用 <span class="math math-inline"/);
    assert.equal(markdown.render(String.raw`\*\*例：\*\*正文`).trim(), '<p>**例：**正文</p>');
    assert.equal(markdown.render('`**例：**正文`').trim(), '<p><code>**例：**正文</code></p>');
    assert.match(markdown.render('```md\n**例：**正文\n```'), /<code class="language-md">\*\*例：\*\*正文/);
    assert.equal(markdown.render('**头**：**后文**').trim(), '<p><strong>头</strong>：<strong>后文</strong></p>');
    assert.equal(markdown.render('**Reason:**Details**').trim(), '<p>**Reason:<strong>Details</strong></p>');
});

test('standard headings, numbered lists and tables remain Markdown', () => {
    const html = markdown.render('# 试验\n\n1. 原文\n2. *proof*\n\n| 量 | 值 |\n| --- | --- |\n| $x_i$ | 2 |');
    assert.match(html, /<h1>试验<\/h1>/);
    assert.match(html, /<ol>\s*<li>原文<\/li>\s*<li><em>proof<\/em><\/li>/);
    assert.match(html, /<table>[\s\S]*<td><span class="math math-inline"[\s\S]*<td>2<\/td>/);
});

test('KaTeX handles four delimiters, CJK Markdown, matrix and alignment', () => {
    const source = [
        String.raw`中文 **求和** $x_i^2$，以及 \(\frac{\alpha}{\sqrt{x}}\)。`,
        '',
        String.raw`\[\begin{matrix}a&b\\c&d\end{matrix}\]`,
        '',
        '$$',
        String.raw`\begin{aligned} x&=y+z\\u&=\sum_i\int_0^1 a_i\,dt\end{aligned}`,
        '$$',
        '',
        '- 列表',
    ].join('\n');
    const html = markdown.render(source);
    assert.equal([...html.matchAll(/class="math /g)].length, 4);
    assert.equal([...html.matchAll(/class="katex(?:"|[- ])/g)].length > 4, true);
    assert.match(html, /中文 <strong>求和<\/strong>/);
    assert.match(html, /<li>列表<\/li>/);
    assert.doesNotMatch(html, /math-fallback/);
});

test('repeated formulas reuse rendering while preserving their own delimiters and mode', () => {
    let renders = 0;
    const cached = context.createResearchMarkdown(context.markdownit, {
        renderToString(...args) { renders++; return context.katex.renderToString(...args); },
    });
    const inline = cached.render(String.raw`$x^2$ and \(x^2\)`);
    assert.equal(renders, 1);
    assert.match(inline, /data-markdown="\$x\^2\$"/);
    assert.match(inline, /data-markdown="\\\(x\^2\\\)"/);
    assert.match(cached.render('$$\nx^2\n$$'), /class="math math-display"/);
    assert.equal(renders, 2);
});

test('plain money, code, incomplete and invalid formulas retain their meaning', () => {
    const incomplete = String.raw`前缀 \(\frac{1}{`;
    const code = ['付款 $5 and $10，亦可付 $999.99。内联 `$x$`。', '', '```txt', String.raw`$$x\backslash y$$`, '```'].join('\n');
    assert.match(markdown.render(incomplete), /\\\(\\frac\{1\}\{/);
    assert.doesNotMatch(markdown.render(code), /class="math /);
    assert.match(markdown.render(code), /\$5 and \$10/);
    const invalid = String.raw`先 $\unsupported{z}$ 再 $x^2$`;
    const html = markdown.render(invalid);
    assert.match(html, /math-fallback/);
    assert.match(html, /data-latex="x\^2"/);
    const reopened = String.raw`前缀 \(\frac{1}{x}\)`;
    assert.match(markdown.render(reopened), /data-latex="\\frac\{1\}\{x\}"/);
});

test('document markup and external images remain inert', () => {
    const html = markdown.render([
        '<script>alert(1)</script>',
        '![remote](https://example.net/sample.png)',
        '[blocked](javascript:alert(1))',
        '[可由用户主动打开](https://example.net)',
        String.raw`$\includegraphics{https://example.net/tracking.png}$`,
    ].join('\n\n'));
    assert.match(html, /&lt;script&gt;/);
    assert.match(html, /href="https:\/\/example\.net"/);
    assert.doesNotMatch(html, /<script|<img|href="javascript:|src="https?:/);
});
