'use strict'

const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const test = require('node:test')
const vm = require('node:vm')
const { Element } = require('./dom.js')

const CID = '12345'
const BODY = 'Your verification code is 482913.'
assert.ok(process.argv[2], 'Pass the Swift test binary as the first argument')
const script = execFileSync(process.argv[2], ['--mark-read-script'], { encoding: 'utf8' })
assert.ok(script.trim(), 'Swift must emit the async JavaScript function body')

function makeFixture(options = {}) {
  const document = new Element('document')
  document.nodeType = 9
  document.documentElement = document.appendChild(new Element('html'))
  document.body = document.documentElement.appendChild(new Element('body'))
  document.readyState = 'complete'
  const add = (parent, tag, attributes, text) => parent.appendChild(new Element(tag, attributes, text))
  const originalURL = 'https://messages.google.com/web/u/0/conversations/54321'
  const listURL = 'https://messages.google.com/web/u/0/conversations'
  let currentURL = options.originalList ? listURL : originalURL
  document.baseURI = currentURL
  const stats = { clicks: [], hardNavigations: 0, pushes: 0, backs: 0, ticks: 0, menuClicks: 0 }
  const composer = add(document.body, 'textarea', { 'data-e2e-message-input-box': '' })
  composer.value = options.draft ? 'Unsent draft in another conversation' : ''
  document.activeElement = composer
  const makeRow = (id, body, name, readState = 'true', mode = options.snippetMode) => {
    const row = new Element('mws-conversation-list-item')
    const anchor = add(row, 'a', {
      href: `/web/u/0/conversations/${id}`,
      'data-e2e-conversation': '',
      'data-e2e-is-unread': readState,
      'aria-selected': 'false',
      role: 'option'
    })
    add(anchor, 'span', { 'data-e2e-conversation-name': '' }, name)
    const snippet = add(anchor, 'div', { 'data-e2e-conversation-snippet': '', class: 'snippet-text' })
    if (mode === 'direct') snippet.textContent = body
    else if (mode === 'split') {
      add(snippet, 'span', {}, body.slice(0, 10))
      add(snippet, 'span', {}, body.slice(10))
    } else if (mode === 'hiddenLabel') {
      add(snippet, 'span', { class: 'sr-only' }, 'Unread message ')
      add(snippet, 'span', {}, body)
      snippet._innerText = body
    } else add(add(snippet, 'mws-conversation-snippet', {}), 'span', {}, body)
    const trigger = add(row, 'button', { 'aria-haspopup': 'menu', 'data-e2e-conversation-list-item-menu': '' })
    trigger.onClick = () => { stats.menuClicks += 1 }
    return { id, row, anchor, snippet, trigger }
  }
  const target = makeRow(options.fallback ? '67890' : CID, options.body ?? BODY, options.targetName ?? 'Acme', options.alreadyRead ? 'false' : 'true')
  const original = makeRow('54321', 'Previous conversation snippet', 'Jordan', 'false')
  const unrelated = makeRow('99999', 'Unrelated unread message', 'Taylor')
  const decoy = makeRow(`${CID}6`, BODY, 'Different sender')
  const rows = [original, unrelated, decoy, target]
  if (!options.originalList) {
    original.anchor.setAttribute('aria-selected', 'true')
    original.anchor.setAttribute('data-e2e-is-selected', 'true')
    original.anchor.className = 'selected'
  }
  if (options.unknownReadState) target.anchor.removeAttribute('data-e2e-is-unread')
  if (options.legacyUnreadClass) target.anchor.className = 'unread'
  if (options.trailingSlash) target.anchor.setAttribute('href', `/web/conversations/${CID}/`)
  if (options.directIdentity) {
    target.anchor.setAttribute('data-e2e-conversation', CID)
    target.anchor.removeAttribute('href')
  }
  if (options.crossOrigin) target.anchor.setAttribute('href', `https://evil.example/web/conversations/${CID}`)
  if (options.cidPrefix) target.anchor.setAttribute('href', `/web/conversations/${CID}9`)
  if (options.ambiguousSnippet) add(target.anchor, 'div', { 'data-e2e-conversation-snippet': '' }, BODY)
  for (const entry of [original, unrelated, decoy]) document.body.appendChild(entry.row)
  if (!options.missing && !options.delayed) document.body.appendChild(target.row)
  if (options.duplicateCID || options.duplicateFallback) {
    const duplicate = makeRow(options.duplicateCID ? CID : '67891', BODY, 'Acme')
    rows.push(duplicate)
    document.body.appendChild(duplicate.row)
  }
  if (options.otherFallback) {
    const fallback = makeRow('67892', BODY, 'Acme')
    rows.push(fallback)
    document.body.appendChild(fallback.row)
  }
  const listAnchor = add(document.body, 'a', { href: listURL, 'data-e2e-back-button': '', 'aria-label': 'Back to conversations' })
  if (options.noListAnchor) listAnchor.remove()
  if (options.preexistingMenu) add(document.body, 'div', { role: 'menu' })
  const entries = ['https://messages.google.com/web/conversations', currentURL]
  let historyIndex = entries.length - 1
  const selectURL = url => {
    currentURL = new URL(url, currentURL).href
    const selectedID = new URL(currentURL).pathname.match(/\/conversations\/([^/]+)\/?$/)?.[1]
    for (const entry of rows) {
      const selected = entry.id === selectedID
      entry.anchor.setAttribute('aria-selected', String(selected))
      entry.anchor.setAttribute('data-e2e-is-selected', String(selected))
      entry.anchor.className = selected ? 'selected' : ''
      if (selected && entry !== target) entry.anchor.setAttribute('data-e2e-is-unread', 'false')
    }
  }
  const history = {
    get length() { return entries.length },
    get state() { return {} },
    back() {
      stats.backs += 1
      if (historyIndex > 0) selectURL(entries[--historyIndex])
    },
    go(delta) {
      if (delta === -1) this.back()
      else throw new Error('Only a single safe SPA back is expected')
    },
    pushState(state, title, url) {
      stats.pushes += 1
      entries.splice(historyIndex + 1)
      entries.push(new URL(url, currentURL).href)
      historyIndex += 1
      selectURL(entries[historyIndex])
    },
    replaceState(state, title, url) {
      entries[historyIndex] = new URL(url, currentURL).href
      selectURL(entries[historyIndex])
    }
  }
  const location = {
    get href() { return currentURL },
    set href(value) { stats.hardNavigations += 1
      selectURL(value)
    },
    get pathname() { return new URL(currentURL).pathname },
    get origin() { return new URL(currentURL).origin },
    get search() { return new URL(currentURL).search },
    get hash() { return new URL(currentURL).hash },
    assign(value) { this.href = value },
    replace(value) { this.href = value }
  }
  document.location = location
  for (const entry of rows) entry.anchor.onClick = () => {
    stats.clicks.push(entry.id)
    history.pushState({}, '', `/web/u/0/conversations/${entry.id}`)
  }
  listAnchor.onClick = () => {
    stats.clicks.push('list')
    history.pushState({}, '', listURL)
  }
  let logicalTime = 0
  let timerID = 0
  let postSelection = false
  const cancelled = new Set()
  const setTimeout = (callback, delay = 0, ...args) => {
    const id = ++timerID
    queueMicrotask(() => {
      if (cancelled.has(id)) return
      logicalTime += Math.max(Number(delay) || 0, 1)
      stats.ticks += 1
      if (options.delayed && stats.ticks === 2) document.body.appendChild(target.row)
      if (stats.clicks.includes(target.id) && !postSelection) {
        postSelection = true
        if (!options.neverClears) target.anchor.setAttribute('data-e2e-is-unread', 'false')
        if (options.userInput) document.dispatchEvent({ type: options.userInput, isTrusted: true })
        if (options.originalChanged) {
          original.snippet.textContent = 'New message arrived while copying the OTP'
          original.snippet._innerText = original.snippet.textContent
          original.anchor.setAttribute('data-e2e-is-unread', 'true')
        }
        if (options.originalReadChanged) original.anchor.setAttribute('data-e2e-is-unread', 'true')
      }
      assert.ok(stats.ticks < 1000, 'Generated script must use bounded waiting')
      callback(...args)
    })
    return id
  }
  class Clock extends Date {
    constructor(...args) { super(...(args.length ? args : [logicalTime])) }
    static now() { return logicalTime }
  }
  class FixtureEvent {
    constructor(type, init = {}) { this.type = type
      Object.assign(this, init)
    }
  }
  const context = {
    document, location, history, URL, console, Date: Clock,
    performance: { now: () => logicalTime },
    setTimeout, clearTimeout: id => cancelled.add(id),
    addEventListener: (...args) => document.addEventListener(...args),
    removeEventListener: (...args) => document.removeEventListener(...args),
    getComputedStyle: element => ({ ...element.style, getPropertyValue: name => element.style[name] || '' }),
    Element, HTMLElement: Element, HTMLButtonElement: Element, HTMLAnchorElement: Element,
    Node: { ELEMENT_NODE: 1 },
    Event: FixtureEvent, MouseEvent: FixtureEvent, KeyboardEvent: FixtureEvent,
    MutationObserver: class { observe() {}
      disconnect() {}
    },
    requestAnimationFrame: callback => setTimeout(callback, 16),
    cancelAnimationFrame: id => cancelled.add(id),
    CSS: { escape: value => String(value) }
  }
  context.window = context
  context.self = context
  return { context, document, target, original, unrelated, decoy, rows, composer, listAnchor, stats, originalURL: options.originalList ? listURL : originalURL, listURL }
}

