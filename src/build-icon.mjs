/**
 * 生成 assets/dsh.ico —— DeepSeek Harness 桌面图标。
 *
 * 素材：DSH 自带 Web UI 的 favicon（DeepSeek 鲸鱼标），位于
 *   <dsh 安装目录>/node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg
 * 版权与出处见 README「来源与致谢」。这里把鲸鱼重新着色为白色，居中放在
 * DSH 深色品牌底色（--dsw-static-neutral-bluish-1000，即 #0F1115）的圆角方块上，
 * 这样在浅色和深色壁纸下都看得清。
 *
 * 64px 及以下写成传统 32bpp DIB 条目（所有 Windows shell 代码路径都认），
 * 128/256 写成 PNG 压缩条目。
 *
 * 用法：
 *   node src/build-icon.mjs [输出目录]        # 默认输出到 assets/
 *   DSH_FAVICON=<路径> node src/build-icon.mjs
 * 依赖 sharp（DSH 自带；没有的话 npm i sharp）。
 */
import { createRequire } from 'node:module'
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const OUT_DIR = process.argv[2] ?? join(HERE, '..', 'assets')
const FAVICON_REL = join('@deepseek-ai', 'dsh-web-frontend', 'dist', 'favicon.svg')

const TILE_FILL = '#0F1115' // DSH 深色品牌底色 --dsw-static-neutral-bluish-1000
const WHALE_FILL = '#FFFFFF'
const CANVAS = 1024
const WHALE_RATIO = 0.58
const DIB_SIZES = [16, 24, 32, 48, 64]
const PNG_SIZES = [128, 256]

/** 可能装着 @deepseek-ai/dsh 的 node_modules 目录。 */
function moduleRoots() {
  const roots = []
  const add = (p) => {
    if (p && existsSync(p)) roots.push(p)
  }
  const npx = process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, 'npm-cache', '_npx')
  if (npx && existsSync(npx)) {
    for (const entry of readdirSync(npx)) add(join(npx, entry, 'node_modules'))
  }
  add(process.env.APPDATA && join(process.env.APPDATA, 'npm', 'node_modules'))
  add(process.env.ProgramFiles && join(process.env.ProgramFiles, 'nodejs', 'node_modules'))
  return roots
}

function findFavicon(roots) {
  if (process.env.DSH_FAVICON) {
    if (!existsSync(process.env.DSH_FAVICON)) throw new Error(`DSH_FAVICON 不存在：${process.env.DSH_FAVICON}`)
    return process.env.DSH_FAVICON
  }
  for (const root of roots) {
    const candidate = join(root, FAVICON_REL)
    if (existsSync(candidate)) return candidate
  }
  throw new Error('找不到 favicon.svg：请设置 DSH_FAVICON=<路径>（该文件在 @deepseek-ai/dsh-web-frontend/dist 下）')
}

async function loadSharp(roots) {
  try {
    return (await import('sharp')).default
  } catch {
    /* 继续从 DSH 的依赖里找 */
  }
  for (const root of roots) {
    const marker = join(root, 'sharp', 'package.json')
    if (!existsSync(marker)) continue
    try {
      return createRequire(marker)('sharp')
    } catch {
      /* 换下一个候选 */
    }
  }
  throw new Error('找不到 sharp：装一个（npm i sharp），或在能解析到 DSH 依赖的位置运行')
}

const roots = moduleRoots()
const faviconPath = findFavicon(roots)
const sharp = await loadSharp(roots)

