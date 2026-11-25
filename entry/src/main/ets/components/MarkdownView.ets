import { Constants } from '../common/Constants';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import { MathBlock } from './MathBlock';

interface ContentBlock {
  type: 'text' | 'code' | 'heading' | 'math' | 'list' | 'quote' | 'rule' | 'table';
  lang?: string;
  level?: number;
  boxed?: boolean;
  latex?: string;
  /** 表格列数（含表头） */
  cols?: number;
  /** 表格单元格：按行优先扁平存放，前 cols 个是表头 */
  cells?: string[];
  content: string;
}

interface InlineSeg {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  math: boolean;
  boxed: boolean;
}

/** 长命令优先替换，避免 \in 把 \infty 拆坏 */
function applyTable(input: string, table: string[][]): string {
  const sorted: string[][] = table.slice();
  sorted.sort((a: string[], b: string[]): number => b[0].length - a[0].length);
  let out: string = input;
  for (let i = 0; i < sorted.length; i++) {
    out = out.split(sorted[i][0]).join(sorted[i][1]);
  }
  return out;
}

/** 把常见 LaTeX 片段转成可读 Unicode 公式，避免引入字体/网络依赖 */
function latexToText(input: string): string {
  let s: string = input;
  // 先拆行：\\ 是矩阵/分段函数的换行，必须在“控制空格 \␣”之前处理，否则两个反斜杠会被吃掉一个
  s = s.split('\\\\').join('\n').split('&').join(' ');
  // 去掉行内控制空格
  s = s.split('\\,').join(' ').split('\\;').join(' ').split('\\!').join('').split('\\ ').join(' ');
  // \text{...} / \mathrm{...}
  s = s.replace(/\\(?:text|mathrm|operatorname)\{([^{}]*)\}/g, (_m: string, p1: string) => p1);
  // \frac{a}{b} 反复剥几层
  for (let i = 0; i < 6; i++) {
    const before: string = s;
    s = s.replace(/\\frac\{([^{}]*)\}\{([^{}]*)\}/g, (_m: string, a: string, b: string) => `(${a})/(${b})`);
    if (s === before) {
      break;
    }
  }
  // \sqrt[n]{x} / \sqrt{x}
  s = s.replace(/\\sqrt\[([^{}]*)\]\{([^{}]*)\}/g, (_m: string, n: string, x: string) => `${superscript(n)}√(${x})`);
  s = s.replace(/\\sqrt\{([^{}]*)\}/g, (_m: string, x: string) => `√(${x})`);
  // 上下标
  s = s.replace(/\\left|\\right/g, '');
  s = s.replace(/\\[dt]?frac/g, '');
  // \boxed{...} 由调用方画框，这里先剥掉命令保留内容
  s = s.replace(/\\boxed\s*\{([^{}]*)\}/g, (_m: string, p1: string) => p1);
  // 重音与几何符号
  s = s.replace(/\\overline\{([^{}]*)\}/g, (_m: string, p1: string) => `${p1}\u0304`);
  s = s.replace(/\\bar\{([^{}]*)\}/g, (_m: string, p1: string) => `${p1}\u0304`);
  s = s.replace(/\\hat\{([^{}]*)\}/g, (_m: string, p1: string) => `${p1}\u0302`);
  s = s.replace(/\\tilde\{([^{}]*)\}/g, (_m: string, p1: string) => `${p1}\u0303`);
  s = s.replace(/\\vec\{([^{}]*)\}/g, (_m: string, p1: string) => `${p1}\u20D7`);
  s = s.replace(/\\binom\{([^{}]*)\}\{([^{}]*)\}/g, (_m: string, a: string, b: string) => `C(${a},${b})`);
  s = s.replace(/\\quad/g, '  ').replace(/\\qquad/g, '    ');
  s = s.replace(/\\begin\{[^{}]*\}/g, '').replace(/\\end\{[^{}]*\}/g, '');
  const sym2: string[][] = [
    ['\\angle', '∠'], ['\\hbar', 'ℏ'], ['\\ell', 'ℓ'], ['\\langle', '⟨'], ['\\rangle', '⟩'],
    ['\\lvert', '|'], ['\\rvert', '|'], ['\\Re', 'ℜ'], ['\\Im', 'ℑ'], ['\\circ', '°'],
    ['\\dots', '…'], ['\\vdots', '⋮'], ['\\ddots', '⋱'], ['\\perp', '⊥'], ['\\parallel', '∥'],
    ['\\sim', '~'], ['\\simeq', '≃'], ['\\cong', '≅'], ['\\bigcup', '⋃'], ['\\bigcap', '⋂'],
    ['\\sqrt', '√'], ['\\deg', '°'], ['\\ast', '*'], ['\\star', '⋆'],
    ['\\Rightarrow', '⇒'], ['\\Leftarrow', '⇐'], ['\\Leftrightarrow', '⇔'],
    ['\\Longrightarrow', '⟹'], ['\\Longleftarrow', '⟸'], ['\\Longleftrightarrow', '⟺'],
    ['\\rightarrow', '→'], ['\\leftarrow', '←'], ['\\leftrightarrow', '↔'],
    ['\\longrightarrow', '⟶'], ['\\longleftarrow', '⟵'], ['\\longleftrightarrow', '⟷'],
    ['\\mapsto', '↦'], ['\\implies', '⇒'], ['\\iff', '⇔'], ['\\gets', '←'],
    ['\\uparrow', '↑'], ['\\downarrow', '↓'], ['\\updownarrow', '↕'],
    ['\\nearrow', '↗'], ['\\searrow', '↘'], ['\\swarrow', '↙'], ['\\nwarrow', '↖'],
    ['\\rightleftharpoons', '⇌'], ['\\leadsto', '⇝'], ['\\hookrightarrow', '↪'],
    ['\\leq', '≤'], ['\\geq', '≥'], ['\\neq', '≠'], ['\\ne', '≠'], ['\\le', '≤'], ['\\ge', '≥'],
    ['\\approx', '≈'], ['\\equiv', '≡'], ['\\propto', '∝'], ['\\ll', '≪'], ['\\gg', '≫'],
    ['\\subset', '⊂'], ['\\supset', '⊃'], ['\\subseteq', '⊆'], ['\\supseteq', '⊇'],
    ['\\in', '∈'], ['\\notin', '∉'], ['\\ni', '∋'], ['\\emptyset', '∅'], ['\\varnothing', '∅'],
    ['\\forall', '∀'], ['\\exists', '∃'], ['\\nexists', '∄'], ['\\neg', '¬'], ['\\lnot', '¬'],
    ['\\land', '∧'], ['\\lor', '∨'], ['\\wedge', '∧'], ['\\vee', '∨'],
    ['\\oplus', '⊕'], ['\\otimes', '⊗'], ['\\odot', '⊙'], ['\\ominus', '⊖'],
    ['\\times', '×'], ['\\div', '÷'], ['\\cdot', '·'], ['\\pm', '±'], ['\\mp', '∓'],
    ['\\infty', '∞'], ['\\sum', '∑'], ['\\prod', '∏'], ['\\coprod', '∐'], ['\\int', '∫'],
    ['\\iint', '∬'], ['\\iiint', '∭'], ['\\oint', '∮'], ['\\partial', '∂'], ['\\nabla', '∇'],
    ['\\therefore', '∴'], ['\\because', '∵'], ['\\triangle', '△'], ['\\square', '□'],
    ['\\diamond', '◇'], ['\\bullet', '•'], ['\\prime', '′'], ['\\degree', '°'],
    ['\\ldots', '…'], ['\\cdots', '⋯'], ['\\dotsb', '⋯'], ['\\dotsc', '…'],
    ['\\aleph', 'ℵ'], ['\\wp', '℘'], ['\\imath', 'ı'], ['\\jmath', 'ȷ'],
    ['\\top', '⊤'], ['\\bot', '⊥'], ['\\mid', '|'], ['\\backslash', '\\'],
    ['\\quad', '  '], ['\\qquad', '    ']
  ];
  s = applyTable(s, sym2);
  // 希腊字母与运算符
  const greek: string[] = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta',
    'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'rho', 'sigma', 'tau', 'upsilon',
    'phi', 'chi', 'psi', 'omega'];
  const greekOut: string[] = ['α', 'β', 'γ', 'δ', 'ε', 'ζ', 'η', 'θ', 'ι', 'κ', 'λ', 'μ',
    'ν', 'ξ', 'π', 'ρ', 'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω'];
  for (let i = 0; i < greek.length; i++) {
    s = s.split(`\\${greek[i]}`).join(greekOut[i]);
  }
  s = s.split('\\Gamma').join('Γ').split('\\Delta').join('Δ').split('\\Theta').join('Θ')
    .split('\\Lambda').join('Λ').split('\\Xi').join('Ξ').split('\\Pi').join('Π')
    .split('\\Sigma').join('Σ').split('\\Phi').join('Φ').split('\\Psi').join('Ψ')
    .split('\\Omega').join('Ω');
  const sym: string[][] = [
    ['\\times', '×'], ['\\div', '÷'], ['\\cdot', '·'], ['\\pm', '±'], ['\\mp', '∓'],
    ['\\leq', '≤'], ['\\geq', '≥'], ['\\neq', '≠'], ['\\approx', '≈'], ['\\equiv', '≡'],
    ['\\infty', '∞'], ['\\sum', '∑'], ['\\prod', '∏'], ['\\int', '∫'], ['\\partial', '∂'],
    ['\\nabla', '∇'], ['\\to', '→'], ['\\rightarrow', '→'], ['\\leftarrow', '←'],
    ['\\in', '∈'], ['\\notin', '∉'], ['\\subset', '⊂'], ['\\cup', '∪'], ['\\cap', '∩'],
    ['\\forall', '∀'], ['\\exists', '∃'], ['\\propto', '∝'], ['\\degree', '°'],
    ['\\prime', '′'], ['\\ldots', '…'], ['\\cdots', '⋯'], ['\\because', '∵'], ['\\therefore', '∴']
  ];
  s = applyTable(s, sym);
  // 上标 ^{...}，下标 _{...} 与单字符形式
  s = s.replace(/\^\{([^{}]*)\}/g, (_m: string, p1: string) => superscript(p1));
  s = s.replace(/_\{([^{}]*)\}/g, (_m: string, p1: string) => subscript(p1));
  s = s.replace(/\^([A-Za-z0-9+\-])/g, (_m: string, p1: string) => superscript(p1));
  s = s.replace(/_([A-Za-z0-9+\-])/g, (_m: string, p1: string) => subscript(p1));
  // 剩下的控制序列去掉反斜杠，保留可读部分
  s = s.replace(/\\([A-Za-z]+)/g, (_m: string, p1: string) => p1);
  s = s.split('{').join('').split('}').join('');
  return s;
}

