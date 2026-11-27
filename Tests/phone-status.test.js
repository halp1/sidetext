'use strict'

const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const test = require('node:test')
const vm = require('node:vm')
const { Element } = require('./dom.js')

assert.ok(process.argv[2], 'Pass the Swift test binary as the first argument')
const script = execFileSync(process.argv[2], ['--phone-status-script'], { encoding: 'utf8' })

const SECOND = 1000

// The tree Google renders, per the mw-banner and mw-information-banner templates in the
// public messagesweb bundle: mw-banner > div.banner-container > mw-error-banner[data-e2e-…]
// > div.error-banner > h2.title + div.content.
function phoneBanner() {
  const host = new Element('mw-error-banner', { 'data-e2e-phone-no-connection-banner': '' })
  const inner = host.appendChild(new Element('div', { class: 'error-banner' }))
  inner.appendChild(new Element('h2', { class: 'title' }, ' Trying to reach your phone '))
  inner.appendChild(new Element('div', { class: 'content' }, ' Check that your phone is on and connected to Wi-Fi or your mobile network. '))
  return host
}

function infoBanner(title) {
  const host = new Element('mw-information-banner')
  const inner = host.appendChild(new Element('div', { class: 'information-banner' }))
  inner.appendChild(new Element('div', { class: 'content-container' })).appendChild(new Element('h2', { class: 'title' }, title))
  return host
}

// One browsing session: sessionStorage and the clock survive page loads, the DOM and the
// script's globals do not.
function makeSession() {
  const storage = new Map()
  const session = {
    now: 0,
    posts: [],
    timers: [],
    sessionStorage: {
      getItem: key => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: key => storage.delete(key)
    }
  }
  session.load = (setup = {}) => loadPage(session, setup)
  session.advance = ms => {
    const end = session.now + ms
    for (;;) {
      session.timers.sort((a, b) => a.at - b.at || a.id - b.id)
      const next = session.timers[0]
      if (!next || next.at > end) break
      session.timers.shift()
      session.now = next.at
      next.callback()
    }
    session.now = end
  }
  return session
}

function loadPage(session, { conversations = true, online = true, banner = false } = {}) {
  session.timers.length = 0
  let timerID = 0
  const observers = []
  const document = new Element('document')
  document.nodeType = 9
  document.readyState = 'complete'
  document.documentElement = document.appendChild(new Element('html'))
  document.body = document.documentElement.appendChild(new Element('body'))
  const root = document.body.appendChild(new Element('mw-app'))
  const bannerSlot = root.appendChild(new Element('mw-banner')).appendChild(new Element('div', { class: 'banner-container' }))
  const main = root.appendChild(new Element('mw-main-container'))
  const windowListeners = new Map()
  const navigator = { onLine: online }

  const mutated = () => observers.forEach(observer => observer.callback([], observer))
  const page = {
    session,
    get posts() { return session.posts },
    showConversations() {
      const list = main.appendChild(new Element('mws-conversations-list'))
      list.appendChild(new Element('mws-conversation-list-item')).appendChild(new Element('a', { 'data-e2e-conversation': 'c1' }))
      mutated()
    },
    showBanner(element) {
      bannerSlot.children.forEach(child => { child.parentElement = null })
      bannerSlot.children = []
      if (element) bannerSlot.appendChild(element)
      mutated()
    },
    showUnableToConnect() {
      main.children.forEach(child => { child.parentElement = null })
      main.children = []
      main.appendChild(new Element('mw-unable-to-connect-container')).appendChild(new Element('h2', {}, ' Trying to reach your phone '))
      mutated()
    },
    setBrowserOnline(value) {
      navigator.onLine = value
      for (const listener of windowListeners.get(value ? 'online' : 'offline') || []) listener({ type: value ? 'online' : 'offline' })
    }
  }

  const context = {
    document,
    navigator,
    sessionStorage: session.sessionStorage,
    console,
    Date: { now: () => session.now },
    setTimeout: (callback, delay = 0) => {
      const id = ++timerID
      session.timers.push({ id, at: session.now + Math.max(0, Number(delay) || 0), callback })
      return id
    },
    clearTimeout: id => {
      const index = session.timers.findIndex(timer => timer.id === id)
      if (index !== -1) session.timers.splice(index, 1)
    },
    addEventListener: (type, listener) => {
      if (!windowListeners.has(type)) windowListeners.set(type, new Set())
      windowListeners.get(type).add(listener)
    },
    MutationObserver: class {
      constructor(callback) { this.callback = callback }
      observe(target, options) {
        assert.ok(options && options.childList && options.subtree, 'Banners mount deep in the tree, so observe the subtree')
        observers.push(this)
      }
      disconnect() { observers.splice(observers.indexOf(this), 1) }
    },
    webkit: { messageHandlers: { phoneStatus: { postMessage: body => session.posts.push({ ...body, at: session.now }) } } }
  }
  context.window = context

  if (conversations) page.showConversations()
  if (banner) page.showBanner(phoneBanner())
  vm.createContext(context)
  page.inject = () => vm.runInContext(script, context, { timeout: 1000 })
  page.observerCount = () => observers.length
  page.inject()
  return page
}

const states = posts => posts.map(post => (post.online ? 'online' : 'offline'))

