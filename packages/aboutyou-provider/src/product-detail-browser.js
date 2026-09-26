// Decode an observed response using the shop's current module, without sending RPCs.
(async ({ bytes, modules }) => {
  class ProtoReader {
    constructor(bytes) {
      this.buf = bytes;
      this.pos = 0;
      this.len = bytes.length;
    }

    uint32() {
      return Number(this.readVarint());
    }

    int32() {
      return this.uint32() | 0;
    }

    int64() {
      const value = this.readVarint();
      return { toNumber: () => Number(value) };
    }

    uint64() {
      return this.int64();
    }

    sint32() {
      const value = this.uint32();
      return (value >>> 1) ^ -(value & 1);
    }

    sint64() {
      const value = this.readVarint();
      const decoded = (value >> 1n) ^ (-(value & 1n));
      return { toNumber: () => Number(decoded) };
    }

    bool() {
      return this.uint32() !== 0;
    }

    string() {
      const length = this.uint32();
      const start = this.pos;
      this.pos += length;
      return new TextDecoder().decode(this.buf.slice(start, start + length));
    }

    bytes() {
      const length = this.uint32();
      const start = this.pos;
      this.pos += length;
      return this.buf.slice(start, start + length);
    }

    double() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 8);
      const value = view.getFloat64(0, true);
      this.pos += 8;
      return value;
    }

    float() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 4);
      const value = view.getFloat32(0, true);
      this.pos += 4;
      return value;
    }

    fixed32() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 4);
      const value = view.getUint32(0, true);
      this.pos += 4;
      return value;
    }

    skipType(wireType) {
      if (wireType === 0) {
        this.readVarint();
        return;
      }
      if (wireType === 1) {
        this.pos += 8;
        return;
      }
      if (wireType === 2) {
        const length = this.uint32();
        this.pos += length;
        return;
      }
      if (wireType === 3) {
        while (this.pos < this.len) {
          const tag = this.uint32();
          if ((tag & 7) === 4) break;
          this.skipType(tag & 7);
        }
        return;
      }
      if (wireType === 5) {
        this.pos += 4;
      }
    }

    readVarint() {
      let shift = 0n;
      let result = 0n;
      while (this.pos < this.len) {
        const byte = this.buf[this.pos++];
        result |= BigInt(byte & 127) << shift;
        if ((byte & 128) === 0) return result;
        shift += 7n;
      }
      return result;
    }
  }

  for (const url of modules) {
    const module = await import(url);
    const method = module.ArticleDetailService_GetProductBulk;
    if (typeof method !== 'function') continue;
    const data = await method({ unary(descriptor) {
      const message = new Uint8Array(bytes);
      return descriptor.decodeResponse(new ProtoReader(message), message.length);
    } }, {});
    const { trailers, ...payload } = data;
    return payload;
  }
  throw new Error('product_detail_decoder_missing');
})