function superscript(t: string): string {
  const map: string[] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
  const extra: string[] = ['⁺', '⁻', '⁽', '⁾'];
  const letters: string[] = ['n', 'i', 'x', 'y', 'k', 't'];
  const lettersOut: string[] = ['ⁿ', 'ⁱ', 'ˣ', 'ʸ', 'ᵏ', 'ᵗ'];
  let out: string = '';
  for (let i = 0; i < t.length; i++) {
    const ch: string = t.charAt(i);
    const digit: number = ch.charCodeAt(0) - 48;
    if (digit >= 0 && digit <= 9) {
      out += map[digit];
    } else if (ch === '+') {
      out += extra[0];
    } else if (ch === '-') {
      out += extra[1];
    } else if (ch === '(') {
      out += extra[2];
    } else if (ch === ')') {
      out += extra[3];
    } else {
      let matched: boolean = false;
      for (let j = 0; j < letters.length; j++) {
        if (letters[j] === ch) {
          out += lettersOut[j];
          matched = true;
          break;
        }
      }
      if (!matched) {
        return `^(${t})`;
      }
    }
  }
  return out;
}

function subscript(t: string): string {
  const map: string[] = ['₀', '₁', '₂', '₃', '₄', '₅', '₆', '₇', '₈', '₉'];
  const extra: string[] = ['₊', '₋', '₍', '₎'];
  const letters: string[] = ['a', 'e', 'i', 'o', 'n', 'k', 'm', 'p', 't', 'x'];
  const lettersOut: string[] = ['ₐ', 'ₑ', 'ᵢ', 'ₒ', 'ₙ', 'ₖ', 'ₘ', 'ₚ', 'ₜ', 'ₓ'];
  let out: string = '';
  for (let i = 0; i < t.length; i++) {
    const ch: string = t.charAt(i);
    const digit: number = ch.charCodeAt(0) - 48;
    if (digit >= 0 && digit <= 9) {
      out += map[digit];
    } else if (ch === '+') {
      out += extra[0];
    } else if (ch === '-') {
      out += extra[1];
    } else if (ch === '(') {
      out += extra[2];
    } else if (ch === ')') {
      out += extra[3];
    } else {
      let matched: boolean = false;
      for (let j = 0; j < letters.length; j++) {
        if (letters[j] === ch) {
          out += lettersOut[j];
          matched = true;
          break;
        }
      }
      if (!matched) {
        return `_(${t})`;
      }
    }
  }
  return out;
}