async function run(options = {}) {
  const fixture = makeFixture(options)
  const result = await vm.runInNewContext(`(async function () {\n${script}\n})()`, fixture.context, { timeout: 1000 })
  fixture.status = typeof result === 'string' ? result : result && result.status
  return fixture
}

function unread(entry) { return entry.anchor.getAttribute('data-e2e-is-unread') }

function assertSafe(fixture) {
  assert.equal(fixture.stats.hardNavigations, 0, 'Never force a full page load')
  assert.equal(fixture.stats.menuClicks, 0, 'Actual Google Messages menus have no mark-read action')
  assert.equal(unread(fixture.unrelated), 'true', 'Unrelated unread state must be preserved')
  assert.equal(unread(fixture.decoy), 'true', 'CID prefixes must not be used')
  assert.equal(fixture.unrelated.anchor.clickCount, 0, 'Never open unrelated unread conversations')
  assert.equal(fixture.decoy.anchor.clickCount, 0, 'Never open a CID prefix match')
  assert.equal(fixture.original.anchor.clickCount, 0, 'Restore the route with history, not a second conversation click')
}

function assertNoSelection(fixture) {
  assertSafe(fixture)
  assert.equal(fixture.stats.clicks.length, 0)
  assert.equal(fixture.stats.backs, 0)
  assert.equal(fixture.context.location.href, fixture.originalURL)
  assert.notEqual(fixture.status, 'read')
}

