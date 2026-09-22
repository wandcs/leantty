export const DURABLE_ASSET_VERSION: number = 1
// Asset Store accepts up to 1024 secret bytes. Readers use the manifest's
// actual chunk count and byte length, so existing smaller chunks remain valid.
export const DURABLE_ASSET_CHUNK_BYTES: number = 1024

const SHA256_CONSTANTS: number[] = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
]

export class DurableAssetManifest {
  version: number = DURABLE_ASSET_VERSION
  path: string = ''
  generation: string = ''
  chunkCount: number = 0
  byteCount: number = 0
  sha256: string = ''
}

export class DurableAssetFormat {
  static encodeText(value: string): Uint8Array {
    let bytes: number[] = []
    for (let i = 0; i < value.length; i++) {
      let codePoint: number = value.charCodeAt(i)
      if (codePoint >= 0xD800 && codePoint <= 0xDBFF && i + 1 < value.length) {
        let low: number = value.charCodeAt(i + 1)
        if (low >= 0xDC00 && low <= 0xDFFF) {
          codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00)
          i++
        }
      }
      if (codePoint <= 0x7F) {
        bytes.push(codePoint)
      } else if (codePoint <= 0x7FF) {
        bytes.push(0xC0 | (codePoint >> 6))
        bytes.push(0x80 | (codePoint & 0x3F))
      } else if (codePoint <= 0xFFFF) {
        bytes.push(0xE0 | (codePoint >> 12))
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F))
        bytes.push(0x80 | (codePoint & 0x3F))
      } else {
        bytes.push(0xF0 | (codePoint >> 18))
        bytes.push(0x80 | ((codePoint >> 12) & 0x3F))
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F))
        bytes.push(0x80 | (codePoint & 0x3F))
      }
    }
    return new Uint8Array(bytes)
  }

  static decodeText(value: Uint8Array): string {
    let result: string = ''
    for (let i = 0; i < value.length; i++) {
      let first: number = value[i]
      let codePoint: number
      let extra: number
      if (first <= 0x7F) {
        codePoint = first
        extra = 0
      } else if ((first & 0xE0) === 0xC0) {
        codePoint = first & 0x1F
        extra = 1
      } else if ((first & 0xF0) === 0xE0) {
        codePoint = first & 0x0F
        extra = 2
      } else if ((first & 0xF8) === 0xF0) {
        codePoint = first & 0x07
        extra = 3
      } else {
        throw new Error('Invalid UTF-8 leading byte')
      }
      if (i + extra >= value.length) {
        throw new Error('Incomplete UTF-8 sequence')
      }
      for (let j = 0; j < extra; j++) {
        let next: number = value[++i]
        if ((next & 0xC0) !== 0x80) {
          throw new Error('Invalid UTF-8 continuation byte')
        }
        codePoint = (codePoint << 6) | (next & 0x3F)
      }
      if ((extra === 1 && codePoint < 0x80) || (extra === 2 && codePoint < 0x800) ||
        (extra === 3 && codePoint < 0x10000) || codePoint > 0x10FFFF ||
        (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
        throw new Error('Invalid UTF-8 code point')
      }
      if (codePoint <= 0xFFFF) {
        result += String.fromCharCode(codePoint)
      } else {
        let normalized: number = codePoint - 0x10000
        result += String.fromCharCode(0xD800 + (normalized >> 10), 0xDC00 + (normalized & 0x3FF))
      }
    }
    return result
  }

  static split(value: Uint8Array): Uint8Array[] {
    let chunks: Uint8Array[] = []
    if (value.length === 0) {
      chunks.push(new Uint8Array(0))
      return chunks
    }
    for (let offset = 0; offset < value.length; offset += DURABLE_ASSET_CHUNK_BYTES) {
      let end: number = Math.min(offset + DURABLE_ASSET_CHUNK_BYTES, value.length)
      chunks.push(value.slice(offset, end))
    }
    return chunks
  }

  static combine(chunks: Uint8Array[]): Uint8Array {
    let total: number = 0
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].length
    }
    let combined: Uint8Array = new Uint8Array(total)
    let offset: number = 0
    for (let i = 0; i < chunks.length; i++) {
      combined.set(chunks[i], offset)
      offset += chunks[i].length
    }
    return combined
  }

  static createManifest(path: string, generation: string, value: Uint8Array): DurableAssetManifest {
    let manifest: DurableAssetManifest = new DurableAssetManifest()
    manifest.path = path
    manifest.generation = generation
    manifest.chunkCount = DurableAssetFormat.split(value).length
    manifest.byteCount = value.length
    manifest.sha256 = DurableAssetFormat.sha256(value)
    return manifest
  }

  static encodeManifest(manifest: DurableAssetManifest): Uint8Array {
    let record: Record<string, string | number> = {
      'v': manifest.version,
      'path': manifest.path,
      'generation': manifest.generation,
      'chunks': manifest.chunkCount,
      'bytes': manifest.byteCount,
      'sha256': manifest.sha256
    }
    return DurableAssetFormat.encodeText(JSON.stringify(record))
  }

  static decodeManifest(value: Uint8Array): DurableAssetManifest {
    let record: Record<string, string | number> = JSON.parse(DurableAssetFormat.decodeText(value))
    let manifest: DurableAssetManifest = new DurableAssetManifest()
    manifest.version = DurableAssetFormat.requireNumber(record, 'v')
    manifest.path = DurableAssetFormat.requireString(record, 'path')
    manifest.generation = DurableAssetFormat.requireString(record, 'generation')
    manifest.chunkCount = DurableAssetFormat.requireNumber(record, 'chunks')
    manifest.byteCount = DurableAssetFormat.requireNumber(record, 'bytes')
    manifest.sha256 = DurableAssetFormat.requireString(record, 'sha256')
    if (manifest.version !== DURABLE_ASSET_VERSION || manifest.path.length === 0 ||
      manifest.generation.length === 0 || manifest.chunkCount < 1 ||
      manifest.byteCount < 0 || !/^[0-9a-f]{64}$/.test(manifest.sha256)) {
      throw new Error('Invalid durable asset manifest')
    }
    return manifest
  }

  static validate(manifest: DurableAssetManifest, value: Uint8Array): void {
    if (value.length !== manifest.byteCount || DurableAssetFormat.sha256(value) !== manifest.sha256) {
      throw new Error('Durable asset generation failed integrity validation: ' + manifest.path)
    }
  }

  static sha256(value: Uint8Array): string {
    let bitLength: number = value.length * 8
    let paddedLength: number = Math.ceil((value.length + 9) / 64) * 64
    let padded: Uint8Array = new Uint8Array(paddedLength)
    padded.set(value)
    padded[value.length] = 0x80
    let bitLengthHigh: number = Math.floor(bitLength / 0x100000000)
    let bitLengthLow: number = bitLength >>> 0
    for (let i = 0; i < 4; i++) {
      padded[paddedLength - 8 + i] = (bitLengthHigh >>> (24 - i * 8)) & 0xFF
      padded[paddedLength - 4 + i] = (bitLengthLow >>> (24 - i * 8)) & 0xFF
    }
    let state: number[] = [
      0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
      0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    let words: number[] = new Array<number>(64)
    for (let block = 0; block < padded.length; block += 64) {
      for (let i = 0; i < 16; i++) {
        let offset: number = block + i * 4
        words[i] = ((padded[offset] << 24) | (padded[offset + 1] << 16) |
          (padded[offset + 2] << 8) | padded[offset + 3]) >>> 0
      }
      for (let i = 16; i < 64; i++) {
        let s0: number = DurableAssetFormat.rotateRight(words[i - 15], 7) ^
          DurableAssetFormat.rotateRight(words[i - 15], 18) ^ (words[i - 15] >>> 3)
        let s1: number = DurableAssetFormat.rotateRight(words[i - 2], 17) ^
          DurableAssetFormat.rotateRight(words[i - 2], 19) ^ (words[i - 2] >>> 10)
        words[i] = (words[i - 16] + s0 + words[i - 7] + s1) >>> 0
      }
      let a: number = state[0]
      let b: number = state[1]
      let c: number = state[2]
      let d: number = state[3]
      let e: number = state[4]
      let f: number = state[5]
      let g: number = state[6]
      let h: number = state[7]
      for (let i = 0; i < 64; i++) {
        let sum1: number = DurableAssetFormat.rotateRight(e, 6) ^
          DurableAssetFormat.rotateRight(e, 11) ^ DurableAssetFormat.rotateRight(e, 25)
        let choose: number = (e & f) ^ ((~e) & g)
        let temp1: number = (h + sum1 + choose + SHA256_CONSTANTS[i] + words[i]) >>> 0
        let sum0: number = DurableAssetFormat.rotateRight(a, 2) ^
          DurableAssetFormat.rotateRight(a, 13) ^ DurableAssetFormat.rotateRight(a, 22)
        let majority: number = (a & b) ^ (a & c) ^ (b & c)
        let temp2: number = (sum0 + majority) >>> 0
        h = g
        g = f
        f = e
        e = (d + temp1) >>> 0
        d = c
        c = b
        b = a
        a = (temp1 + temp2) >>> 0
      }
      state[0] = (state[0] + a) >>> 0
      state[1] = (state[1] + b) >>> 0
      state[2] = (state[2] + c) >>> 0
      state[3] = (state[3] + d) >>> 0
      state[4] = (state[4] + e) >>> 0
      state[5] = (state[5] + f) >>> 0
      state[6] = (state[6] + g) >>> 0
      state[7] = (state[7] + h) >>> 0
    }
    let result: string = ''
    for (let i = 0; i < state.length; i++) {
      result += state[i].toString(16).padStart(8, '0')
    }
    return result
  }

  private static rotateRight(value: number, amount: number): number {
    return ((value >>> amount) | (value << (32 - amount))) >>> 0
  }

  private static requireString(record: Record<string, string | number>, key: string): string {
    let value: string | number = record[key]
    if (typeof value !== 'string') {
      throw new Error('Invalid durable asset manifest field: ' + key)
    }
    return value
  }

  private static requireNumber(record: Record<string, string | number>, key: string): number {
    let value: string | number = record[key]
    if (typeof value !== 'number' || !Number.isInteger(value)) {
      throw new Error('Invalid durable asset manifest field: ' + key)
    }
    return value
  }
}