@Component
export struct MarkdownView {
  @Prop rawText: string = '';
  @Prop isGenerating: boolean = false;

  /** 行内解析：粗体 / 斜体 / 行内代码 / 行内公式 $...$ */
  private parseInline(text: string): InlineSeg[] {
    const segs: InlineSeg[] = [];
    let i: number = 0;
    let plain: string = '';
    const flushPlain = () => {
      if (plain.length > 0) {
        segs.push({ text: plain, bold: false, italic: false, code: false, math: false, boxed: false });
        plain = '';
      }
    };
    while (i < text.length) {
      const ch: string = text.charAt(i);
      // 行内代码
      if (ch === '`') {
        const end: number = text.indexOf('`', i + 1);
        if (end > i) {
          flushPlain();
          segs.push({
            text: text.substring(i + 1, end),
            bold: false, italic: false, code: true, math: false, boxed: false
          });
          i = end + 1;
          continue;
        }
      }
      // 行内公式
      if (ch === '$') {
        const end: number = text.indexOf('$', i + 1);
        if (end > i + 1) {
          flushPlain();
          const raw: string = text.substring(i + 1, end);
          segs.push({
            text: latexToText(raw),
            bold: false, italic: false, code: false, math: true, boxed: raw.indexOf('\\boxed') >= 0
          });
          i = end + 1;
          continue;
        }
      }
      // 粗体
      if (ch === '*' && text.charAt(i + 1) === '*') {
        const end: number = text.indexOf('**', i + 2);
        if (end > i) {
          flushPlain();
          segs.push({
            text: text.substring(i + 2, end),
            bold: true, italic: false, code: false, math: false, boxed: false
          });
          i = end + 2;
          continue;
        }
      }
      // 斜体
      if (ch === '*') {
        const end: number = text.indexOf('*', i + 1);
        if (end > i + 1) {
          flushPlain();
          segs.push({
            text: text.substring(i + 1, end),
            bold: false, italic: true, code: false, math: false, boxed: false
          });
          i = end + 1;
          continue;
        }
      }
      plain += ch;
      i++;
    }
    flushPlain();
    return segs.length > 0 ? segs : [{ text: text, bold: false, italic: false, code: false, math: false, boxed: false }];
  }