/** 渲染 1024×1024 母版：圆角底板 + 居中的白色鲸鱼。 */
async function renderMaster() {
  const radius = Math.round(CANVAS * 0.22)
  const tile = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS}" height="${CANVAS}">`
    + `<rect width="${CANVAS}" height="${CANVAS}" rx="${radius}" ry="${radius}" fill="${TILE_FILL}"/></svg>`,
  )
  const svg = readFileSync(faviconPath, 'utf8')
  if (!svg.includes('fill="#000"')) throw new Error('favicon.svg 里没有预期的 fill="#000"，上游图形可能改过了')
  // density 让 libvips 直接把 50px 的 viewBox 光栅化到 ~1700px，而不是放大位图。
  const whale = await sharp(Buffer.from(svg.replace('fill="#000"', `fill="${WHALE_FILL}"`)), { density: 2400 })
    .resize(Math.round(CANVAS * WHALE_RATIO), Math.round(CANVAS * WHALE_RATIO), {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer()
  return sharp(tile).composite([{ input: whale, gravity: 'center' }]).png().toBuffer()
}

/** ICO 目录项（16 字节）。 */
function entry(size, offset, bytes) {
  const header = Buffer.alloc(16)
  header.writeUInt8(size >= 256 ? 0 : size, 0) // 256 用 0 表示
  header.writeUInt8(size >= 256 ? 0 : size, 1)
  header.writeUInt8(0, 2) // 调色板大小
  header.writeUInt8(0, 3) // 保留
  header.writeUInt16LE(1, 4) // 色彩平面
  header.writeUInt16LE(32, 6) // 位深
  header.writeUInt32LE(bytes.length, 8)
  header.writeUInt32LE(offset, 12)
  return header
}

/** 32bpp 自下而上的 BGRA DIB + 全不透明的 AND 掩码。 */
async function dibEntry(master, size) {
  const { data } = await sharp(master).resize(size, size, { kernel: 'lanczos3' }).ensureAlpha()
    .raw().toBuffer({ resolveWithObject: true })
  const xor = Buffer.alloc(size * size * 4)
  for (let y = 0; y < size; y += 1) {
    const src = y * size * 4
    const dst = (size - 1 - y) * size * 4
    for (let x = 0; x < size * 4; x += 4) {
      xor[dst + x] = data[src + x + 2] // B
      xor[dst + x + 1] = data[src + x + 1] // G
      xor[dst + x + 2] = data[src + x] // R
      xor[dst + x + 3] = data[src + x + 3] // A
    }
  }
  const maskStride = Math.ceil(size / 32) * 4
  const mask = Buffer.alloc(maskStride * size) // 全 0 = 交给 alpha 通道
  const info = Buffer.alloc(40)
  info.writeUInt32LE(40, 0)
  info.writeInt32LE(size, 4)
  info.writeInt32LE(size * 2, 8) // XOR + AND 两层的高度
  info.writeUInt16LE(1, 12)
  info.writeUInt16LE(32, 14)
  info.writeUInt32LE(0, 16)
  info.writeUInt32LE(xor.length + mask.length, 20)
  return Buffer.concat([info, xor, mask])
}

const master = await renderMaster()
const images = []
for (const size of DIB_SIZES) images.push({ size, bytes: await dibEntry(master, size) })
for (const size of PNG_SIZES) {
  images.push({ size, bytes: await sharp(master).resize(size, size, { kernel: 'lanczos3' }).png({ compressionLevel: 9 }).toBuffer() })
}

const header = Buffer.alloc(6)
header.writeUInt16LE(0, 0)
header.writeUInt16LE(1, 2) // 1 = 图标
header.writeUInt16LE(images.length, 4)
let offset = 6 + images.length * 16
const directory = []
const payload = []
for (const image of images) {
  directory.push(entry(image.size, offset, image.bytes))
  payload.push(image.bytes)
  offset += image.bytes.length
}
const ico = Buffer.concat([header, ...directory, ...payload])

writeFileSync(join(OUT_DIR, 'dsh.ico'), ico)
writeFileSync(join(OUT_DIR, 'preview-256.png'), images.find((i) => i.size === 256).bytes)
console.log(`素材：${faviconPath}`)
console.log(`dsh.ico：${ico.length} 字节，${images.length} 个尺寸（${images.map((i) => i.size).join('/')}）`)