function assertReadAndRestored(fixture) {
  assertSafe(fixture)
  assert.equal(fixture.status, 'read')
  assert.equal(unread(fixture.target), 'false')
  assert.deepEqual(fixture.stats.clicks, [fixture.target.id])
  assert.equal(fixture.stats.backs, 1)
  assert.equal(fixture.context.location.href, fixture.originalURL)
}

test('exact attr-only OTP row is selected, marked read, and original route restored', async () => {
  assertReadAndRestored(await run())
})

test('original list route is restored through SPA history', async () => {
  assertReadAndRestored(await run({ originalList: true }))
})

test('trusted route identity permits optional trailing slash and no account prefix', async () => {
  assertReadAndRestored(await run({ trailingSlash: true }))
})

test('direct conversation data identity works without href', async () => {
  assertReadAndRestored(await run({ directIdentity: true }))
})

for (const snippetMode of ['direct', 'split', 'hiddenLabel']) {
  test(`whole-snippet matching supports ${snippetMode} layout`, async () => {
    assertReadAndRestored(await run({ snippetMode }))
  })
}

test('whole-snippet comparison normalizes whitespace', async () => {
  assertReadAndRestored(await run({ body: ' \n Your\u00a0verification\tcode is   482913. \n' }))
})

test('missing CID falls back only to a unique exact sender and whole body', async () => {
  assertReadAndRestored(await run({ fallback: true }))
})

test('duplicate sender and whole-body fallback candidates refuse selection', async () => {
  assertNoSelection(await run({ fallback: true, duplicateFallback: true }))
})

