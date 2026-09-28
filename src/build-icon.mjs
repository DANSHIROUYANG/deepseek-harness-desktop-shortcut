/**
 * 生成 assets/dsh.ico —— DeepSeek Harness 桌面图标。
 *
 * 两种素材来源：
 *   1) 默认：DSH 自带 Web UI 的 favicon（DeepSeek 鲸鱼标），重新着色为白色，衬在 DSH 深色
 *      品牌底色（--dsw-static-neutral-bluish-1000，即 #0F1115）的圆角方块上。
 *   2) --source <图片>：换成你自己的图（png / jpg / webp / svg）。图片按**等比缩放、完整放入**
 *      处理，**不做任何裁切**（不会为了凑正方形切掉上边或下边），只是把四角切成圆角，
 *      想要直角加 --square。
 *
 * 64px 及以下写成传统 32bpp DIB 条目（所有 Windows shell 代码路径都认），
 * 128/256 写成 PNG 压缩条目。
 *
 * 用法：
 *   node src/build-icon.mjs                                        # 默认鲸鱼标，输出到 assets/
 *   node src/build-icon.mjs assets --source assets/icon-source.jpg
 *   node src/build-icon.mjs out --source logo.png --square
 *   DSH_FAVICON=<路径> node src/build-icon.mjs
 * 依赖 sharp（DSH 自带；没有的话 npm i sharp）。
 */
import { createRequire } from 'node:module'
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const FAVICON_REL = join('@deepseek-ai', 'dsh-web-frontend', 'dist', 'favicon.svg')

const TILE_FILL = '#0F1115' // DSH 深色品牌底色 --dsw-static-neutral-bluish-1000
const WHALE_FILL = '#FFFFFF'
const CANVAS = 1024
const WHALE_RATIO = 0.58
const CORNER_RATIO = 0.22
const DIB_SIZES = [16, 24, 32, 48, 64]
const PNG_SIZES = [128, 256]

// ---- 命令行参数 -------------------------------------------------------------
const argv = process.argv.slice(2)
let outDir = null
let sourceArg = null
let square = false
for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i]
  if (arg === '--source' || arg === '-s') sourceArg = argv[++i]
  else if (arg === '--square') square = true
  else if (arg === '--help' || arg === '-h') {
    console.log('用法：node src/build-icon.mjs [输出目录] [--source <图片>] [--square]')
    process.exit(0)
  } else if (!arg.startsWith('-') && outDir === null) outDir = arg
}
const OUT_DIR = outDir ?? join(HERE, '..', 'assets')

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
  throw new Error('找不到 favicon.svg：请设置 DSH_FAVICON=<路径>，或用 --source 指定图片')
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
const sharp = await loadSharp(roots)

/** 圆角遮罩：只切四个角，不裁掉任何内容。 */
async function rounded(input, width, height, ratio = CORNER_RATIO) {
  if (square) return input
  const radius = Math.round(Math.min(width, height) * ratio)
  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">`
    + `<rect width="${width}" height="${height}" rx="${radius}" ry="${radius}" fill="#fff"/></svg>`,
  )
  return sharp(input).ensureAlpha().composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer()
}

/** 默认素材：DSH 鲸鱼标 + 深色圆角底板。 */
async function renderWhaleTile(faviconPath) {
  const tile = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS}" height="${CANVAS}">`
    + `<rect width="${CANVAS}" height="${CANVAS}" rx="${Math.round(CANVAS * CORNER_RATIO)}" ry="${Math.round(CANVAS * CORNER_RATIO)}" fill="${TILE_FILL}"/></svg>`,
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

/** 自定义素材：等比缩放完整放入画布，绝不裁切，只处理四角。 */
async function renderFromImage(imagePath) {
  const meta = await sharp(imagePath).metadata()
  const fitted = await sharp(imagePath)
    .resize(CANVAS, CANVAS, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer()
  const master = await rounded(fitted, CANVAS, CANVAS)
  console.log(`素材：${imagePath}（原始 ${meta.width}×${meta.height}，等比缩放完整放入 ${CANVAS}×${CANVAS}，未裁切）`)
  return master
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

let master
if (sourceArg) {
  const sourcePath = resolve(sourceArg)
  if (!existsSync(sourcePath)) throw new Error(`素材不存在：${sourcePath}`)
  master = await renderFromImage(sourcePath)
} else {
  const faviconPath = findFavicon(roots)
  console.log(`素材：${faviconPath}`)
  master = await renderWhaleTile(faviconPath)
}

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
console.log(`dsh.ico：${ico.length} 字节，${images.length} 个尺寸（${images.map((i) => i.size).join('/')}）`)
