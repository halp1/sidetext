'use strict'

const assert = require('node:assert/strict')

// A deliberately small DOM, with selectors resolved against real parent/child
// relationships rather than a table keyed to the implementation's selectors.
function selectorParts(selector) {
  return selector.trim().replace(/\s*>\s*/g, ' > ').split(/\s+(?![^\[]*\])/)
}

function matchesSimple(element, selector) {
  if (!element || element.nodeType !== 1) return false
  let rest = selector
  const not = [...rest.matchAll(/:not\(([^)]+)\)/g)]
  rest = rest.replace(/:not\([^)]+\)/g, '')
  if (not.some(match => matchesSimple(element, match[1]))) return false
  const tag = rest.match(/^[a-zA-Z][\w-]*|^\*/)
  if (tag && tag[0] !== '*' && tag[0].toLowerCase() !== element.localName) return false
  if (tag) rest = rest.slice(tag[0].length)
  const attributes = [...rest.matchAll(/\[([^\s~|^$*!=\]]+)\s*(?:(\^=|\$=|\*=|~=|=)\s*["']?([^\]"']*)["']?)?\]/g)]
  for (const [, name, operator, expected] of attributes) {
    const actual = element.getAttribute(name)
    if (actual === null) return false
    if (!operator) continue
    if (operator === '=' && actual !== expected) return false
    if (operator === '^=' && !actual.startsWith(expected)) return false
    if (operator === '$=' && !actual.endsWith(expected)) return false
    if (operator === '*=' && !actual.includes(expected)) return false
    if (operator === '~=' && !actual.split(/\s+/).includes(expected)) return false
  }
  rest = rest.replace(/\[[^\]]*\]/g, '')
  for (const match of rest.matchAll(/\.([\w-]+)/g)) {
    if (!element.classList.contains(match[1])) return false
  }
  rest = rest.replace(/\.[\w-]+/g, '')
  const id = rest.match(/^#([\w-]+)/)
  if (id && element.id !== id[1]) return false
  if (id) rest = rest.slice(id[0].length)
  assert.equal(rest, '', `Unsupported fixture selector: ${selector}`)
  return true
}

function matchesSelector(element, selector) {
  return selector.split(',').some(branch => {
    const parts = selectorParts(branch)
    let current = element
    if (!matchesSimple(current, parts.pop())) return false
    while (parts.length) {
      const part = parts.pop()
      if (part === '>') {
        current = current.parentElement
        if (!matchesSimple(current, parts.pop())) return false
      } else {
        current = current.parentElement
        while (current && !matchesSimple(current, part)) current = current.parentElement
        if (!current) return false
      }
    }
    return true
  })
}

class Element {
  constructor(tag, attributes = {}, text = '') {
    this.nodeType = 1
    this.localName = tag.toLowerCase()
    this.tagName = tag.toUpperCase()
    this.attributes = { ...attributes }
    this.children = []
    this.parentElement = null
    this._text = text
    this.style = { display: '', visibility: 'visible', opacity: '1' }
    this.hidden = false
    this.disabled = false
    this.clickCount = 0
    this.listeners = new Map()
    this.classList = {
      contains: token => this.className.split(/\s+/).includes(token),
      add: token => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), token])].join(' ') },
      remove: token => { this.className = this.className.split(/\s+/).filter(value => value !== token).join(' ') },
      [Symbol.iterator]: () => this.className.split(/\s+/).filter(Boolean)[Symbol.iterator]()
    }
  }
  get className() { return this.getAttribute('class') || '' }
  set className(value) { this.setAttribute('class', value) }
  get id() { return this.getAttribute('id') || '' }
  get textContent() { return this._text + this.children.map(child => child.textContent).join('') }
  set textContent(value) { this._text = value }
  get innerText() { return this._innerText === undefined ? this.textContent : this._innerText }
  get href() { return new URL(this.getAttribute('href') || '', 'https://messages.google.com').href }
  get parentNode() { return this.parentElement }
  get childNodes() { return this.children }
  get isConnected() { return this === this.ownerDocument || Boolean(this.parentElement && this.parentElement.isConnected) }
  get ownerDocument() {
    let root = this
    while (root.parentElement) root = root.parentElement
    return root.nodeType === 9 ? root : null
  }
  get offsetParent() { return this.visible() ? this.parentElement : null }
  get offsetWidth() { return this.visible() ? 200 : 0 }
  get offsetHeight() { return this.visible() ? 30 : 0 }
  getAttribute(name) { return Object.hasOwn(this.attributes, name) ? String(this.attributes[name]) : null }
  hasAttribute(name) { return Object.hasOwn(this.attributes, name) }
  setAttribute(name, value) { this.attributes[name] = String(value) }
  removeAttribute(name) { delete this.attributes[name] }
  appendChild(child) {
    this.children.push(child)
    child.parentElement = this
    return child
  }
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this)
    this.parentElement = null
  }
  contains(element) { return this === element || this.children.some(child => child.contains(element)) }
  matches(selector) { return matchesSelector(this, selector) }
  closest(selector) {
    let current = this
    while (current && current.nodeType === 1) {
      if (current.matches(selector)) return current
      current = current.parentElement
    }
    return null
  }
  querySelectorAll(selector) {
    const result = []
    const visit = parent => {
      for (const child of parent.children) {
        if (matchesSelector(child, selector)) result.push(child)
        visit(child)
      }
    }
    visit(this)
    return result
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null }
  visible() {
    return !this.hidden && this.style.display !== 'none' && this.style.visibility !== 'hidden' &&
      (!this.parentElement || this.parentElement.visible())
  }
  getClientRects() { return this.visible() ? [this.getBoundingClientRect()] : [] }
  getBoundingClientRect() { return { x: 0, y: 0, top: 0, left: 0, bottom: this.offsetHeight, right: this.offsetWidth, width: this.offsetWidth, height: this.offsetHeight } }
  click() {
    this.clickCount += 1
    if (this.onClick) this.onClick()
  }
  dispatchEvent(event) {
    if (event.type === 'click') this.click()
    for (const listener of this.listeners.get(event.type) || []) listener(event)
    return true
  }
  focus() { this.ownerDocument.activeElement = this }
  scrollIntoView() {}
  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(listener)
  }
  removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener) }
}

module.exports = { Element, matchesSelector }
