import { asset } from '@kit.AssetStoreKit'
import { BusinessError } from '@ohos.base'
import {
  DurableAssetFormat,
  DurableAssetManifest
} from './DurableAssetFormat'

const NAMESPACE: string = 'leantty.durable.v1'
const KIND_POINTER: string = 'pointer'
const KIND_CHUNK: string = 'chunk'
const QUERY_PAGE_SIZE: number = 40

export class DurableAssetStore {
  private generationSequence: number = 0

  write(path: string, text: string): void {
    this.validatePath(path)
    let value: Uint8Array = DurableAssetFormat.encodeText(text)
    let generation: string = this.nextGeneration()
    let manifest: DurableAssetManifest = DurableAssetFormat.createManifest(path, generation, value)
    let chunks: Uint8Array[] = DurableAssetFormat.split(value)
    try {
      for (let i = 0; i < chunks.length; i++) {
        this.addRecord(this.chunkAlias(path, generation, i), chunks[i], KIND_CHUNK, path, generation)
      }
      let verified: Uint8Array = this.readGeneration(manifest)
      DurableAssetFormat.validate(manifest, verified)
      this.upsertPointer(path, DurableAssetFormat.encodeManifest(manifest))
    } catch (e) {
      this.removeGeneration(path, generation)
      throw new Error('Failed to commit durable asset: ' + e)
    }
    try {
      this.removeOtherGenerations(path, generation)
    } catch (e) {
    }
  }

  read(path: string): string | null {
    this.validatePath(path)
    let pointer: Uint8Array | null = this.querySecret(this.pointerAlias(path))
    if (pointer === null) {
      return null
    }
    let manifest: DurableAssetManifest = DurableAssetFormat.decodeManifest(pointer)
    if (manifest.path !== path) {
      throw new Error('Durable asset pointer path mismatch')
    }
    let value: Uint8Array = this.readGeneration(manifest)
    DurableAssetFormat.validate(manifest, value)
    return DurableAssetFormat.decodeText(value)
  }

  async readAsync(path: string): Promise<string | null> {
    this.validatePath(path)
    let pointer: Uint8Array | null = await this.querySecretAsync(this.pointerAlias(path))
    if (pointer === null) {
      return null
    }
    let manifest: DurableAssetManifest = DurableAssetFormat.decodeManifest(pointer)
    if (manifest.path !== path) {
      throw new Error('Durable asset pointer path mismatch')
    }
    let value: Uint8Array = await this.readGenerationAsync(manifest)
    DurableAssetFormat.validate(manifest, value)
    return DurableAssetFormat.decodeText(value)
  }

  remove(path: string): void {
    this.validatePath(path)
    this.removeAlias(DurableAssetFormat.encodeText(this.pointerAlias(path)))
    let aliases: Uint8Array[] = this.queryAliasesByPath(path)
    for (let i = 0; i < aliases.length; i++) {
      try {
        this.removeAlias(aliases[i])
      } catch (e) {
      }
    }
  }

  listPaths(): string[] {
    let aliases: Uint8Array[] = this.queryAliases(KIND_POINTER)
    let paths: string[] = []
    for (let i = 0; i < aliases.length; i++) {
      let secret: Uint8Array | null = this.querySecretBytes(aliases[i])
      if (secret === null) {
        continue
      }
      let manifest: DurableAssetManifest = DurableAssetFormat.decodeManifest(secret)
      if (paths.indexOf(manifest.path) < 0) {
        paths.push(manifest.path)
      }
    }
    return paths
  }

  async listPathsAsync(): Promise<string[]> {
    let aliases: Uint8Array[] = await this.queryAliasesAsync(KIND_POINTER)
    let paths: string[] = []
    for (let i = 0; i < aliases.length; i++) {
      let secret: Uint8Array | null = await this.querySecretBytesAsync(aliases[i])
      if (secret === null) {
        continue
      }
      let manifest: DurableAssetManifest = DurableAssetFormat.decodeManifest(secret)
      if (paths.indexOf(manifest.path) < 0) {
        paths.push(manifest.path)
      }
    }
    return paths
  }