test('duplicate trusted CID rows refuse selection', async () => {
  assertNoSelection(await run({ duplicateCID: true }))
})

test('known CID body mismatch refuses even with a unique matching sender fallback', async () => {
  assertNoSelection(await run({ body: 'Your verification code is 999999.', otherFallback: true }))
})

test('sender fallback cannot ignore newer text following the expected OTP body', async () => {
  assertNoSelection(await run({ fallback: true, body: `${BODY} Newer message follows.` }))
})

test('sender fallback cannot use the OTP body without an exact sender match', async () => {
  assertNoSelection(await run({ fallback: true, targetName: 'Not Acme' }))
})

test('sender fallback cannot use a matching sender without the exact body', async () => {
  assertNoSelection(await run({ fallback: true, body: 'Your verification code is 999999.' }))
})

test('missing row never opens a different sender with the same OTP snippet', async () => {
  assertNoSelection(await run({ missing: true }))
})

for (const option of ['cidPrefix', 'crossOrigin']) {
  test(`${option} route refuses without an eligible sender fallback`, async () => {
    assertNoSelection(await run({ [option]: true, targetName: 'Not Acme' }))
  })
}

test('unknown read state is not interpreted as already read', async () => {
  const fixture = await run({ unknownReadState: true, legacyUnreadClass: true })
  assertNoSelection(fixture)
  assert.notEqual(fixture.status, 'already-read')
})

test('authoritative false read attribute prevents selection even with stale unread class', async () => {
  const fixture = await run({ alreadyRead: true, legacyUnreadClass: true })
  assert.equal(fixture.status, 'already-read')
  assertNoSelection(fixture)
})

test('nonempty draft prevents selection and preserves text', async () => {
  const fixture = await run({ draft: true })
  assertNoSelection(fixture)
  assert.equal(fixture.composer.value, 'Unsent draft in another conversation')
})

test('an existing visible menu prevents automation from navigating', async () => {
  assertNoSelection(await run({ preexistingMenu: true }))
})

test('multiple snippet roots are ambiguous and refuse selection', async () => {
  assertNoSelection(await run({ ambiguousSnippet: true }))
})

test('delayed target row rendering is awaited', async () => {
  const fixture = await run({ delayed: true })
  assertReadAndRestored(fixture)
  assert.ok(fixture.stats.ticks >= 2)
})

for (const userInput of ['pointerdown', 'keydown']) {
  test(`real ${userInput} after selecting OTP cancels route restoration`, async () => {
    const fixture = await run({ userInput })
    assertSafe(fixture)
    assert.deepEqual(fixture.stats.clicks, [fixture.target.id])
    assert.equal(fixture.stats.backs, 0)
    assert.notEqual(fixture.context.location.href, fixture.originalURL)
    assert.equal(unread(fixture.target), 'false')
  })
}

for (const change of ['originalChanged', 'originalReadChanged']) {
  test(`${change} never reopens the original conversation and consumes new unread content`, async () => {
    const fixture = await run({ [change]: true })
    assertSafe(fixture)
    assert.equal(unread(fixture.target), 'false')
    assert.equal(unread(fixture.original), 'true')
    assert.equal(fixture.stats.backs, 0)
    assert.notEqual(fixture.context.location.href, fixture.originalURL)
    assert.ok(fixture.context.location.href === fixture.listURL || fixture.context.location.pathname.endsWith(`/${fixture.target.id}`))
    assert.ok(fixture.stats.clicks.every(id => id === fixture.target.id || id === 'list'))
  })
}

test('unsafe original-restore race can leave OTP selected when no verified list anchor exists', async () => {
  const fixture = await run({ originalChanged: true, noListAnchor: true })
  assertSafe(fixture)
  assert.equal(unread(fixture.original), 'true')
  assert.equal(fixture.stats.backs, 0)
  assert.ok(fixture.context.location.pathname.endsWith(`/${fixture.target.id}`))
})

test('anchor click without authoritative unread clear is not success', async () => {
  const fixture = await run({ neverClears: true })
  assertSafe(fixture)
  assert.deepEqual(fixture.stats.clicks, [fixture.target.id])
  assert.equal(unread(fixture.target), 'true')
  assert.notEqual(fixture.status, 'read')
  assert.notEqual(fixture.status, 'already-read')
})