test('a phone banner that persists posts offline once, after the hold time', () => {
  const session = makeSession()
  const page = session.load()
  page.showBanner(phoneBanner())
  session.advance(20 * SECOND)
  assert.deepEqual(page.posts, [], 'A dozing phone recovers well inside 20 s, so nothing is posted yet')
  session.advance(10 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'])
  assert.ok(page.posts[0].at >= 25 * SECOND && page.posts[0].at <= 26 * SECOND)
  session.advance(10 * 60 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'], 'A banner that stays up is reported once')
})

test('back online follows a posted offline once the phone stays reachable', () => {
  const session = makeSession()
  const page = session.load()
  page.showBanner(phoneBanner())
  session.advance(30 * SECOND)
  page.showBanner(infoBanner('Connected'))
  session.advance(5 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'])
  session.advance(10 * SECOND)
  assert.deepEqual(states(page.posts), ['offline', 'online'])
  session.advance(10 * 60 * SECOND)
  assert.equal(page.posts.length, 2)
})

test('flapping shorter than the hold posts nothing, in either direction', () => {
  const session = makeSession()
  const page = session.load()
  for (let i = 0; i < 12; i++) {
    page.showBanner(phoneBanner())
    session.advance(15 * SECOND)
    page.showBanner(null)
    session.advance(3 * SECOND)
  }
  assert.deepEqual(page.posts, [], 'Every offline spell was under 25 s, and no online is owed')
})

test('a brief recovery while offline does not post back online, and offline is not repeated', () => {
  const session = makeSession()
  const page = session.load()
  page.showBanner(phoneBanner())
  session.advance(30 * SECOND)
  for (let i = 0; i < 6; i++) {
    page.showBanner(infoBanner('Connected'))
    session.advance(4 * SECOND)
    page.showBanner(phoneBanner())
    session.advance(40 * SECOND)
  }
  assert.deepEqual(states(page.posts), ['offline'])
})

test('a banner already on screen when the script starts still waits out the hold', () => {
  const session = makeSession()
  session.now = 5 * 60 * SECOND
  const page = session.load({ banner: true })
  session.advance(24 * SECOND)
  assert.deepEqual(page.posts, [])
  session.advance(2 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'])
})

test('a banner that clears during initial load posts nothing', () => {
  const session = makeSession()
  const page = session.load({ conversations: false })
  page.showBanner(infoBanner('Connecting'))
  session.advance(3 * SECOND)
  page.showBanner(phoneBanner())
  session.advance(8 * SECOND)
  page.showBanner(null)
  page.showConversations()
  session.advance(60 * SECOND)
  assert.deepEqual(page.posts, [])
})

test('the full-page unable-to-connect screen counts as unreachable', () => {
  const session = makeSession()
  const page = session.load()
  page.showUnableToConnect()
  session.advance(26 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'])
})

test('reloading while offline neither repeats offline nor forgets the owed online', () => {
  const session = makeSession()
  const first = session.load()
  first.showBanner(phoneBanner())
  session.advance(30 * SECOND)
  assert.deepEqual(states(session.posts), ['offline'])

  const second = session.load({ conversations: false })
  second.showBanner(phoneBanner())
  session.advance(60 * SECOND)
  second.showConversations()
  session.advance(60 * SECOND)
  assert.deepEqual(states(session.posts), ['offline'], 'The phone is still unreachable after the reload')

  const third = session.load()
  session.advance(11 * SECOND)
  assert.deepEqual(states(session.posts), ['offline', 'online'])
})

test('reloading before the hold elapses starts the hold again, with no stale timer', () => {
  const session = makeSession()
  const first = session.load()
  first.showBanner(phoneBanner())
  session.advance(20 * SECOND)
  const second = session.load()
  session.advance(60 * SECOND)
  assert.deepEqual(session.posts, [])
  second.showBanner(phoneBanner())
  session.advance(26 * SECOND)
  assert.deepEqual(states(session.posts), ['offline'])
})

test('the Mac losing its connection is not reported as the phone, and does not count as back online', () => {
  const session = makeSession()
  const page = session.load()
  page.setBrowserOnline(false)
  page.showBanner(infoBanner('No internet connection'))
  session.advance(5 * 60 * SECOND)
  assert.deepEqual(page.posts, [], 'Google swaps the phone banner for the browser-offline one')

  page.setBrowserOnline(true)
  page.showBanner(phoneBanner())
  session.advance(30 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'])

  page.setBrowserOnline(false)
  page.showBanner(infoBanner('No internet connection'))
  session.advance(5 * 60 * SECOND)
  assert.deepEqual(states(page.posts), ['offline'], 'A hidden phone banner is not proof the phone recovered')
})

test('pages without the conversation list, such as pairing, never post', () => {
  const session = makeSession()
  const page = session.load({ conversations: false })
  session.advance(10 * 60 * SECOND)
  assert.deepEqual(page.posts, [])
})

test('injecting twice into the same page keeps one observer and one report', () => {
  const session = makeSession()
  const page = session.load()
  page.inject()
  assert.equal(page.observerCount(), 1)
  page.showBanner(phoneBanner())
  session.advance(30 * SECOND)
  assert.deepEqual(states(session.posts), ['offline'])
})
