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