  private parseBlocks(text: string): ContentBlock[] {
    const blocks: ContentBlock[] = [];
    if (!text) {
      return blocks;
    }
    const lines: string[] = text.split('\n');
    let i: number = 0;
    let para: string[] = [];

    const flushPara = () => {
      if (para.length > 0) {
        blocks.push({ type: 'text', content: para.join('\n') });
        para = [];
      }
    };

    while (i < lines.length) {
      const line: string = lines[i];
      const trimmed: string = line.trim();

      // 代码块
      if (trimmed.startsWith('```')) {
        flushPara();
        const lang: string = trimmed.substring(3).trim();
        const body: string[] = [];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          body.push(lines[i]);
          i++;
        }
        i++;
        blocks.push({ type: 'code', lang: lang === '' ? 'text' : lang, content: body.join('\n') });
        continue;
      }

      // 块级公式 $$...$$ 或 \[...\]
      if (trimmed.startsWith('$$') || trimmed.startsWith('\\[')) {
        const closer: string = trimmed.startsWith('$$') ? '$$' : '\\]';
        const opener: string = trimmed.startsWith('$$') ? '$$' : '\\[';
        let body: string = trimmed.substring(opener.length);
        if (body.endsWith(closer) && body.length > closer.length) {
          body = body.substring(0, body.length - closer.length);
          flushPara();
          blocks.push({
            type: 'math',
            boxed: body.indexOf('\\boxed') >= 0,
            latex: body.trim(),
            content: latexToText(body.trim())
          });
          i++;
          continue;
        }
        flushPara();
        const collected: string[] = [];
        if (body.trim().length > 0) {
          collected.push(body);
        }
        i++;
        while (i < lines.length && !lines[i].trim().endsWith(closer)) {
          collected.push(lines[i]);
          i++;
        }
        if (i < lines.length) {
          const last: string = lines[i].trim();
          collected.push(last.substring(0, last.length - closer.length));
          i++;
        }
        const rawBody: string = collected.join('\n').trim();
        blocks.push({
          type: 'math',
          boxed: rawBody.indexOf('\\boxed') >= 0,
          latex: rawBody,
          content: latexToText(rawBody)
        });
        continue;
      }

      // 表格：表头行 + |---| 分隔行 + 数据行
      if (trimmed.startsWith('|') && i + 1 < lines.length && this.isTableSeparator(lines[i + 1].trim())) {
        flushPara();
        const header: string[] = this.splitTableRow(trimmed);
        const cols: number = Math.max(1, header.length);
        const cells: string[] = [];
        for (let c = 0; c < cols; c++) {
          cells.push(c < header.length ? header[c] : '');
        }
        i += 2;
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          const row: string[] = this.splitTableRow(lines[i].trim());
          for (let c = 0; c < cols; c++) {
            cells.push(c < row.length ? row[c] : '');
          }
          i++;
        }
        blocks.push({ type: 'table', cols: cols, cells: cells, content: '' });
        continue;
      }