  garbageCollect(): void {
    let paths: string[] = this.listPaths()
    let activeGenerations: Map<string, string> = new Map<string, string>()
    for (let i = 0; i < paths.length; i++) {
      let pointer: Uint8Array | null = this.querySecret(this.pointerAlias(paths[i]))
      if (pointer !== null) {
        let manifest: DurableAssetManifest = DurableAssetFormat.decodeManifest(pointer)
        activeGenerations.set(paths[i], manifest.generation)
      }
    }
    let aliases: Uint8Array[] = this.queryAliases(KIND_CHUNK)
    for (let i = 0; i < aliases.length; i++) {
      let attrs: asset.AssetMap | null = this.queryAttributesByAlias(aliases[i])
      if (attrs === null) {
        continue
      }
      let path: string = this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_3)
      let generation: string = this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_4)
      if (!activeGenerations.has(path) || activeGenerations.get(path) !== generation) {
        this.removeAlias(aliases[i])
      }
    }
  }

  private readGeneration(manifest: DurableAssetManifest): Uint8Array {
    let chunks: Uint8Array[] = []
    for (let i = 0; i < manifest.chunkCount; i++) {
      let chunk: Uint8Array | null = this.querySecret(this.chunkAlias(manifest.path, manifest.generation, i))
      if (chunk === null) {
        throw new Error('Durable asset generation is incomplete: ' + manifest.path)
      }
      chunks.push(chunk)
    }
    return DurableAssetFormat.combine(chunks)
  }

  private async readGenerationAsync(manifest: DurableAssetManifest): Promise<Uint8Array> {
    let chunks: Uint8Array[] = []
    for (let i = 0; i < manifest.chunkCount; i++) {
      let chunk: Uint8Array | null =
        await this.querySecretAsync(this.chunkAlias(manifest.path, manifest.generation, i))
      if (chunk === null) {
        throw new Error('Durable asset generation is incomplete: ' + manifest.path)
      }
      chunks.push(chunk)
    }
    return DurableAssetFormat.combine(chunks)
  }

  private upsertPointer(path: string, manifest: Uint8Array): void {
    let alias: string = this.pointerAlias(path)
    if (this.querySecret(alias) === null) {
      this.addRecord(alias, manifest, KIND_POINTER, path, '')
      return
    }
    let query: asset.AssetMap = this.aliasQuery(DurableAssetFormat.encodeText(alias))
    let update: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    update.set(asset.Tag.SECRET, manifest)
    asset.updateSync(query, update)
  }

  private addRecord(alias: string, secret: Uint8Array, kind: string, path: string, generation: string): void {
    let attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    attrs.set(asset.Tag.ALIAS, DurableAssetFormat.encodeText(alias))
    attrs.set(asset.Tag.SECRET, secret)
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    attrs.set(asset.Tag.IS_PERSISTENT, true)
    attrs.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true)
    attrs.set(asset.Tag.DATA_LABEL_CRITICAL_1, DurableAssetFormat.encodeText(NAMESPACE))
    attrs.set(asset.Tag.DATA_LABEL_CRITICAL_2, DurableAssetFormat.encodeText(kind))
    attrs.set(asset.Tag.DATA_LABEL_CRITICAL_3, DurableAssetFormat.encodeText(path))
    if (generation.length > 0) {
      attrs.set(asset.Tag.DATA_LABEL_CRITICAL_4, DurableAssetFormat.encodeText(generation))
    }
    asset.addSync(attrs)
  }

  private querySecret(alias: string): Uint8Array | null {
    return this.querySecretBytes(DurableAssetFormat.encodeText(alias))
  }

  private async querySecretAsync(alias: string): Promise<Uint8Array | null> {
    return await this.querySecretBytesAsync(DurableAssetFormat.encodeText(alias))
  }

  private querySecretBytes(alias: Uint8Array): Uint8Array | null {
    let query: asset.AssetMap = this.aliasQuery(alias)
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      let results: asset.AssetMap[] = asset.querySync(query)
      if (results.length !== 1) {
        throw new Error('Durable asset alias did not resolve uniquely')
      }
      let value: asset.Value | undefined = results[0].get(asset.Tag.SECRET)
      if (!(value instanceof Uint8Array)) {
        throw new Error('Durable asset secret is missing')
      }
      return value
    } catch (e) {
      let error: BusinessError = e as BusinessError
      if (error.code === asset.ErrorCode.NOT_FOUND) {
        return null
      }
      throw new Error('Failed to query durable asset secret: ' + e)
    }
  }

  private async querySecretBytesAsync(alias: Uint8Array): Promise<Uint8Array | null> {
    let query: asset.AssetMap = this.aliasQuery(alias)
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      let results: asset.AssetMap[] = await asset.query(query)
      if (results.length !== 1) {
        throw new Error('Durable asset alias did not resolve uniquely')
      }
      let value: asset.Value | undefined = results[0].get(asset.Tag.SECRET)
      if (!(value instanceof Uint8Array)) {
        throw new Error('Durable asset secret is missing')
      }
      return value
    } catch (e) {
      let error: BusinessError = e as BusinessError
      if (error.code === asset.ErrorCode.NOT_FOUND) {
        return null
      }
      throw new Error('Failed to query durable asset secret: ' + e)
    }
  }

  private queryAttributesByAlias(alias: Uint8Array): asset.AssetMap | null {
    let query: asset.AssetMap = this.aliasQuery(alias)
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES)
    try {
      let results: asset.AssetMap[] = asset.querySync(query)
      if (results.length !== 1) {
        throw new Error('Durable asset alias did not resolve uniquely')
      }
      return results[0]
    } catch (e) {
      let error: BusinessError = e as BusinessError
      if (error.code === asset.ErrorCode.NOT_FOUND) {
        return null
      }
      throw new Error('Failed to query durable asset attributes: ' + e)
    }
  }

  private queryAliases(kind: string): Uint8Array[] {
    let aliases: Uint8Array[] = []
    let offset: number = 0
    while (true) {
      let query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
      query.set(asset.Tag.DATA_LABEL_CRITICAL_1, DurableAssetFormat.encodeText(NAMESPACE))
      query.set(asset.Tag.DATA_LABEL_CRITICAL_2, DurableAssetFormat.encodeText(kind))
      query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true)
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES)
      query.set(asset.Tag.RETURN_LIMIT, QUERY_PAGE_SIZE)
      query.set(asset.Tag.RETURN_OFFSET, offset)
      let page: asset.AssetMap[]
      try {
        page = asset.querySync(query)
      } catch (e) {
        let error: BusinessError = e as BusinessError
        if (error.code === asset.ErrorCode.NOT_FOUND) {
          return aliases
        }
        throw new Error('Failed to enumerate durable assets: ' + e)
      }
      for (let i = 0; i < page.length; i++) {
        let value: asset.Value | undefined = page[i].get(asset.Tag.ALIAS)
        if (!(value instanceof Uint8Array)) {
          throw new Error('Durable asset query returned an invalid alias')
        }
        aliases.push(value)
      }
      if (page.length < QUERY_PAGE_SIZE) {
        return aliases
      }
      offset += page.length
    }
  }

  private async queryAliasesAsync(kind: string): Promise<Uint8Array[]> {
    let aliases: Uint8Array[] = []
    let offset: number = 0
    while (true) {
      let query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
      query.set(asset.Tag.DATA_LABEL_CRITICAL_1, DurableAssetFormat.encodeText(NAMESPACE))
      query.set(asset.Tag.DATA_LABEL_CRITICAL_2, DurableAssetFormat.encodeText(kind))
      query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true)
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES)
      query.set(asset.Tag.RETURN_LIMIT, QUERY_PAGE_SIZE)
      query.set(asset.Tag.RETURN_OFFSET, offset)
      let page: asset.AssetMap[]
      try {
        page = await asset.query(query)
      } catch (e) {
        let error: BusinessError = e as BusinessError
        if (error.code === asset.ErrorCode.NOT_FOUND) {
          return aliases
        }
        throw new Error('Failed to enumerate durable assets: ' + e)
      }
      for (let i = 0; i < page.length; i++) {
        let value: asset.Value | undefined = page[i].get(asset.Tag.ALIAS)
        if (!(value instanceof Uint8Array)) {
          throw new Error('Durable asset query returned an invalid alias')
        }
        aliases.push(value)
      }
      if (page.length < QUERY_PAGE_SIZE) {
        return aliases
      }
      offset += page.length
    }
  }

  private queryAliasesByPath(path: string): Uint8Array[] {
    let aliases: Uint8Array[] = []
    let offset: number = 0
    while (true) {
      let query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
      query.set(asset.Tag.DATA_LABEL_CRITICAL_1, DurableAssetFormat.encodeText(NAMESPACE))
      query.set(asset.Tag.DATA_LABEL_CRITICAL_3, DurableAssetFormat.encodeText(path))
      query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true)
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES)
      query.set(asset.Tag.RETURN_LIMIT, QUERY_PAGE_SIZE)
      query.set(asset.Tag.RETURN_OFFSET, offset)
      let page: asset.AssetMap[]
      try {
        page = asset.querySync(query)
      } catch (e) {
        let error: BusinessError = e as BusinessError
        if (error.code === asset.ErrorCode.NOT_FOUND) {
          return aliases
        }
        throw new Error('Failed to enumerate durable assets by path: ' + e)
      }
      for (let i = 0; i < page.length; i++) {
        let value: asset.Value | undefined = page[i].get(asset.Tag.ALIAS)
        if (value instanceof Uint8Array) {
          aliases.push(value)
        }
      }
      if (page.length < QUERY_PAGE_SIZE) {
        return aliases
      }
      offset += page.length
    }
  }

  private removeOtherGenerations(path: string, activeGeneration: string): void {
    let aliases: Uint8Array[] = this.queryAliasesByPath(path)
    for (let i = 0; i < aliases.length; i++) {
      let attrs: asset.AssetMap | null = this.queryAttributesByAlias(aliases[i])
      if (attrs === null) {
        continue
      }
      let kind: string = this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_2)
      if (kind === KIND_CHUNK) {
        let generation: string = this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_4)
        if (generation !== activeGeneration) {
          this.removeAlias(aliases[i])
        }
      }
    }
  }

  private removeGeneration(path: string, generation: string): void {
    let aliases: Uint8Array[] = this.queryAliasesByPath(path)
    for (let i = 0; i < aliases.length; i++) {
      let attrs: asset.AssetMap | null = this.queryAttributesByAlias(aliases[i])
      if (attrs !== null &&
        this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_2) === KIND_CHUNK &&
        this.requireTextAttribute(attrs, asset.Tag.DATA_LABEL_CRITICAL_4) === generation) {
        this.removeAlias(aliases[i])
      }
    }
  }

  private removeAlias(alias: Uint8Array): void {
    try {
      asset.removeSync(this.aliasQuery(alias))
    } catch (e) {
      let error: BusinessError = e as BusinessError
      if (error.code !== asset.ErrorCode.NOT_FOUND) {
        throw new Error('Failed to remove durable asset: ' + e)
      }
    }
  }

  private aliasQuery(alias: Uint8Array): asset.AssetMap {
    let query: asset.AssetMap = new Map<asset.Tag, asset.Value>()
    query.set(asset.Tag.ALIAS, alias)
    query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true)
    return query
  }

  private requireTextAttribute(attrs: asset.AssetMap, tag: asset.Tag): string {
    let value: asset.Value | undefined = attrs.get(tag)
    if (!(value instanceof Uint8Array)) {
      throw new Error('Durable asset attribute is missing')
    }
    return DurableAssetFormat.decodeText(value)
  }

  private pointerAlias(path: string): string {
    return 'leantty.v1.p.' + DurableAssetFormat.sha256(DurableAssetFormat.encodeText(path))
  }

  private chunkAlias(path: string, generation: string, index: number): string {
    return 'leantty.v1.c.' + DurableAssetFormat.sha256(DurableAssetFormat.encodeText(path)) +
      '.' + generation + '.' + index.toString()
  }

  private nextGeneration(): string {
    this.generationSequence++
    return Date.now().toString(36) + '-' + this.generationSequence.toString(36)
  }

  private validatePath(path: string): void {
    if (path.length === 0 || path.length > 160 || path.startsWith('/') || path.includes('\\') ||
      path.includes('/../') || path.startsWith('../') || path.endsWith('/..')) {
      throw new Error('Invalid durable asset path')
    }
  }
}
