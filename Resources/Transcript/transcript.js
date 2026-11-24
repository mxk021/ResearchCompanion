/* One WebKit document per conversation pane.  Updates preserve stable
 * message nodes, the reader's selection and whether the reader follows. */
(() => {
  'use strict';

  const markdown = window.createResearchMarkdown(window.markdownit, window.katex);
  const transcript = document.getElementById('transcript');
  const messages = document.getElementById('messages');
  const latest = document.getElementById('latest');
  const formulaActions = document.getElementById('formula-actions');
  const formulaCopy = document.getElementById('copy-formula');
  const formulaSave = document.getElementById('save-formula');
  const formulaSaveOptions = document.getElementById('save-formula-options');
  const noteFeedback = document.getElementById('note-feedback');
  const noteFeedbackText = document.getElementById('note-feedback-text');
  const revealNote = document.getElementById('reveal-note');
  const dismissNoteFeedback = document.getElementById('dismiss-note-feedback');
  const empty = document.getElementById('empty');
  const rows = new Map();
  const rowByArticle = new WeakMap();
  const deferredRows = new Set();
  let order = [];
  let session = null;
  let jump = null;
  let following = true;
  let scheduled = false;
  let lastY = window.scrollY;
  let layoutDeferred = false;
  let activeFormula;
  let openMore;
  let noteRevealID = '';

  function noteSaved(text, noteSession, revealID) {
    if (noteSession !== session) return;
    noteFeedbackText.textContent = text;
    noteFeedback.hidden = !text;
    noteRevealID = text && typeof revealID === 'string' ? revealID : '';
    revealNote.hidden = !noteRevealID;
  }

  const post = data => window.webkit?.messageHandlers.researchTranscript?.postMessage(data);
  revealNote.addEventListener('click', () => {
    if (noteRevealID) post({ noteRevealID, session });
  });
  dismissNoteFeedback.addEventListener('click', () => noteSaved('', session, ''));
  const nearBottom = () => document.documentElement.scrollHeight - (window.scrollY + window.innerHeight) <= 22;

  function setFollowing(value) {
    following = value;
    latest.hidden = value;
  }

  function moveToLatest() {
    if (!following || scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      if (!following) return;
      window.scrollTo(0, document.documentElement.scrollHeight);
      lastY = window.scrollY;
    });
  }

  latest.addEventListener('click', () => { setFollowing(true); moveToLatest(); });
  window.addEventListener('scroll', () => {
    const now = window.scrollY;
    if (nearBottom()) setFollowing(true);
    else if (now < lastY - 1) setFollowing(false);
    lastY = now;
  }, { passive: true });
  window.addEventListener('wheel', event => {
    if (event.deltaY < -1 && Math.abs(event.deltaY) > Math.abs(event.deltaX)
        && document.documentElement.scrollHeight > window.innerHeight + 3) setFollowing(false);
  }, { passive: true });
  const layoutObserver = new ResizeObserver(moveToLatest);
  layoutObserver.observe(transcript);
  window.addEventListener('resize', moveToLatest);
  if (document.fonts) {
    document.fonts.ready.then(moveToLatest);
    document.fonts.addEventListener('loadingdone', moveToLatest);
  }

  function containsSelection(element) {
    const selection = window.getSelection();
    return Boolean(selection && !selection.isCollapsed &&
      (element.contains(selection.anchorNode) || element.contains(selection.focusNode)));
  }

  function selectedMarkdown(body, allowBoundary = false) {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return undefined;
    const range = selection.getRangeAt(0).cloneRange();
    if (!body.contains(range.startContainer) || !body.contains(range.endContainer)) {
      if (!allowBoundary || !range.intersectsNode(body)) return undefined;
      // A triple-click on the last formula can place a boundary just outside
      // the body. The caller has already excluded cross-message selections.
      if (!body.contains(range.startContainer)) range.setStart(body, 0);
      if (!body.contains(range.endContainer)) range.setEnd(body, body.childNodes.length);
    }
    for (const formula of body.querySelectorAll('.math[data-markdown]')) {
      if (formula.contains(range.startContainer)) range.setStartBefore(formula);
      if (formula.contains(range.endContainer)) range.setEndAfter(formula);
    }
    function read(node) {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent;
      if (node.nodeName === 'BR') return '\n';
      if (node.matches?.('.math[data-markdown]')) {
        return node.matches('.math-display') ? '\n\n' + node.dataset.markdown + '\n\n' : node.dataset.markdown;
      }
      const contents = Array.from(node.childNodes, read).join('');
      return /^(P|LI|PRE|BLOCKQUOTE|H[1-6]|TR)$/u.test(node.nodeName) ? contents + '\n\n' : contents;
    }
    return read(range.cloneContents()).trim() || undefined;
  }

  let readingFeedbackTimer;

  function readingFeedback(text) {
    const status = document.getElementById('reading-feedback');
    clearTimeout(readingFeedbackTimer);
    status.textContent = text;
    status.hidden = false;
    readingFeedbackTimer = setTimeout(() => { status.hidden = true; }, 4200);
  }

  function isAnswer(record) {
    return record?.desired?.role === 'assistant' && !record.desired.streaming &&
      rows.get(record.id) === record && order.includes(record.id);
  }

  function answerWithSelection(selection) {
    const range = selection.getRangeAt(0);
    function containingBody(node) {
      const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      const record = rowByArticle.get(element?.closest('article'));
      return record?.body.contains(node) ? record : undefined;
    }
    const start = containingBody(range.startContainer);
    const end = containingBody(range.endContainer);
    if (start && end) return start === end && isAnswer(start) ? start : undefined;
    // WebKit may place a triple-click boundary just outside the body.
    const touched = [...rows.values()].filter(record => range.intersectsNode(record.body));
    return touched.length === 1 && isAnswer(touched[0]) ? touched[0] : undefined;
  }

  function clearSelectionOutside(record) {
    const selection = window.getSelection();
    if (selection?.rangeCount && !selection.isCollapsed && (!record || answerWithSelection(selection) !== record)) {
      selection.removeAllRanges();
    }
  }

  function closeMore() {
    if (!openMore) return;
    openMore.open = false;
    openMore = undefined;
  }

  function button(className, text) {
    const control = document.createElement('button');
    control.type = 'button';
    control.className = className;
    control.textContent = text;
    return control;
  }

  function actionMenu(className, text, label) {
    const menu = document.createElement('details');
    menu.className = 'action-menu ' + className;
    const summary = document.createElement('summary');
    summary.textContent = text;
    summary.setAttribute('aria-label', label);
    summary.title = label;
    const items = document.createElement('div');
    items.className = 'action-menu-items';
    menu.append(summary, items);
    menu.addEventListener('toggle', () => {
      if (menu.open && openMore !== menu) {
        closeMore();
        openMore = menu;
      } else if (!menu.open && openMore === menu) openMore = undefined;
    });
    items.addEventListener('click', () => {
      if (items.contains(document.activeElement)) summary.focus({ preventScroll: true });
      menu.open = false;
    });
    return { menu, items };
  }

  let compact = messages.clientWidth <= 475;
  function placeCopy(record) {
    const inMenu = compact && record.article.classList.contains('settled-answer');
    const parent = inMenu ? record.moreItems : record.actions;
    if (record.copy.parentElement !== parent) {
      if (inMenu) parent.append(record.copy);
      else parent.insertBefore(record.copy, record.more);
    }
    record.more.hidden = !inMenu;
    if (!inMenu) record.more.open = false;
  }
  new ResizeObserver(([entry]) => {
    const narrow = entry.contentRect.width <= 475;
    if (compact === narrow) return;
    compact = narrow;
    for (const record of rows.values()) placeCopy(record);
  }).observe(messages);

  function createRow(row) {
    const article = document.createElement('article');
    article.className = row.role === 'user' ? 'message user' : 'message';
    const header = document.createElement('header');
    header.className = 'message-header';
    const byline = document.createElement('span');
    byline.textContent = row.role === 'user' ? '你' : '科研伙伴';
    const actions = document.createElement('div');
    actions.className = 'message-actions';
    const sourceGroup = document.createElement('div');
    sourceGroup.className = 'source-group';
    const openSource = button('answer-direct-source', '');
    const objectLabel = document.createElement('span');
    objectLabel.className = 'source-objects';
    const openMaterial = document.createElement('span');
    openMaterial.className = 'answer-material-label';
    const pageLabel = document.createElement('span');
    pageLabel.className = 'source-page';
    openSource.append(objectLabel, openMaterial, pageLabel);
    const showSource = button('answer-source', '');
    sourceGroup.append(openSource, showSource);
    const split = document.createElement('div');
    split.className = 'note-split';
    const saveNote = button('answer-note', '保存为笔记');
    saveNote.setAttribute('aria-description', '有选区时保存选中的回答内容');
    const note = actionMenu('answer-note-options', '▾', '笔记保存选项');
    const supplement = button('note-supplement', '添加补充后保存…');
    const saveAs = button('note-save-as', '另存为…');
    note.items.append(supplement, saveAs);
    split.append(saveNote, note.menu);
    const copy = button('copy-original', '复制原文');
    const overflow = actionMenu('answer-more', '更多', '更多回答操作');
    actions.append(sourceGroup, split, copy, overflow.menu);
    header.append(byline, actions);
    const body = document.createElement('div');
    body.className = 'message-body';
    const source = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = '当时发送的原文与要求';
    const original = document.createElement('pre');
    source.append(summary, original);
    article.append(header, body, source);
    const record = { id: row.id, article, body, source, original, sourceGroup, openSource, showSource,
      objectLabel, openMaterial, pageLabel, split, actions, copy, more: overflow.menu, moreItems: overflow.items,
      raw: null, originalRaw: null, blocks: null };
    rowByArticle.set(article, record);
    copy.addEventListener('click', () => post({ copyID: record.id, session }));
    openSource.addEventListener('click', () => {
      if (!openSource.hidden) post({ directSourceID: record.id, session });
    });
    showSource.addEventListener('click', () => post({ sourceID: record.id, session }));
    // Keep the selected text (and original TeX) while navigating a note menu.
    actions.addEventListener('mousedown', event => {
      if (event.target.closest('button, summary')) event.preventDefault();
    });
    for (const [control, mode] of [[saveNote, 'quick'], [supplement, 'supplement'], [saveAs, 'saveAs']]) {
      control.addEventListener('click', event => {
        if (event.detail > 1 || !isAnswer(record)) return;
        const selection = window.getSelection();
        let excerpt = '';
        if (selection?.rangeCount && !selection.isCollapsed) {
          if (answerWithSelection(selection) !== record || !(excerpt = selectedMarkdown(body, true))) {
            readingFeedback('请选择这条回答内的内容，或取消选区以保存整条回答。');
            return;
          }
        }
        post({ noteID: record.id, session, selection: excerpt, noteMode: mode });
      });
    }
    return record;
  }

  /** Parse the complete reply so references, list looseness and unfinished
   * fences keep normal Markdown semantics. The rendered nodes of the stable
   * block prefix (including KaTeX and horizontal scroll) survive each delta. */
  function renderStream(record, source) {
    const env = {};
    const tokens = markdown.parse(source, env);
    const previous = record.blocks ?? [];
    const next = [];
    const remainder = document.createDocumentFragment();
    const template = document.createElement('template');
    let start = 0;
    let nesting = 0;
    let reusable = record.blocks !== null;
    for (let index = 0; index < tokens.length; index++) {
      nesting += tokens[index].nesting;
      if (nesting !== 0 && index + 1 < tokens.length) continue;
      const group = tokens.slice(start, index + 1);
      start = index + 1;
      const signature = JSON.stringify(group);
      const original = previous[next.length];
      if (reusable && original?.signature === signature) {
        next.push(original);
        continue;
      }
      reusable = false;
      template.innerHTML = markdown.renderer.render(group, markdown.options, env);
      next.push({ signature, nodes: Array.from(template.content.childNodes) });
      remainder.append(template.content);
    }
    const keep = next.findIndex((block, index) => block !== previous[index]);
    const removed = record.blocks === null ? Array.from(record.body.childNodes)
      : previous.slice(keep < 0 ? next.length : keep).flatMap(block => block.nodes);
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed && selection.rangeCount > 0) {
      const range = selection.getRangeAt(0);
      if (removed.some(node => range.intersectsNode(node))) return false;
    }
    for (const node of removed) node.remove();
    record.body.append(remainder);
    record.blocks = next;
    return true;
  }

  const headerFields = ['role', 'streaming', 'sourceDisplay', 'sourceDetails', 'canOpenSource',
    'sourceTitle', 'sourceObjects', 'sourcePage', 'sourceWarning'];

  function updateHeader(record, row) {
    const completedAnswer = row.role === 'assistant' && !row.streaming;
    record.sourceGroup.hidden = record.split.hidden = !completedAnswer;
    record.article.classList.toggle('settled-answer', completedAnswer);
    const sourceDisplay = typeof row.sourceDisplay === 'string' ? row.sourceDisplay : '';
    const sourceDetails = typeof row.sourceDetails === 'string' ? row.sourceDetails : '';
    record.openSource.hidden = !completedAnswer || row.canOpenSource !== true || !sourceDisplay;
    record.objectLabel.hidden = !row.sourceObjects;
    record.objectLabel.textContent = row.sourceObjects ? row.sourceObjects + ' · ' : '';
    record.openMaterial.textContent = row.sourceTitle || sourceDisplay;
    record.pageLabel.textContent = row.sourcePage ? ' · ' + row.sourcePage : '';
    record.openSource.title = sourceDetails;
    record.openSource.setAttribute('aria-label', '打开原文 · ' + sourceDisplay);
    const inspect = record.openSource.hidden && sourceDisplay ? '摘录 · ' + sourceDisplay : '来源详情';
    if (row.sourceWarning) {
      record.showSource.textContent = record.openSource.hidden ? inspect + ' · 图注待核对' : '图注待核对';
      record.showSource.title = row.sourceWarning;
    } else {
      record.showSource.textContent = inspect;
      record.showSource.title = record.openSource.hidden ? sourceDetails || '查看已记录的材料信息' : '查看当时发送的原文摘录与来源信息';
    }
    placeCopy(record);
  }

  function updateRow(record, row) {
    const before = record.desired;
    if (!before || headerFields.some(key => before[key] !== row[key])) updateHeader(record, row);
    record.desired = row;
    if (record.raw !== row.text) {
      let shown = false;
      try {
        if (row.streaming || record.blocks !== null) shown = renderStream(record, row.text);
        else if (!containsSelection(record.body)) {
          record.body.innerHTML = markdown.render(row.text);
          shown = true;
        }
      } catch (_) {
        if (!containsSelection(record.body)) {
          record.body.textContent = row.text;
          record.blocks = null;
          shown = true;
        }
      }
      if (shown) record.raw = row.text;
    }
    if (!row.streaming && record.raw === row.text) record.blocks = null;
    if (record.originalRaw !== row.original && !containsSelection(record.source)) {
      record.original.textContent = row.original;
      record.source.hidden = !row.original;
      record.originalRaw = row.original;
    }
    if (record.raw !== row.text || record.originalRaw !== row.original) deferredRows.add(record);
    else deferredRows.delete(record);
  }

  function arrange() {
    const ids = new Set(order);
    layoutDeferred = false;
    for (const [id, record] of rows) {
      if (ids.has(id)) continue;
      if (containsSelection(record.article)) {
        layoutDeferred = true;
      } else {
        record.article.remove();
        deferredRows.delete(record);
        rows.delete(id);
      }
    }
    let next = messages.firstElementChild;
    for (const id of order) {
      const record = rows.get(id);
      if (!record) continue;
      if (record.article !== next && record.article.parentNode === messages && containsSelection(record.article)) {
        layoutDeferred = true;
        continue;
      }
      while (next && next !== record.article && containsSelection(next)) next = next.nextElementSibling;
      if (record.article !== next) messages.insertBefore(record.article, next);
      next = record.article.nextElementSibling;
    }
    empty.hidden = order.length > 0;
  }

  function update(patch) {
    // A stream continuation is against the last received text, including a
    // pending render held back to preserve the reader's selection. Validate
    // before changing any row so Swift can retry a rejected delta in full.
    const updates = patch.rows.map(row => {
      if (row.appendAfterUTF16 === undefined) return row;
      const before = rows.get(row.id)?.desired;
      if (session !== patch.session || !row.streaming || !before?.streaming ||
          before.text.length !== row.appendAfterUTF16) throw new Error('Stream continuation base does not match');
      return { ...row, text: before.text + row.text };
    });
    if (session !== patch.session) {
      closeMore();
      clearTimeout(readingFeedbackTimer);
      document.getElementById('reading-feedback').hidden = true;
      window.getSelection()?.removeAllRanges();
      session = patch.session;
      order = [];
      messages.replaceChildren();
      rows.clear();
      deferredRows.clear();
      layoutDeferred = false;
      formulaActions.hidden = true;
      activeFormula = undefined;
      noteSaved('', session, '');
      setFollowing(true);
    }
    if (jump !== patch.jump) {
      jump = patch.jump;
      setFollowing(true);
    }
    if (patch.order) {
      const last = rows.get(order.at(-1));
      const final = updates.find(row => row.id === patch.order.at(-1));
      // Use the same row when the live reply becomes its persisted item.
      // A final correction can differ at the same position. Delay only its
      // selected blocks, never display a second copy of that reply.
      const samePosition = order.at(-2) === patch.order.at(-2);
      if (last?.desired?.streaming && final?.role === 'assistant' && !final.streaming
          && (last.desired.text === final.text || samePosition)
          && !patch.order.includes(last.id) && !rows.has(final.id)) {
        rows.delete(last.id);
        last.id = final.id;
        rows.set(final.id, last);
      }
      order = patch.order;
    }
    for (const row of updates) {
      let record = rows.get(row.id);
      if (!record) {
        record = createRow(row);
        rows.set(row.id, record);
      }
      updateRow(record, row);
    }
    if (patch.order) arrange();

    moveToLatest();
  }

  document.addEventListener('selectionchange', () => {
    const selection = window.getSelection();
    if (selection?.rangeCount && !selection.isCollapsed) return;
    if (!layoutDeferred && deferredRows.size === 0) return;
    if (layoutDeferred) arrange();
    for (const record of deferredRows) updateRow(record, record.desired);
    moveToLatest();
  });
  document.addEventListener('focusin', event => {
    if (formulaActions.contains(event.target)) return;
    if (openMore && !openMore.contains(event.target)) closeMore();
    clearSelectionOutside(rowByArticle.get(event.target.closest('article')));
  });
  document.addEventListener('click', event => {
    if (openMore && !openMore.contains(event.target)) closeMore();
    if (!formulaActions.contains(event.target)) {
      formulaActions.hidden = true;
      if (event.detail > 0) {
        const selection = window.getSelection();
        const record = rowByArticle.get(event.target.closest('article'));
        if (!(record && selection?.rangeCount && !selection.isCollapsed && record.body.contains(event.target))) {
          clearSelectionOutside(record);
        }
      }
    }
    const link = event.target.closest('a[href]');
    if (!link) return;
    event.preventDefault();
    const href = link.getAttribute('href');
    if (/^https?:\/\//iu.test(href)) post({ openLink: href });
  });
  document.addEventListener('contextmenu', event => {
    const math = event.target.closest('.math[data-latex]');
    if (!math) return;
    event.preventDefault();
    const message = Array.from(rows.values()).find(row => row.body.contains(math));
    clearSelectionOutside(message);
    activeFormula = { message, tex: math.dataset.latex, markdown: math.dataset.markdown };
    formulaSave.hidden = formulaSaveOptions.hidden = message?.desired?.role !== 'assistant' || message.desired.streaming;
    formulaActions.hidden = false;
    formulaActions.style.left = `${Math.max(0, Math.min(event.clientX, window.innerWidth - formulaActions.offsetWidth - 4))}px`;
    formulaActions.style.top = `${Math.max(0, Math.min(event.clientY, window.innerHeight - formulaActions.offsetHeight - 4))}px`;
  });
  formulaCopy.addEventListener('click', () => {
    if (activeFormula) post({ copyTeX: activeFormula.tex });
    formulaActions.hidden = true;
  });
  formulaSave.addEventListener('click', () => {
    if (activeFormula?.message) post({ noteID: activeFormula.message.id, session, selection: activeFormula.markdown });
    formulaActions.hidden = true;
  });
  formulaSaveOptions.addEventListener('click', () => {
    if (activeFormula?.message) {
      post({ noteID: activeFormula.message.id, session, selection: activeFormula.markdown, noteMode: 'supplement' });
    }
    formulaActions.hidden = true;
  });
  window.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    formulaActions.hidden = true;
    if (!openMore) return;
    openMore.querySelector('summary').focus({ preventScroll: true });
    closeMore();
    event.preventDefault();
  });
  window.addEventListener('blur', () => {
    closeMore();
    formulaActions.hidden = true;
  });
  window.addEventListener('resize', () => {
    if (openMore && getComputedStyle(openMore).display === 'none') closeMore();
  });

  window.ResearchTranscript = Object.freeze({ update, noteSaved });
  post({ ready: true });
})();