      // 标题
      if (trimmed.startsWith('#')) {
        flushPara();
        let level: number = 0;
        while (level < trimmed.length && trimmed.charAt(level) === '#') {
          level++;
        }
        const title: string = trimmed.substring(level).trim();
        blocks.push({ type: 'heading', level: level, content: title });
        i++;
        continue;
      }

      // 分割线
      if (trimmed === '---' || trimmed === '***' || trimmed === '___') {
        flushPara();
        blocks.push({ type: 'rule', content: '' });
        i++;
        continue;
      }

      // 引用
      if (trimmed.startsWith('>')) {
        flushPara();
        const quoteLines: string[] = [];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quoteLines.push(lines[i].trim().substring(1).trim());
          i++;
        }
        blocks.push({ type: 'quote', content: quoteLines.join('\n') });
        continue;
      }

      // 列表项（- / * / 1. 2.）
      const listMatch: RegExpMatchArray | null = trimmed.match(/^([-*]|\d+\.)\s+(.*)$/);
      if (listMatch !== null) {
        flushPara();
        const items: string[] = [];
        while (i < lines.length) {
          const t: string = lines[i].trim();
          const m: RegExpMatchArray | null = t.match(/^([-*]|\d+\.)\s+(.*)$/);
          if (m === null) {
            break;
          }
          items.push(m[2]);
          i++;
        }
        blocks.push({ type: 'list', content: items.join('\n') });
        continue;
      }

      // 空行
      if (trimmed === '') {
        flushPara();
        i++;
        continue;
      }

      para.push(line);
      i++;
    }
    flushPara();
    return blocks;
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return 22;
    }
    if (level === 2) {
      return 19;
    }
    return 17;
  }

  private hasBoxed(text: string): boolean {
    return text.indexOf('\\boxed') >= 0;
  }

  /** 只由 | - : 空格组成、且至少含一个 - 的行，视为表格分隔行 */
  private isTableSeparator(line: string): boolean {
    if (line.indexOf('|') < 0 || line.indexOf('-') < 0) {
      return false;
    }
    const stripped: string = line.replace(/[|:\-\s]/g, '');
    return stripped.length === 0;
  }

  private splitTableRow(line: string): string[] {
    let t: string = line.trim();
    if (t.startsWith('|')) {
      t = t.substring(1);
    }
    if (t.endsWith('|')) {
      t = t.substring(0, t.length - 1);
    }
    const parts: string[] = t.split('|');
    const out: string[] = [];
    for (let k = 0; k < parts.length; k++) {
      out.push(parts[k].trim());
    }
    return out;
  }

  /** 表格数据行序号（不含表头） */
  private tableDataRows(block: ContentBlock): number[] {
    const cols: number = block.cols !== undefined ? block.cols : 1;
    const cells: string[] = block.cells !== undefined ? block.cells : [];
    const total: number = Math.floor(cells.length / cols);
    const rows: number[] = [];
    for (let r = 1; r < total; r++) {
      rows.push(r);
    }
    return rows;
  }

  private tableCell(block: ContentBlock, row: number, col: number): string {
    const cols: number = block.cols !== undefined ? block.cols : 1;
    const cells: string[] = block.cells !== undefined ? block.cells : [];
    const idx: number = row * cols + col;
    return idx >= 0 && idx < cells.length ? cells[idx] : '';
  }

  /** 列序号 0..cols-1 */
  private tableCols(block: ContentBlock): number[] {
    const cols: number = block.cols !== undefined ? block.cols : 1;
    const out: number[] = [];
    for (let c = 0; c < cols; c++) {
      out.push(c);
    }
    return out;
  }

  @Builder
  tableCellText(text: string, header: boolean) {
    // 单元格也要走行内解析：模型常在表头/首列写 **粗体**，
    // 直接 Text(text) 会把星号原样显示出来
    Text() {
      ForEach(this.parseInline(text), (seg: InlineSeg) => {
        Span(seg.text)
          .fontSize(seg.code ? Constants.FONT_SMALL - 1 : Constants.FONT_SMALL)
          .fontWeight(seg.bold ? FontWeight.Bold : (header ? FontWeight.Medium : FontWeight.Normal))
          .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(seg.code || seg.math ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(seg.code
            ? Constants.COLOR_TEXT_TERTIARY
            : (header ? Constants.COLOR_TEXT_PRIMARY : Constants.COLOR_TEXT_SECONDARY))
      })
    }
    .lineHeight(19)
    .layoutWeight(1)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .align(Alignment.TopStart)
  }

  @Builder
  tableBlock(block: ContentBlock) {
    Column() {
      // 表头
      Row() {
        ForEach(this.tableCols(block), (c: number) => {
          this.tableCellText(this.tableCell(block, 0, c), true)
        }, (c: number) => `h${c}`)
      }
      .width('100%')
      .backgroundColor(Constants.COLOR_CARD_BG)
      .alignItems(VerticalAlign.Top)

      Divider()
        .color(Constants.COLOR_CARD_BORDER)

      ForEach(this.tableDataRows(block), (r: number) => {
        Column() {
          Row() {
            ForEach(this.tableCols(block), (c: number) => {
              this.tableCellText(this.tableCell(block, r, c), false)
            }, (c: number) => `r${r}c${c}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Divider()
            .color(Constants.COLOR_CARD_BORDER)
            .opacity(0.6)
        }
        .width('100%')
      }, (r: number) => `row${r}`)
    }
    .width('100%')
    .borderRadius(Constants.RADIUS_M)
    .border({ width: 1, color: Constants.COLOR_CARD_BORDER })
    .clip(true)
    .margin({ top: 4, bottom: 4 })
  }

  @Builder
  renderInline(text: string, size: number, color: string) {
    if (this.hasBoxed(text)) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(this.parseInline(text), (seg: InlineSeg) => {
          if (seg.boxed) {
            Text(seg.text)
              .fontSize(size + 1)
              .fontFamily('monospace')
              .fontColor(Constants.COLOR_TEXT_PRIMARY)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .border({ width: 1.5, color: Constants.COLOR_PRIMARY, radius: 6 })
              .margin({ left: 3, right: 3 })
          } else {
            Text(seg.text)
              .fontSize(seg.math ? size + 1 : (seg.code ? size - 1 : size))
              .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
              .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
              .fontFamily(seg.code || seg.math ? 'monospace' : 'HarmonyOS Sans')
              .fontColor(seg.math ? Constants.COLOR_TEXT_PRIMARY : (seg.code ? Constants.COLOR_TEXT_SECONDARY : color))
              .lineHeight(size + 9)
          }
        })
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else {
      Text() {
        ForEach(this.parseInline(text), (seg: InlineSeg) => {
          Span(seg.text)
            .fontSize(seg.math ? size + 1 : (seg.code ? size - 1 : size))
            .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontFamily(seg.code || seg.math ? 'monospace' : 'HarmonyOS Sans')
            .fontColor(seg.math ? Constants.COLOR_TEXT_PRIMARY : (seg.code ? Constants.COLOR_TEXT_SECONDARY : color))
        })
      }
      .lineHeight(size + 9)
      .width('100%')
    }
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.parseBlocks(this.rawText), (block: ContentBlock, index: number) => {
        if (block.type === 'code') {
          Column() {
            Row() {
              Text((block.lang ?? 'text').toUpperCase())
                .fontSize(Constants.FONT_BADGE)
                .fontColor('#9CA3AF')
                .fontWeight(FontWeight.Medium)

              Blank()

              Text('复制')
                .fontSize(Constants.FONT_BADGE)
                .fontColor('#9CA3AF')
                .onClick(() => {
                  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, block.content);
                  pasteboard.getSystemPasteboard().setData(data).then(() => {
                    promptAction.showToast({ message: '代码已复制' });
                  }).catch((err: Error) => {
                    promptAction.showToast({ message: `复制失败：${err.message}` });
                  });
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#1E2227')
            .borderRadius({ topLeft: Constants.RADIUS_M, topRight: Constants.RADIUS_M })

            Scroll() {
              Text(block.content)
                .fontFamily('monospace')
                .fontSize(13)
                .fontColor(Constants.COLOR_CODE_TEXT)
                .lineHeight(20)
                .padding(12)
                .width('100%')
            }
            .scrollable(ScrollDirection.Horizontal)
            .width('100%')
            .backgroundColor(Constants.COLOR_CODE_BG)
            .borderRadius({ bottomLeft: Constants.RADIUS_M, bottomRight: Constants.RADIUS_M })
          }
          .width('100%')
          .borderRadius(Constants.RADIUS_M)
          .margin({ top: 4, bottom: 4 })
        } else if (block.type === 'math') {
          if (block.boxed === true) {
            Column() {
              MathBlock({
                latex: block.latex !== undefined ? block.latex : block.content,
                fallback: block.content
              })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .border({ width: 1.2, color: Constants.COLOR_PRIMARY, radius: 8 })
          } else {
            Column() {
              MathBlock({
                latex: block.latex !== undefined ? block.latex : block.content,
                fallback: block.content
              })
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 8, bottom: 8 })
            .backgroundColor(Color.Transparent)
          }
        } else if (block.type === 'table') {
          this.tableBlock(block)
        } else if (block.type === 'heading') {
          Column() {
            this.renderInline(block.content, this.headingSize(block.level ?? 3), Constants.COLOR_TEXT_PRIMARY)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 6, bottom: 2 })
        } else if (block.type === 'rule') {
          Divider()
            .color(Constants.COLOR_CARD_BORDER)
            .margin({ top: 6, bottom: 6 })
        } else if (block.type === 'quote') {
          Column() {
            this.renderInline(block.content, Constants.FONT_CAPTION + 1, Constants.COLOR_TEXT_SECONDARY)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 10, top: 6, bottom: 6 })
          .border({ width: { left: 3 }, color: { left: Constants.COLOR_PRIMARY } })
          .backgroundColor(Constants.COLOR_CARD_BG)
          .borderRadius({ topRight: Constants.RADIUS_S, bottomRight: Constants.RADIUS_S })
        } else if (block.type === 'list') {
          Column({ space: 4 }) {
            ForEach(block.content.split('\n'), (item: string) => {
              Row({ space: 6 }) {
                Text('•')
                  .fontSize(Constants.FONT_BODY)
                  .fontColor(Constants.COLOR_TEXT_TERTIARY)
                Column() {
                  this.renderInline(item, Constants.FONT_BODY, Constants.COLOR_TEXT_PRIMARY)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            })
          }
          .width('100%')
        } else {
          Row() {
            Column() {
              this.renderInline(block.content, Constants.FONT_BODY, Constants.COLOR_TEXT_PRIMARY)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .alignItems(VerticalAlign.Bottom)
          .width('100%')
        }
      })

      if (this.isGenerating) {
        Row() {
          Text('▌')
            .fontSize(Constants.FONT_BODY)
            .fontColor(Constants.COLOR_PRIMARY)
        }
        .width('100%')
        .height(10)
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
